import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Result of checking the explicitly configured local decoder executable.
public enum MediaDecoderPreflight: Sendable, Equatable {
    case available(path: String)
    case unavailable(reason: String)
}

/// SourceBroker-owned decoder. The decoder receives a broker stream on stdin,
/// never the original source path. ffmpeg is used only as a local demux/decode
/// utility for compressed containers; its stdout is bounded into timestamped
/// PCM chunks before reaching a transcription provider.
///
/// Uncompressed RIFF/WAVE-PCM sources are demuxed internally (pure Foundation,
/// no subprocess). This keeps the generated-audio E2E path deterministic on
/// machines without Homebrew/ffmpeg — including CI runners — while ffmpeg
/// remains required for anything compressed. Both paths consume broker-owned
/// bytes only and fail closed on truncation or policy violations.
public struct BrokerPCMDecoder: Sendable {
    private final class ErrorBox: @unchecked Sendable {
        var value: Error?
    }
    public static let defaultSampleRate = 16_000.0
    public static let defaultChannels = 1
    public static let defaultChunkDuration: TimeInterval = 15

    public let executablePath: String
    public let maxSnapshotBytes: Int64
    public let sampleRate: Double
    public let channels: Int
    public let chunkDuration: TimeInterval

    public init(executablePath: String? = nil,
                maxSnapshotBytes: Int64 = 256 * 1024 * 1024,
                sampleRate: Double = BrokerPCMDecoder.defaultSampleRate,
                channels: Int = BrokerPCMDecoder.defaultChannels,
                chunkDuration: TimeInterval = BrokerPCMDecoder.defaultChunkDuration) {
        self.executablePath = executablePath ?? Self.defaultExecutablePath()
        self.maxSnapshotBytes = maxSnapshotBytes
        self.sampleRate = sampleRate
        self.channels = channels
        self.chunkDuration = chunkDuration
    }

    /// Reports whether the EXTERNAL demuxer executable is usable. Only needed
    /// for containers the internal RIFF/WAVE-PCM demuxer cannot handle
    /// (compressed audio, most video). Uncompressed WAV decodes regardless.
    public static func preflight(executablePath: String? = nil) -> MediaDecoderPreflight {
        let path = executablePath ?? defaultExecutablePath()
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .unavailable(reason: "decoder executable unavailable: \(path)")
        }
        return .available(path: path)
    }

    /// Decode one complete, policy-bounded source stream. Every emitted chunk
    /// contains at most `chunkDuration` seconds of mono PCM. The source is
    /// consumed strictly through `broker`; the original file is never written
    /// and its path is never handed to a subprocess.
    public func decode(path: String, broker: SourceBroker,
                       onChunk: (PCMChunk) throws -> Void) throws {
        let snapshot = try broker.completeSnapshot(path, maxBytes: min(maxSnapshotBytes, broker.maxSnapshotBytes))
        try decode(snapshot: snapshot, onChunk: onChunk)
    }

    /// Decode a complete broker-owned snapshot. This is the protocol used by
    /// the indexer so no source path crosses the decoder boundary.
    public func decode(snapshot: Data,
                       onChunk: (PCMChunk) throws -> Void) throws {
        guard sampleRate.isFinite, sampleRate > 0,
              chunkDuration.isFinite, chunkDuration > 0,
              sampleRate <= Double(Int.max) / chunkDuration,
              channels == 1 else {
            throw MediaDecoderError.invalidConfiguration
        }
        guard Int64(snapshot.count) <= maxSnapshotBytes else {
            throw MediaDecoderError.decoderFailed(
                status: -1, detail: "broker snapshot exceeds decoder policy")
        }

        switch Self.classifyRIFFWave(snapshot) {
        case .ok(let wave):
            return try emitChunks(from: wave.samples(atTargetRate: sampleRate),
                                  sampleRate: sampleRate, onChunk: onChunk)
        case .truncatedOrInvalid:
            // A RIFF/WAVE container whose declared chunks outrun the snapshot,
            // or whose header lies about its layout, must NEVER reach the
            // tolerant external demuxer — ffmpeg would happily decode the
            // surviving prefix and exit 0. Fail closed instead.
            throw MediaDecoderError.decoderFailed(status: -1,
                                                  detail: "truncated or invalid RIFF/WAVE-PCM snapshot; refusing partial decode")
        case .notRIFFWave, .unsupportedFormat:
            // Genuinely not uncompressed WAVE-PCM (or a valid container with an
            // unsupported encoding such as float/ADPCM): the external demuxer
            // may handle it and must be explicitly available.
            guard case .available = Self.preflight(executablePath: executablePath) else {
                throw MediaDecoderError.decoderUnavailable(executablePath)
            }
            try decodeViaExternalDemuxer(snapshot: snapshot, onChunk: onChunk)
        }
    }

    // MARK: - External demuxer (ffmpeg)

    private func decodeViaExternalDemuxer(snapshot: Data,
                                          onChunk: (PCMChunk) throws -> Void) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-i", "pipe:0",
                             "-vn", "-ac", String(channels), "-ar", String(Int(sampleRate)),
                             "-f", "s16le", "pipe:1"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // Decoder diagnostics are not part of the catalog contract. Discard
        // stderr so a noisy local executable cannot fill a pipe while the
        // bounded stdout stream is being consumed.
        process.standardError = FileHandle.nullDevice
        try process.run()
        let outputFD = output.fileHandleForReading.fileDescriptor
        let outputFlags = fcntl(outputFD, F_GETFL)
        if outputFlags != -1 { _ = fcntl(outputFD, F_SETFL, outputFlags | O_NONBLOCK) }

        let writerQueue = DispatchQueue(label: "librarian.media-decoder-input")
        let writerLock = NSLock()
        let writerError = ErrorBox()
        writerQueue.async {
            do {
                // Feed the broker-owned snapshot captured above; the source
                // path and filesystem play no further role.
                var offset = 0
                while offset < snapshot.count {
                    let n = min(262_144, snapshot.count - offset)
                    try input.fileHandleForWriting.write(contentsOf: snapshot[offset..<offset + n])
                    offset += n
                }
                try input.fileHandleForWriting.close()
            } catch {
                writerLock.lock()
                writerError.value = error
                writerLock.unlock()
                try? input.fileHandleForWriting.close()
            }
        }

        var pendingByte: UInt8?
        var samples: [Float] = []
        let maxSamples = max(1, Int(sampleRate * chunkDuration))
        var emittedSamples: Int64 = 0
        let deadline = Date().addingTimeInterval(120)
        func emitFullChunks() throws {
            while samples.count >= maxSamples {
                let chunkSamples = Array(samples.prefix(maxSamples))
                samples.removeFirst(maxSamples)
                let chunk = PCMChunk(samples: chunkSamples, sampleRate: sampleRate,
                                     channels: channels,
                                     startTime: TimeInterval(emittedSamples) / sampleRate)
                emittedSamples += Int64(chunkSamples.count)
                try onChunk(chunk)
            }
        }

        do {
            while true {
                var descriptor = pollfd(fd: outputFD, events: Int16(POLLIN), revents: 0)
                let timeout: Int32
                if process.isRunning {
                    timeout = max(0, Int32(deadline.timeIntervalSinceNow * 1000))
                } else {
                    timeout = 0
                }
                let ready = poll(&descriptor, 1, timeout)
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw MediaDecoderError.decoderFailed(
                        status: -1, detail: "decoder output poll failed: \(errno)")
                }
                if ready == 0 {
                    guard !process.isRunning else {
                        throw MediaDecoderError.decoderFailed(
                            status: -2, detail: "decoder timed out after 120s")
                    }
                    break
                }
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                    guard let baseAddress = bytes.baseAddress else { return 0 }
                    return Darwin.read(outputFD, baseAddress, bytes.count)
                }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                        continue
                    }
                    throw MediaDecoderError.decoderFailed(
                        status: -1, detail: "decoder output read failed: \(errno)")
                }
                if count == 0 {
                    if !process.isRunning {
                        break
                    }
                    // A HUP can be reported before Process observes exit.
                    usleep(1_000)
                    continue
                }
                let data = buffer[..<count]
                var bytes = Array(data)
                if let carry = pendingByte {
                    bytes.insert(carry, at: 0)
                    pendingByte = nil
                }
                if bytes.count % 2 == 1 { pendingByte = bytes.removeLast() }
                var index = 0
                samples.reserveCapacity(min(maxSamples, samples.count + bytes.count / 2))
                while index + 1 < bytes.count {
                    let raw = Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
                    samples.append(Float(raw) / 32768.0)
                    index += 2
                }
                try emitFullChunks()
            }
            guard pendingByte == nil else {
                throw MediaDecoderError.decoderFailed(
                    status: -1, detail: "external decoder emitted an incomplete PCM sample")
            }
            if !samples.isEmpty {
                let chunk = PCMChunk(samples: samples, sampleRate: sampleRate, channels: channels,
                                     startTime: TimeInterval(emittedSamples) / sampleRate)
                try onChunk(chunk)
            }
            process.waitUntilExit()
        } catch {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let stopDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < stopDeadline { usleep(20_000) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw error
        }

        try? input.fileHandleForWriting.close()
        writerQueue.sync {}
        writerLock.lock()
        let failure = writerError.value
        writerLock.unlock()
        if let failure { throw failure }
        guard process.terminationStatus == 0 else {
            throw MediaDecoderError.decoderFailed(
                status: process.terminationStatus, detail: "external decoder returned a failure status")
        }
    }

    private static func defaultExecutablePath() -> String {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/bin/ffmpeg"
    }

    // MARK: - Internal RIFF/WAVE-PCM demuxer

    /// Outcome classification for candidate RIFF/WAVE bytes. Distinguishing
    /// "not RIFF/WAVE at all" from "RIFF/WAVE that failed validation" is what
    /// keeps truncated containers away from the tolerant external demuxer
    /// (which would otherwise decode the surviving prefix and exit 0).
    fileprivate enum RIFFClassification {
        case ok(RIFFWave)
        /// Bytes are not a RIFF/WAVE container at all.
        case notRIFFWave
        /// Well-formed container carrying an encoding this demuxer does not
        /// implement (IEEE float, ADPCM, ...). The external demuxer may handle it.
        case unsupportedFormat
        /// A RIFF/WAVE container whose declared structure outruns or
        /// contradicts the actual snapshot: truncated payload, lying headers.
        case truncatedOrInvalid
    }

    fileprivate static func classifyRIFFWave(_ data: Data) -> RIFFClassification {
        guard data.count >= 12,
              data.subdata(in: 0..<4) == Data("RIFF".utf8),
              data.subdata(in: 8..<12) == Data("WAVE".utf8) else {
            return .notRIFFWave
        }
        let declaredRIFFSize = Int64(leUInt32(data, 4))
        guard declaredRIFFSize + 8 == Int64(data.count) else {
            return .truncatedOrInvalid
        }

        var fmtRate: UInt32?
        var fmtChannels: UInt16?
        var sawUnsupportedEncoding = false
        var sawValidPCMFormat = false
        var pcmPayload: Data?

        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = data.subdata(in: offset..<offset + 4)
            // Chunk size cannot straddle the buffer end (overflow-safe:
            // Int64 arithmetic before any Int conversion).
            let rawSize = leUInt32(data, offset + 4)
            let bodyStart = offset + 8
            let bodyEnd = Int64(bodyStart) + Int64(rawSize)
            guard bodyEnd <= Int64(data.count) else {
                return .truncatedOrInvalid
            }

            if chunkID == Data("fmt ".utf8) {
                guard rawSize >= 16 else { return .truncatedOrInvalid }
                let formatTag = leUInt16(data, bodyStart)
                if formatTag == 1 {
                    let channels = leUInt16(data, bodyStart + 2)
                    let rate = leUInt32(data, bodyStart + 4)
                    let bitsPerSample = leUInt16(data, bodyStart + 14)
                    // The header must tell the truth about its own geometry;
                    // implausible values mean a corrupt/lying header, while a
                    // truthful non-16-bit PCM encoding is merely unsupported.
                    guard channels >= 1, channels <= 8, rate >= 8_000, rate <= 192_000 else {
                        return .truncatedOrInvalid
                    }
                    guard bitsPerSample == 16 else { return .unsupportedFormat }
                    fmtChannels = channels
                    fmtRate = rate
                    sawValidPCMFormat = true
                } else {
                    sawUnsupportedEncoding = true
                }
            } else if chunkID == Data("data".utf8) {
                // Last data chunk wins (metadata chunks may legally follow).
                pcmPayload = data.subdata(in: bodyStart..<Int(bodyEnd))
            }
            // RIFF chunks are word-aligned: odd sizes carry one pad byte.
            offset = bodyStart + Int(rawSize) + (Int(rawSize) % 2)
        }

        guard offset == data.count else {
            return .truncatedOrInvalid
        }
        if sawUnsupportedEncoding { return .unsupportedFormat }
        guard sawValidPCMFormat, let rate = fmtRate, let channels = fmtChannels else {
            return .truncatedOrInvalid // RIFF/WAVE with no usable fmt chunk
        }
        guard let payload = pcmPayload else {
            return .truncatedOrInvalid // RIFF/WAVE with no data chunk
        }
        guard payload.count % (2 * Int(channels)) == 0 else {
            return .truncatedOrInvalid // incomplete PCM frame
        }
        return .ok(RIFFWave(sourceRate: Double(rate), sourceChannels: Int(channels), pcm: payload))
    }

    /// Minimal model of an uncompressed RIFF/WAVE-PCM (format tag 1, 16-bit)
    /// container that has ALREADY passed bounds validation.
    fileprivate struct RIFFWave {
        let sourceRate: Double
        let sourceChannels: Int
        let pcm: Data

        /// Deterministic mono Float conversion at the requested rate: channel
        /// fold by mean, then linear-interpolation resample. Identical inputs
        /// always produce bit-identical outputs on every machine.
        func samples(atTargetRate target: Double) -> [Float] {
            let frameCount = pcm.count / (2 * sourceChannels)
            func converted(_ frame: Int) -> [Float] {
                var out: [Float] = []
                out.reserveCapacity(sourceChannels)
                let base = frame * 2 * sourceChannels
                for c in 0..<sourceChannels {
                    let raw = UInt16(pcm[base + c * 2]) | (UInt16(pcm[base + c * 2 + 1]) << 8)
                    out.append(Float(Int16(bitPattern: raw)) / 32768.0)
                }
                return out
            }

            // Fast path: already mono at target rate — exact passthrough.
            if sourceChannels == 1, sourceRate == target {
                var out = [Float]()
                out.reserveCapacity(frameCount)
                for f in 0..<frameCount { out.append(converted(f)[0]) }
                return out
            }

            let ratio = sourceRate / target
            let outCount = Int((Double(frameCount) / ratio).rounded(.down))
            var out = [Float]()
            out.reserveCapacity(max(0, outCount))
            for j in 0..<max(0, outCount) {
                let position = Double(j) * ratio
                let s = Int(position.rounded(.down))
                let frac = Float(position - Double(s))
                let a = converted(s)
                let b = converted(min(s + 1, frameCount - 1))
                var mixed: Float = 0
                for c in 0..<sourceChannels { mixed += a[c] + (b[c] - a[c]) * frac }
                out.append(mixed / Float(sourceChannels))
            }
            return out
        }
    }

    fileprivate static func leUInt16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[o]) | (UInt16(d[o + 1]) << 8)
    }
    fileprivate static func leUInt32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | (UInt32(d[o + 1]) << 8) | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24)
    }

    /// Slice a mono sample array into timestamped chunks of at most
    /// `chunkDuration` seconds. Shared by both demux paths.
    fileprivate func emitChunks(from samples: [Float], sampleRate: Double,
                                onChunk: (PCMChunk) throws -> Void) throws {
        let maxSamples = max(1, Int(sampleRate * chunkDuration))
        var emitted: Int64 = 0
        var start = samples.startIndex
        while start < samples.endIndex {
            let end = min(start + maxSamples, samples.endIndex)
            let chunk = PCMChunk(samples: Array(samples[start..<end]),
                                 sampleRate: sampleRate, channels: 1,
                                 startTime: TimeInterval(emitted) / sampleRate)
            emitted += Int64(end - start)
            try onChunk(chunk)
            start = end
        }
    }
}

public enum MediaDecoderError: Error, CustomStringConvertible, Sendable {
    case invalidConfiguration
    case decoderUnavailable(String)
    case decoderFailed(status: Int32, detail: String)

    public var description: String {
        switch self {
        case .invalidConfiguration: return "invalid PCM decoder configuration"
        case .decoderUnavailable(let path): return "decoder unavailable: \(path)"
        case .decoderFailed(let status, let detail): return "decoder failed (\(status)): \(detail)"
        }
    }
}
