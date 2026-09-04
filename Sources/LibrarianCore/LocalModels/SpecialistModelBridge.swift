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

/// One opaque, broker-owned image payload in a bounded SigLIP batch. The ID is
/// returned unchanged by the worker so callers can bind vectors back to exact
/// file generations without ever sending source paths to Python.
public struct SpecialistImageEmbeddingBatchItem: Sendable, Equatable {
    public let id: String
    public let bytes: Data

    public init(id: String, bytes: Data) {
        self.id = id
        self.bytes = bytes
    }
}

public struct SpecialistImageEmbeddingBatchResult: Sendable, Equatable {
    public let id: String
    public let vector: EmbeddingVector

    public init(id: String, vector: EmbeddingVector) {
        self.id = id
        self.vector = vector
    }
}

/// Bounded bridge to `scripts/specialist.py`.
/// The protocol accepts broker-owned bytes or derived text only; source paths are never sent.
public final class SpecialistModelBridge: @unchecked Sendable {
    public static let siglipBaseDimension = 768
    public static let siglipSo400mDimension = 1152
    /// Compatibility name for the original So400m-only bridge.
    public static let siglipDimension = siglipSo400mDimension
    public static let dinoDimension = 768
    public static let maxImageBytes = 64 * 1024 * 1024
    public static let maxBatchImages = 8
    public static let maxBatchRawBytes = 64 * 1024 * 1024

    private let worker: Worker?

    public init(startWorker: Bool = true) {
        self.worker = startWorker ? Worker() : nil
    }

    deinit { worker?.close() }

    public static func availableModelIDs() -> Set<String> {
        Set(LocalModelStack.all.compactMap { isProvisioned($0) ? $0.id : nil })
    }

    /// This is a structural discovery check used by the UI and router. The
    /// Python worker performs the expensive byte-for-byte verification before
    /// loading a checkpoint, so a manifest can never make untrusted weights
    /// executable by itself.
    public static func isProvisioned(_ descriptor: LocalModelDescriptor) -> Bool {
        isProvisioned(descriptor, roots: specialistRoots())
    }

    /// Internal root-injection seam used by regression tests. Production calls
    /// the public overload so bundled, Application Support, and configured
    /// roots are discovered from the process environment.
    static func isProvisioned(_ descriptor: LocalModelDescriptor, roots: [URL]) -> Bool {
        guard unsupportedReason(descriptor) == nil else { return false }
        for root in roots {
            let directory = root.appendingPathComponent(descriptor.id)
            guard let rootValues = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
                  let data = try? Data(contentsOf: directory.appendingPathComponent("provenance.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["schema"] as? Int == 1,
                  object["model"] as? String == descriptor.id,
                  object["hf_id"] as? String == descriptor.hfID,
                  let revision = object["revision"] as? String,
                  revision.count == 40,
                  revision.hasPrefix(descriptor.revisionPrefix),
                  let files = object["expected_files"] as? [String: Any], !files.isEmpty else { continue }
            let canonicalRoot = directory.resolvingSymlinksInPath().standardizedFileURL.path
            var expectedPaths = Set<String>()
            var valid = true
            for (relative, expected) in files {
                guard let digest = expected as? String, digest.count == 64,
                      digest.allSatisfy({ $0.isHexDigit }),
                      Self.isSafeRelativePath(relative) else {
                    valid = false
                    break
                }
                let file = directory.appendingPathComponent(relative)
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else {
                    valid = false
                    break
                }
                let resolved = file.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved.hasPrefix(canonicalRoot + "/") else {
                    valid = false
                    break
                }
                expectedPaths.insert(relative)
            }
            guard valid else { continue }

            // A stale or injected extra regular file must not be silently trusted.
            // `.cache` is intentionally ignored here and by the provisioner; it is
            // never part of the immutable model snapshot.
            var actualPaths = Set<String>()
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []) else { continue }
            for case let file as URL in enumerator {
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink != true else {
                    valid = false
                    break
                }
                guard values.isRegularFile == true else { continue }
                let resolvedFile = file.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolvedFile.hasPrefix(canonicalRoot + "/") else {
                    valid = false
                    break
                }
                let relative = String(resolvedFile.dropFirst(canonicalRoot.count + 1))
                if relative == "provenance.json" || file.pathComponents.contains(".cache") { continue }
                actualPaths.insert(relative)
            }
            if valid && actualPaths == expectedPaths { return true }
        }
        return false
    }

    public static func preflight(_ descriptor: LocalModelDescriptor) -> EmbeddingProviderPreflight {
        let script = LocalModelBridge.scriptsDir()?.appendingPathComponent("specialist.py")
        let provisioned = isProvisioned(descriptor)
        let hasScript = script.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let hasRuntime = LocalModelBridge.pythonExecutable() != nil
        var runtimeModulesAvailable = false
        let reason: String
        if let unsupported = unsupportedReason(descriptor) { reason = unsupported }
        else if !hasScript { reason = "specialist.py is not packaged/available" }
        else if !hasRuntime { reason = "isolated Python runtime is not installed — run scripts/setup_models.sh --specialist-runtime-only" }
        else if !provisioned {
            reason = descriptor.gated
                ? "Pinned model is not provisioned (this model is gated and requires accepted access)."
                : "Pinned specialist checkpoint is not provisioned."
        } else if let script {
            let runtime = LocalModelBridge.runPython(
                [script.path, "--runtime-check", descriptor.id], timeout: 8)
            if runtime.exitCode != 0 {
                let detail = (runtime.stderr.isEmpty ? runtime.stdout : runtime.stderr)
                    .split(whereSeparator: \.isNewline).first.map(String.init)
                    ?? "required Python modules are unavailable"
                reason = "specialist runtime unavailable — \(detail)"
            } else {
                runtimeModulesAvailable = true
                reason = "Pinned local specialist snapshot is available; runtime remains offline-only."
            }
        } else {
            reason = "specialist.py is not packaged/available"
        }
        return EmbeddingProviderPreflight(
            providerID: descriptor.id,
            available: unsupportedReason(descriptor) == nil && hasScript && hasRuntime && provisioned
                && runtimeModulesAvailable,
            reason: reason,
            artifacts: [descriptor.hfID + "@" + descriptor.revisionPrefix],
            dependencies: [descriptor.runtime])
    }

    public static func siglipDimension(for descriptor: LocalModelDescriptor) -> Int? {
        switch descriptor.id {
        case LocalModelStack.siglip2Base.id: return siglipBaseDimension
        case LocalModelStack.siglip2So400m.id: return siglipSo400mDimension
        default: return nil
        }
    }

    public func embedSigLIPImage(_ bytes: Data,
                                 model: LocalModelDescriptor = LocalModelStack.siglip2So400m,
                                 timeout: TimeInterval = 30) -> EmbeddingVector? {
        guard model.capability == .imageSemantic,
              let dimension = Self.siglipDimension(for: model),
              bytes.count > 0, bytes.count <= Self.maxImageBytes,
              Self.isProvisioned(model), let worker else { return nil }
        let request: [String: Any] = [
            "op": "siglip_image", "model": model.id,
            "data_b64": bytes.base64EncodedString(),
        ]
        guard let object = worker.call(request, timeout: timeout), object["error"] == nil,
              let data = Self.vectorData(object, expectedDimension: dimension) else { return nil }
        return EmbeddingVector(spaceID: Self.siglipSpaceID(for: model), dim: dimension, data: data)
    }

    /// Execute one real grouped processor/model call in the already-warm
    /// specialist worker. The same hard 8-image / 64-MiB raw-byte limits are
    /// enforced on both sides of the JSONL boundary so production callers
    /// cannot turn batching into an accidental unified-memory stress test.
    public func embedSigLIPImages(
        _ items: [SpecialistImageEmbeddingBatchItem],
        model: LocalModelDescriptor = LocalModelStack.siglip2So400m,
        timeout: TimeInterval = 60
    ) -> [SpecialistImageEmbeddingBatchResult]? {
        guard model.capability == .imageSemantic,
              Self.siglipDimension(for: model) != nil,
              !items.isEmpty, items.count <= Self.maxBatchImages,
              Self.isProvisioned(model), let worker else { return nil }

        var seenIDs = Set<String>()
        var totalRawBytes = 0
        var requestItems: [[String: Any]] = []
        requestItems.reserveCapacity(items.count)
        for item in items {
            guard !item.id.isEmpty, item.id.count <= 128,
                  seenIDs.insert(item.id).inserted,
                  !item.bytes.isEmpty, item.bytes.count <= Self.maxImageBytes,
                  item.bytes.count <= Self.maxBatchRawBytes - totalRawBytes else { return nil }
            totalRawBytes += item.bytes.count
            requestItems.append([
                "id": item.id,
                "data_b64": item.bytes.base64EncodedString(),
            ])
        }

        let request: [String: Any] = [
            "op": "siglip_image_batch",
            "model": model.id,
            "items": requestItems,
        ]
        return Self.parseSigLIPBatchResponse(
            worker.call(request, timeout: timeout),
            model: model,
            expectedIDs: items.map(\.id))
    }

    public func embedSigLIPText(_ text: String,
                                model: LocalModelDescriptor = LocalModelStack.siglip2So400m,
                                timeout: TimeInterval = 20) -> EmbeddingVector? {
        let clipped = String(text.prefix(16_000))
        guard model.capability == .imageSemantic,
              let dimension = Self.siglipDimension(for: model),
              !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.isProvisioned(model), let worker else { return nil }
        let request: [String: Any] = ["op": "siglip_text", "model": model.id, "text": clipped]
        guard let object = worker.call(request, timeout: timeout), object["error"] == nil,
              let data = Self.vectorData(object, expectedDimension: dimension) else { return nil }
        return EmbeddingVector(spaceID: Self.siglipSpaceID(for: model), dim: dimension, data: data)
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

    public func classifyText(model: LocalModelDescriptor,
                             evidence: SpecialistEvidence,
                             timeout: TimeInterval = 120) -> SpecialistClassification? {
        guard model.capability == .textReasoning, Self.isProvisioned(model), let worker else { return nil }
        defer { _ = worker.call(["op": "release", "model": model.id], timeout: 8) }
        return Self.parseClassification(
            worker.call(["op": "classify_text", "evidence": evidence.jsonObject], timeout: timeout),
            modelID: model.id)
    }

    public static func siglipSpaceID(for descriptor: LocalModelDescriptor) -> String {
        "siglip2-joint:\(descriptor.id):\(descriptor.revisionPrefix):naflex-v1"
    }

    /// Compatibility identity for the original So400m-only provider.
    public static var siglipSpaceID: String {
        siglipSpaceID(for: LocalModelStack.siglip2So400m)
    }
    public static var dinoSpaceID: String {
        "dinov3-visual:\(LocalModelStack.dinov3.revisionPrefix):vitb16-v1"
    }

    private static func unsupportedReason(_ descriptor: LocalModelDescriptor) -> String? {
        #if os(macOS)
        if descriptor.id == LocalModelStack.paddleOCR.id {
            return "PaddleOCR-VL is not supported on macOS CPU/Apple silicon; native Vision OCR remains enabled."
        }
        #endif
        return nil
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

    /// Internal parser seam so contract tests can prove that a batch cannot
    /// silently reorder IDs, change model spaces, or smuggle malformed vectors
    /// into the catalog without requiring a multi-gigabyte checkpoint in CI.
    static func parseSigLIPBatchResponse(
        _ object: [String: Any]?,
        model: LocalModelDescriptor,
        expectedIDs: [String]
    ) -> [SpecialistImageEmbeddingBatchResult]? {
        guard let object, object["error"] == nil,
              model.capability == .imageSemantic,
              let dimension = siglipDimension(for: model),
              object["model"] as? String == model.id,
              object["space"] as? String == "\(model.id)-joint",
              object["count"] as? Int == expectedIDs.count,
              let rows = object["items"] as? [[String: Any]],
              rows.count == expectedIDs.count else { return nil }

        var results: [SpecialistImageEmbeddingBatchResult] = []
        results.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            guard let id = row["id"] as? String,
                  id == expectedIDs[index],
                  let data = vectorData(row, expectedDimension: dimension) else { return nil }
            results.append(SpecialistImageEmbeddingBatchResult(
                id: id,
                vector: EmbeddingVector(
                    spaceID: siglipSpaceID(for: model),
                    dim: dimension,
                    data: data)))
        }
        return results
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

    private static func specialistRoots() -> [URL] {
        var candidates: [URL] = []
        let environment = ProcessInfo.processInfo.environment
        if let list = environment["LIBRARIAN_SPECIALIST_MODELS_DIRS"] {
            candidates.append(contentsOf: list.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        }
        if let single = environment["LIBRARIAN_SPECIALIST_MODELS_DIR"], !single.isEmpty {
            candidates.append(URL(fileURLWithPath: single))
        }
        candidates.append(contentsOf: LocalModelBridge.modelsRoots().map {
            $0.appendingPathComponent("specialists", isDirectory: true)
        })
        var seen = Set<String>()
        return candidates.filter {
            seen.insert($0.standardizedFileURL.path).inserted
                && FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private static func isSafeRelativePath(_ relative: String) -> Bool {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\") else { return false }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
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
            let candidates = SpecialistModelBridge.specialistRoots()
            guard let python = LocalModelBridge.pythonExecutable(), !candidates.isEmpty else { return nil }
            let process = Process()
            process.executableURL = python
            process.arguments = [script.path, "--worker"]
            var env = ProcessInfo.processInfo.environment
            env["HF_HUB_OFFLINE"] = "1"
            env["TRANSFORMERS_OFFLINE"] = "1"
            env["HF_DATASETS_OFFLINE"] = "1"
            env["HF_HUB_DISABLE_TELEMETRY"] = "1"
            env["DO_NOT_TRACK"] = "1"
            env["LIBRARIAN_SPECIALIST_MODELS_DIRS"] = candidates.map(\.path).joined(separator: ":")
            if env["LIBRARIAN_SPECIALIST_MODELS_DIR"] == nil, let root = candidates.first {
                env["LIBRARIAN_SPECIALIST_MODELS_DIR"] = root.path
            }
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
            closeLocked()
        }

        private func closeLocked() {
            guard !closed else { return }
            closed = true
            try? input.fileHandleForWriting.close()
            guard process.isRunning else { return }
            process.terminate()
            let gracefulDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < gracefulDeadline { usleep(20_000) }
            if process.isRunning { process.interrupt() }
            let interruptDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < interruptDeadline { usleep(20_000) }
            #if canImport(Darwin)
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            #endif
            process.waitUntilExit()
        }

        func call(_ request: [String: Any], timeout: TimeInterval) -> [String: Any]? {
            lock.lock()
            defer { lock.unlock() }
            guard !closed, process.isRunning,
                  var data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
            guard data.count <= 96 * 1024 * 1024 else { return nil }
            data.append(10)
            let deadline = Date().addingTimeInterval(max(0.1, timeout))
            guard write(data, deadline: deadline) else {
                closeLocked()
                return nil
            }
            guard let response = readResponse(deadline: deadline) else {
                // A timeout, malformed line, EOF, or oversized response makes
                // the JSONL stream unsynchronized. Do not reuse the worker.
                closeLocked()
                return nil
            }
            return response
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
    public let providerID: String
    public let model: LocalModelDescriptor
    private let bridge: SpecialistModelBridge

    public init(model: LocalModelDescriptor = LocalModelStack.siglip2So400m,
                bridge: SpecialistModelBridge = SpecialistModelBridge()) {
        precondition(model.capability == .imageSemantic, "SigLIP provider requires an image-semantic model")
        self.model = model
        self.bridge = bridge
        self.providerID = "specialist:\(model.id)@\(model.revisionPrefix):naflex-v1"
    }

    public var preflight: EmbeddingProviderPreflight {
        SpecialistModelBridge.preflight(model)
    }
    public var imageModelID: String { "image:\(providerID)" }
    public var textModelID: String { "text:\(providerID)" }

    public func embedText(_ text: String) -> EmbeddingVector? {
        bridge.embedSigLIPText(text, model: model)
    }
    public func embedImageBytes(_ bytes: Data) -> EmbeddingVector? {
        bridge.embedSigLIPImage(bytes, model: model)
    }
    public func embedImageBatch(
        _ items: [SpecialistImageEmbeddingBatchItem],
        timeout: TimeInterval = 60
    ) -> [SpecialistImageEmbeddingBatchResult]? {
        bridge.embedSigLIPImages(items, model: model, timeout: timeout)
    }
    public func embedJointText(_ text: String) -> EmbeddingVector? {
        bridge.embedSigLIPText(text, model: model)
    }
}
