import Foundation

/// Result of checking the explicitly configured local decoder executable.
public enum MediaDecoderPreflight: Sendable, Equatable {
    case available(path: String)
    case unavailable(reason: String)
}

/// SourceBroker-owned decoder. The decoder receives a broker stream on stdin,
/// never the original source path. ffmpeg is used only as a local demux/decode
/// utility; its stdout is bounded into timestamped PCM chunks before reaching
/// a transcription provider.
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

    public static func preflight(executablePath: String? = nil) -> MediaDecoderPreflight {
        let path = executablePath ?? defaultExecutablePath()
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .unavailable(reason: "decoder executable unavailable: \(path)")
        }
        return .available(path: path)
    }

    /// Decode one complete, policy-bounded source stream. Every emitted chunk
    /// contains at most `chunkDuration` seconds of mono PCM.
    public func decode(path: String, broker: SourceBroker,
                       onChunk: (PCMChunk) throws -> Void) throws {
        guard sampleRate > 0, channels == 1, chunkDuration > 0 else {
            throw MediaDecoderError.invalidConfiguration
        }
        guard case .available = Self.preflight(executablePath: executablePath) else {
            throw MediaDecoderError.decoderUnavailable(executablePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-i", "pipe:0",
                             "-vn", "-ac", String(channels), "-ar", String(Int(sampleRate)),
                             "-f", "s16le", "pipe:1"]
        let input = Pipe()
        let output = Pipe()
        let errorPipe = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe
        try process.run()

        let writerQueue = DispatchQueue(label: "librarian.media-decoder-input")
        let writerLock = NSLock()
        let writerError = ErrorBox()
        writerQueue.async {
            do {
                try broker.streamCompleteSnapshot(path, maxBytes: min(maxSnapshotBytes, broker.maxSnapshotBytes)) { data, isLast in
                    if !isLast { try input.fileHandleForWriting.write(contentsOf: data) }
                    if isLast { try input.fileHandleForWriting.close() }
                }
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
                let data = output.fileHandleForReading.readData(ofLength: 64 * 1024)
                if data.isEmpty { break }
                var bytes = [UInt8](data)
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
            if !samples.isEmpty {
                let chunk = PCMChunk(samples: samples, sampleRate: sampleRate, channels: channels,
                                     startTime: TimeInterval(emittedSamples) / sampleRate)
                try onChunk(chunk)
            }
            process.waitUntilExit()
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }

        writerQueue.sync {}
        writerLock.lock()
        let failure = writerError.value
        writerLock.unlock()
        if let failure { throw failure }
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown decoder error"
            throw MediaDecoderError.decoderFailed(status: process.terminationStatus, detail: detail)
        }
    }

    private static func defaultExecutablePath() -> String {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/bin/ffmpeg"
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
