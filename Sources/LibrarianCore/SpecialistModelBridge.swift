import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct SpecialistOCRResult: Sendable, Equatable {
    public let modelID: String
    public let text: String
    public let confidence: Double
}

public struct SpecialistClassification: Sendable, Equatable {
    public let modelID: String
    public let categories: [String]
    public let description: String
    public let confidence: Double
    public let reasons: [String]
}

public struct SpecialistEvidence: Sendable, Equatable {
    public let kind: String
    public let filename: String
    public let deterministicCategories: [String]
    public let deterministicConfidence: Double
    public let textSample: String?
    public let visionLabels: [String]

    public init(kind: String, filename: String, deterministicCategories: [String],
                deterministicConfidence: Double, textSample: String?, visionLabels: [String]) {
        self.kind = kind
        self.filename = String(filename.prefix(256))
        self.deterministicCategories = Array(deterministicCategories.prefix(8))
        self.deterministicConfidence = max(0, min(1, deterministicConfidence))
        self.textSample = textSample.map { String($0.prefix(8_000)) }
        self.visionLabels = Array(visionLabels.prefix(8)).map { String($0.prefix(96)) }
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "kind": kind,
            "filename": filename,
            "categories": deterministicCategories,
            "confidence": deterministicConfidence,
            "vision_labels": visionLabels,
        ]
        if let textSample { object["text_sample"] = textSample }
        return object
    }
}

/// Bounded bridge to `scripts/specialist.py`.
/// The protocol accepts broker-owned bytes or derived text only; source paths are never sent.
public final class SpecialistModelBridge: @unchecked Sendable {
    public static let siglipDimension = 1152
    public static let dinoDimension = 768
    public static let maxImageBytes = 64 * 1024 * 1024

    private let worker: Worker?

    public init(startWorker: Bool = true) {
        self.worker = startWorker ? Worker() : nil
    }

    deinit { worker?.close() }

    public static func availableModelIDs() -> Set<String> {
        Set(LocalModelStack.all.compactMap { isProvisioned($0) ? $0.id : nil })
    }

    public static func isProvisioned(_ descriptor: LocalModelDescriptor) -> Bool {
        guard let root = specialistRoot(containing: descriptor.id) else { return false }
        let directory = root.appendingPathComponent(descriptor.id)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("provenance.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema"] as? Int == 1,
              object["model"] as? String == descriptor.id,
              object["hf_id"] as? String == descriptor.hfID,
              let revision = object["revision"] as? String,
              revision.count == 40,
              revision.hasPrefix(descriptor.revisionPrefix),
              let files = object["expected_files"] as? [String: Any], !files.isEmpty else { return false }
        let canonicalRoot = directory.resolvingSymlinksInPath().standardizedFileURL.path
        for (relative, expected) in files {
            guard let digest = expected as? String, digest.count == 64,
                  digest.allSatisfy({ $0.isHexDigit }) else { return false }
            let file = directory.appendingPathComponent(relative)
                .resolvingSymlinksInPath().standardizedFileURL
            guard file.path == canonicalRoot || file.path.hasPrefix(canonicalRoot + "/"),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        }
        return true
    }

    public static func preflight(_ descriptor: LocalModelDescriptor) -> EmbeddingProviderPreflight {
        let script = LocalModelBridge.scriptsDir()?.appendingPathComponent("specialist.py")
        let provisioned = isProvisioned(descriptor)
        let hasScript = script.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let reason: String
        if !hasScript { reason = "specialist.py is not packaged/available" }
        else if !provisioned {
            reason = descriptor.gated
                ? "Pinned model is not provisioned (this model is gated and requires accepted access)."
                : "Pinned specialist checkpoint is not provisioned."
        } else { reason = "Pinned local specialist snapshot is available; runtime remains offline-only." }
        return EmbeddingProviderPreflight(
            providerID: descriptor.id,
            available: hasScript && provisioned,
            reason: reason,
            artifacts: [descriptor.hfID + "@" + descriptor.revisionPrefix],
            dependencies: [descriptor.runtime])
    }

    public func embedSigLIPImage(_ bytes: Data, timeout: TimeInterval = 30) -> EmbeddingVector? {
        guard bytes.count > 0, bytes.count <= Self.maxImageBytes,
              Self.isProvisioned(LocalModelStack.siglip2), let worker else { return nil }
        let request: [String: Any] = ["op": "siglip_image", "data_b64": bytes.base64EncodedString()]
        guard let object = worker.call(request, timeout: timeout), object["error"] == nil,
              let data = Self.vectorData(object, expectedDimension: Self.siglipDimension) else { return nil }
        return EmbeddingVector(spaceID: Self.siglipSpaceID, dim: Self.siglipDimension, data: data)
    }

    public func embedSigLIPText(_ text: String, timeout: TimeInterval = 20) -> EmbeddingVector? {
        let clipped = String(text.prefix(16_000))
        guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.isProvisioned(LocalModelStack.siglip2), let worker else { return nil }
        guard let object = worker.call(["op": "siglip_text", "text": clipped], timeout: timeout),
              object["error"] == nil,
              let data = Self.vectorData(object, expectedDimension: Self.siglipDimension) else { return nil }
        return EmbeddingVector(spaceID: Self.siglipSpaceID, dim: Self.siglipDimension, data: data)
    }

    public func embedDINOImage(_ bytes: Data, timeout: TimeInterval = 25) -> EmbeddingVector? {
        guard bytes.count > 0, bytes.count <= Self.maxImageBytes,
              Self.isProvisioned(LocalModelStack.dinov3), let worker else { return nil }
        let request: [String: Any] = ["op": "dino_image", "data_b64": bytes.base64EncodedString()]
        guard let object = worker.call(request, timeout: timeout), object["error"] == nil,
              let data = Self.vectorData(object, expectedDimension: Self.dinoDimension) else { return nil }
        return EmbeddingVector(spaceID: Self.dinoSpaceID, dim: Self.dinoDimension, data: data)
    }

    public func recognizeDocument(_ bytes: Data, suffix: String = ".png",
                                  timeout: TimeInterval = 90) -> SpecialistOCRResult? {
        guard bytes.count > 0, bytes.count <= Self.maxImageBytes,
              Self.isProvisioned(LocalModelStack.paddleOCR), let worker else { return nil }
        let request: [String: Any] = [
            "op": "ocr", "data_b64": bytes.base64EncodedString(),
            "suffix": String(suffix.prefix(9)),
        ]
        guard let object = worker.call(request, timeout: timeout), object["error"] == nil,
              let text = object["text"] as? String,
              let confidence = object["confidence"] as? Double else { return nil }
        // OCR is an occasional specialist. Drop it after the call to keep the resident set small.
        _ = worker.call(["op": "release", "model": LocalModelStack.paddleOCR.id], timeout: 5)
        return SpecialistOCRResult(modelID: LocalModelStack.paddleOCR.id,
                                   text: String(text.prefix(200_000)), confidence: max(0, min(1, confidence)))
    }

    public func classifyImage(_ bytes: Data, model: LocalModelDescriptor,
                              evidence: SpecialistEvidence,
                              timeout: TimeInterval = 120) -> SpecialistClassification? {
        guard model.capability == .visionFallback || model.capability == .visionHeavyFallback,
              bytes.count > 0, bytes.count <= Self.maxImageBytes,
              Self.isProvisioned(model), let worker else { return nil }
        let request: [String: Any] = [
            "op": "classify_image", "model": model.id,
            "data_b64": bytes.base64EncodedString(), "evidence": evidence.jsonObject,
        ]
        defer { _ = worker.call(["op": "release", "model": model.id], timeout: 8) }
        return Self.parseClassification(worker.call(request, timeout: timeout), modelID: model.id)
    }

    public func classifyText(model: LocalModelDescriptor = LocalModelStack.ling,
                             evidence: SpecialistEvidence,
                             timeout: TimeInterval = 120) -> SpecialistClassification? {
        guard model.capability == .textReasoning, Self.isProvisioned(model), let worker else { return nil }
        defer { _ = worker.call(["op": "release", "model": model.id], timeout: 8) }
        return Self.parseClassification(
            worker.call(["op": "classify_text", "evidence": evidence.jsonObject], timeout: timeout),
            modelID: model.id)
    }

    public static var siglipSpaceID: String {
        "siglip2-joint:\(LocalModelStack.siglip2.revisionPrefix):naflex-v1"
    }
    public static var dinoSpaceID: String {
        "dinov3-visual:\(LocalModelStack.dinov3.revisionPrefix):vitb16-v1"
    }

    private static func parseClassification(_ object: [String: Any]?, modelID: String) -> SpecialistClassification? {
        guard let object, object["error"] == nil,
              let categories = object["categories"] as? [String], !categories.isEmpty,
              let description = object["description"] as? String,
              let confidence = object["confidence"] as? Double,
              let reasons = object["reasons"] as? [String],
              confidence.isFinite else { return nil }
        return SpecialistClassification(
            modelID: modelID,
            categories: Array(categories.prefix(ClassifierContract.maxCategories)),
            description: String(description.prefix(512)),
            confidence: max(0, min(1, confidence)),
            reasons: Array(reasons.prefix(ClassifierContract.maxReasonCodes)).map { String($0.prefix(96)) })
    }

    private static func vectorData(_ object: [String: Any], expectedDimension: Int) -> Data? {
        guard object["dim"] as? Int == expectedDimension,
              let vector = object["vector"] as? [Double], vector.count == expectedDimension else { return nil }
        var data = Data(capacity: expectedDimension * MemoryLayout<Float>.stride)
        for value in vector {
            guard value.isFinite else { return nil }
            var float = Float(value)
            guard float.isFinite else { return nil }
            withUnsafeBytes(of: &float) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func specialistRoot(containing modelID: String) -> URL? {
        for models in LocalModelBridge.modelsRoots() {
            let specialists = models.appendingPathComponent("specialists")
            if FileManager.default.fileExists(atPath: specialists.appendingPathComponent(modelID)
                .appendingPathComponent("provenance.json").path) {
                return specialists
            }
        }
        return nil
    }

    /// One long-lived process per Indexer keeps embedding models warm. Heavy models are explicitly
    /// released after use, and `close()` terminates the whole process at session end.
    final class Worker: @unchecked Sendable {
        private let process: Process
        private let input: Pipe
        private let output: Pipe
        private let error: Pipe
        private let lock = NSLock()
        private var buffer = Data()
        private var closed = false

        init?() {
            guard let script = LocalModelBridge.scriptsDir()?.appendingPathComponent("specialist.py"),
                  FileManager.default.fileExists(atPath: script.path) else { return nil }
            let candidates = LocalModelBridge.modelsRoots().map { $0.appendingPathComponent("specialists") }
            let root = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
            let pythonCandidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            guard let python = pythonCandidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [script.path, "--worker"]
            var env = ProcessInfo.processInfo.environment
            env["HF_HUB_OFFLINE"] = "1"
            env["TRANSFORMERS_OFFLINE"] = "1"
            env["HF_DATASETS_OFFLINE"] = "1"
            env["HF_HUB_DISABLE_TELEMETRY"] = "1"
            env["DO_NOT_TRACK"] = "1"
            if let root { env["LIBRARIAN_SPECIALIST_MODELS_DIR"] = root.path }
            process.environment = env
            let input = Pipe(), output = Pipe(), error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            do { try process.run() } catch { return nil }
            self.process = process
            self.input = input
            self.output = output
            self.error = error
            #if canImport(Darwin)
            for fd in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor] {
                let flags = fcntl(fd, F_GETFL)
                if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
            }
            #endif
            let stderrHandle = error.fileHandleForReading
            DispatchQueue.global(qos: .utility).async {
                while !stderrHandle.readData(ofLength: 64 * 1024).isEmpty {}
            }
        }

        deinit { close() }

        func close() {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < deadline { usleep(20_000) }
                if process.isRunning { process.interrupt() }
            }
        }

        func call(_ request: [String: Any], timeout: TimeInterval) -> [String: Any]? {
            lock.lock()
            defer { lock.unlock() }
            guard !closed, process.isRunning,
                  var data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
            guard data.count <= 96 * 1024 * 1024 else { return nil }
            data.append(10)
            let deadline = Date().addingTimeInterval(max(0.1, timeout))
            guard write(data, deadline: deadline) else { return nil }
            return readResponse(deadline: deadline)
        }

        private func write(_ data: Data, deadline: Date) -> Bool {
            #if canImport(Darwin)
            let fd = input.fileHandleForWriting.fileDescriptor
            var offset = 0
            while offset < data.count && Date() < deadline {
                let written = data.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                }
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                if written < 0, errno != EAGAIN, errno != EWOULDBLOCK { return false }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ms = max(1, Int32(deadline.timeIntervalSinceNow * 1000))
                if poll(&descriptor, 1, ms) <= 0 { return false }
            }
            return offset == data.count
            #else
            do { try input.fileHandleForWriting.write(contentsOf: data); return true } catch { return false }
            #endif
        }

        private func readResponse(deadline: Date) -> [String: Any]? {
            #if canImport(Darwin)
            let fd = output.fileHandleForReading.fileDescriptor
            while Date() < deadline {
                if let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(...newline)
                    return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ms = max(1, Int32(deadline.timeIntervalSinceNow * 1000))
                let ready = poll(&descriptor, 1, ms)
                if ready <= 0 { return nil }
                var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                let count = bytes.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.read(fd, base, raw.count)
                }
                if count > 0 {
                    buffer.append(contentsOf: bytes[..<count])
                    if buffer.count > 4 * 1024 * 1024 { return nil }
                } else if count == 0 { return nil }
                else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { return nil }
            }
            return nil
            #else
            return nil
            #endif
        }
    }
}

/// SigLIP2 semantic provider. DINOv3 is deliberately separate because its visual space is not
/// cross-modal and must never be compared with SigLIP vectors.
public final class SpecialistSigLIP2EmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public let providerID = "specialist:siglip2-so400m-naflex@cc24074:naflex-v1"
    private let bridge: SpecialistModelBridge

    public init(bridge: SpecialistModelBridge = SpecialistModelBridge()) { self.bridge = bridge }

    public var preflight: EmbeddingProviderPreflight {
        SpecialistModelBridge.preflight(LocalModelStack.siglip2)
    }
    public var imageModelID: String { "image:\(providerID)" }
    public var textModelID: String { "text:\(providerID)" }

    public func embedText(_ text: String) -> EmbeddingVector? { bridge.embedSigLIPText(text) }
    public func embedImageBytes(_ bytes: Data) -> EmbeddingVector? { bridge.embedSigLIPImage(bytes) }
    public func embedJointText(_ text: String) -> EmbeddingVector? { bridge.embedSigLIPText(text) }
}
