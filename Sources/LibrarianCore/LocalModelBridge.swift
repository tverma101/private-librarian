import Accelerate
import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Bridge to optional downloaded local models (CLIP / MiniLM) running 100% offline.
///
/// - No network entitlement is ever required.
/// - No `Models/` path is added to the indexed tree.
/// - If no model is provisioned, or the helper is missing deps, every call
///   returns nil and Vision remains the sole signal — no crash, no blocking.
///
/// The Python helper `scripts/embed.py` runs with `local_files_only=True` and
/// is verified offline by `embed --check`. Swift side is a thin, timeout-bounded
/// subprocess wrapper with no path interpolation or shell.
public struct LocalModelBridge: Sendable {
    private final class BoundedDataBox: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var value = Data()

        init(limit: Int) {
            self.limit = limit
            value.reserveCapacity(min(limit, 64 * 1024))
        }

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard value.count < limit else { return }
            value.append(data.prefix(limit - value.count))
        }

        func data() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    public enum Model: String, CaseIterable, Sendable {
        case clipImage = "clip-vit-base-patch32" // 512-d image embedding (CLIP ViT-B/32)
        case miniLMText = "all-MiniLM-L6-v2"      // 384-d text embedding (MiniLM)
    }

    public static func expectedDimension(_ model: Model) -> Int {
        switch model {
        case .clipImage: return 512
        case .miniLMText: return 384
        }
    }

    /// Whether the bridge can run on this machine right now (python + deps + at least one model).
    public static func isAvailable() -> Bool {
        guard let scriptsDir = scriptsDir() else { return false }
        let embed = scriptsDir.appendingPathComponent("embed.py")
        guard FileManager.default.fileExists(atPath: embed.path) else { return false }
        let check = runPython([embed.path, "--check"], timeout: 6)
        return check.exitCode == 0
    }

    // MARK: - Persistent worker (Issue #4 P1: avoid per-file cold start)

    /// Long-lived JSONL worker for the indexing pipeline. Keeps the helper
    /// process + model warm across many files (one warm import per index
    /// session). Non-persistent per-call path remains for one-off searches
    /// via runPython().
    public final class PersistentWorker: @unchecked Sendable {
        private let proc: Process
        private let stdin: Pipe
        private let stdout: Pipe
        private let stderr: Pipe
        private let lock = NSLock()
        private var closed = false
        private var buffer = Data()

        /// Start `embed.py --worker [model]` with pinned python + offline env.
        public init?(model: Model? = nil) {
            guard let scriptsDir = LocalModelBridge.scriptsDir() else { return nil }
            guard let python = LocalModelBridge.pythonExecutable() else { return nil }
            let embed = scriptsDir.appendingPathComponent("embed.py").path
            var args: [String] = [embed, "--worker"]
            if let m = model { args += ["--model", m.rawValue] }
            let proc = Process()
            proc.executableURL = python
            proc.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["HF_HUB_OFFLINE"] = "1"; env["TRANSFORMERS_OFFLINE"] = "1"
            env["HF_DATASETS_OFFLINE"] = "1"; env["HF_HUB_DISABLE_TELEMETRY"] = "1"; env["DO_NOT_TRACK"] = "1"
            if env["LIBRARIAN_MODELS_DIR"] == nil,
               let root = LocalModelBridge.modelsRoot(for: args) {
                env["LIBRARIAN_MODELS_DIR"] = root.path
            }
            proc.environment = env
            let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
            proc.standardInput = stdin; proc.standardOutput = stdout; proc.standardError = stderr
            // Drain stderr asynchronously so a noisy worker cannot fill the pipe
            // and block. Async read never touches `self` before init completes.
            let errFH = stderr.fileHandleForReading
            DispatchQueue.global(qos: .utility).async {
                errFH.readToEndOfFileInBackgroundAndNotify()
            }
            do { try proc.run() } catch { return nil }
            usleep(150_000)
            if !proc.isRunning { return nil }
            self.proc = proc; self.stdin = stdin; self.stdout = stdout; self.stderr = stderr
            // Ensure both ends are non-blocking so a stalled helper cannot
            // block a caller while a timeout is being enforced.
            for fd in [stdin.fileHandleForWriting.fileDescriptor,
                       stdout.fileHandleForReading.fileDescriptor] {
                let flags = fcntl(fd, F_GETFL)
                if flags != -1 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
            }
        }

        deinit { close() }

        public func close() {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            terminateLocked()
        }

        /// Send one JSON request line and read one JSON response line with a trustworthy timeout.
        private func call(_ req: [String: Any], timeout: TimeInterval) -> [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            guard !closed, proc.isRunning else { return nil }
            guard let line = try? JSONSerialization.data(withJSONObject: req) else { return nil }
            let deadline = Date().addingTimeInterval(max(0, timeout))
            guard writeRequest(line + Data([10]), deadline: deadline) else {
                closed = true
                terminateLocked()
                return nil
            }
            let fd = stdout.fileHandleForReading.fileDescriptor
            while Date() < deadline {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ms = max(0, Int32(deadline.timeIntervalSinceNow * 1000))
                let pr = poll(&pfd, 1, ms)
                if pr > 0 {
                    var bytes = [UInt8](repeating: 0, count: 16 * 1024)
                    let count = bytes.withUnsafeMutableBytes { raw -> Int in
                        guard let base = raw.baseAddress else { return 0 }
                        return Darwin.read(fd, base, raw.count)
                    }
                    if count > 0 {
                        buffer.append(contentsOf: bytes[..<count])
                        guard buffer.count <= 16 * 1024 * 1024 else {
                            closed = true
                            terminateLocked()
                            return nil
                        }
                        if let nl = buffer.firstIndex(of: 10) {
                            let lineData = buffer.prefix(upTo: nl)
                            buffer.removeSubrange(...nl)
                            if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                                return obj
                            }
                        }
                    } else if count == 0, !proc.isRunning {
                        return nil
                    } else if count < 0, errno != EINTR, errno != EAGAIN, errno != EWOULDBLOCK {
                        closed = true
                        terminateLocked()
                        return nil
                    }
                } else if pr == 0 {
                    closed = true
                    terminateLocked()
                    return nil // timeout
                } else {
                    if errno == EINTR { continue }
                    closed = true
                    terminateLocked()
                    return nil
                }
                if !proc.isRunning, buffer.isEmpty { return nil }
            }
            closed = true
            terminateLocked()
            return nil
        }

        private func writeRequest(_ data: Data, deadline: Date) -> Bool {
            let fd = stdin.fileHandleForWriting.fileDescriptor
            var offset = 0
            while offset < data.count {
                let count = data.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                }
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                if count < 0, errno != EAGAIN, errno != EWOULDBLOCK { return false }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ms = max(0, Int32(deadline.timeIntervalSinceNow * 1000))
                if ms <= 0 { return false }
                let ready = poll(&pfd, 1, ms)
                if ready < 0, errno == EINTR { continue }
                if ready <= 0 { return false }
            }
            return true
        }

        private func terminateLocked() {
            try? stdin.fileHandleForWriting.close()
            guard proc.isRunning else { return }
            proc.terminate()
            let firstDeadline = Date().addingTimeInterval(0.5)
            while proc.isRunning && Date() < firstDeadline { usleep(20_000) }
            if proc.isRunning { proc.interrupt() }
            let secondDeadline = Date().addingTimeInterval(0.5)
            while proc.isRunning && Date() < secondDeadline { usleep(20_000) }
            if proc.isRunning { _ = kill(proc.processIdentifier, SIGKILL) }
        }

        public func embedImageBytes(_ bytes: Data, timeout: TimeInterval = 20) -> (dim: Int, data: Data)? {
            let b64 = bytes.base64EncodedString()
            guard let obj = call(["op": "image_b64", "data": b64], timeout: timeout),
                  let dim = obj["dim"] as? Int, dim == LocalModelBridge.expectedDimension(.clipImage),
                  let vec = obj["vector"] as? [Double],
                  let out = LocalModelBridge.vectorData(vec, expectedDim: dim) else { return nil }
            return (dim, out)
        }

        public func embedText(_ text: String, timeout: TimeInterval = 10) -> (dim: Int, data: Data)? {
            let clipped = String(text.prefix(4000))
            guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard let obj = call(["op": "text", "data": clipped], timeout: timeout),
                  let dim = obj["dim"] as? Int, dim == LocalModelBridge.expectedDimension(.miniLMText),
                  let vec = obj["vector"] as? [Double],
                  let out = LocalModelBridge.vectorData(vec, expectedDim: dim) else { return nil }
            return (dim, out)
        }

        public func embedClipText(_ text: String, timeout: TimeInterval = 10) -> (dim: Int, data: Data)? {
            let clipped = String(text.prefix(4000))
            guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard let obj = call(["op": "clip_text", "data": clipped], timeout: timeout),
                  let dim = obj["dim"] as? Int, dim == LocalModelBridge.expectedDimension(.clipImage),
                  let vec = obj["vector"] as? [Double],
                  let out = LocalModelBridge.vectorData(vec, expectedDim: dim) else { return nil }
            return (dim, out)
        }
    }

    private struct PinnedModelProvenance {
        let hfID: String
        let revision: String
    }

    private static func pinnedProvenance(for model: Model) -> PinnedModelProvenance {
        switch model {
        case .clipImage:
            return PinnedModelProvenance(
                hfID: "openai/clip-vit-base-patch32",
                revision: "3d74acf9a28c67741b2f4f2ea7635f0aaf6f0268")
        case .miniLMText:
            return PinnedModelProvenance(
                hfID: "sentence-transformers/all-MiniLM-L6-v2",
                revision: "1110a243fdf4706b3f48f1d95db1a4f5529b4d41")
        }
    }

    private static func modelHasArtifacts(_ directory: URL, model: Model) -> Bool {
        let hasConfig = FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path)
        let hasWeights = ["pytorch_model.bin", "model.safetensors", "tf_model.h5", "flax_model.msgpack"].contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        // This is a fast discovery predicate used by the app/UI and by the
        // helper path selection. The helper's first --check/inference call
        // performs the full manifest hash verification, so merely asking
        // whether a model exists never re-hashes hundreds of megabytes.
        return hasConfig && hasWeights && hasTrustedProvenance(
            directory, model: model, verifyHashes: false)
    }

    /// Pick the installed model root for the helper instead of assuming that
    /// the current working directory is the repository. This is what makes a
    /// packaged app's Application Support/Resources model installation work.
    private static func modelsRoot(for args: [String]) -> URL? {
        let roots = modelsRoots()
        let requested = args.compactMap { Model(rawValue: $0) }
        if let model = requested.first,
           let root = roots.first(where: { modelHasArtifacts($0.appendingPathComponent(model.rawValue), model: model) }) {
            return root
        }
        return roots.first(where: { root in
            Model.allCases.allSatisfy { modelHasArtifacts(root.appendingPathComponent($0.rawValue), model: $0) }
        }) ?? roots.first(where: { root in
            Model.allCases.contains { modelHasArtifacts(root.appendingPathComponent($0.rawValue), model: $0) }
        })
    }

    /// Check the non-network identity manifest produced by the provisioner.
    /// File bytes are hashed by the provisioning/verification command; this
    /// fast runtime gate verifies that every manifest entry is present, safe,
    /// and tied to the pinned model identity before a helper can load it.
    private static func hasTrustedProvenance(_ directory: URL, model: Model,
                                              verifyHashes: Bool = true) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("provenance.json")),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["schema"] as? Int == 2,
              let modelName = record["model"] as? String,
              modelName == model.rawValue,
              let hfID = record["hf_id"] as? String,
              let revision = record["revision"] as? String else { return false }
        let pinned = pinnedProvenance(for: model)
        guard hfID == pinned.hfID, revision == pinned.revision,
              let expectedFiles = record["expected_files"] as? [String: Any],
              !expectedFiles.isEmpty else { return false }
        let weightNames = ["pytorch_model.bin", "model.safetensors", "tf_model.h5", "flax_model.msgpack"]
        guard expectedFiles["config.json"] != nil,
              weightNames.contains(where: { expectedFiles[$0] != nil }) else { return false }

        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        for (relative, value) in expectedFiles {
            guard let expected = value as? String,
                  expected.count == 64,
                  expected.allSatisfy({ $0.isHexDigit }) else { return false }
            let path = directory.appendingPathComponent(relative)
                .resolvingSymlinksInPath().standardizedFileURL
            guard path.path == root.path || path.path.hasPrefix(root.path + "/"),
                  let values = try? path.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return false }
            if verifyHashes && sha256File(path) != expected.lowercased() { return false }
        }
        return true
    }

    static func sha256File(_ path: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1 << 20)
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a specific, pinned checkpoint is provisioned under any Models root.
    public static func isProvisioned(_ model: Model) -> Bool {
        for root in modelsRoots() {
            let dir = root.appendingPathComponent(model.rawValue)
            if modelHasArtifacts(dir, model: model) {
                return true
            }
        }
        return false
    }

    /// Embed raw image bytes via stdin (broker-only; helper never sees a raw path).
    /// Returned FileIdentity-agnostic: bytes already produced by SourceBroker.
    public static func embedImageBytes(_ bytes: Data, model: Model = .clipImage, timeout: TimeInterval = 20) -> (dim: Int, data: Data)? {
        guard model == .clipImage, isProvisioned(model), !bytes.isEmpty else { return nil }
        guard let scriptsDir = scriptsDir() else { return nil }
        let embed = scriptsDir.appendingPathComponent("embed.py").path
        let result = runPython([embed, "--stdin-image", "--model", model.rawValue], input: bytes, timeout: timeout)
        return parseEmbedding(from: result.stdout, expectedDim: expectedDimension(.clipImage))
    }

    /// Compatibility wrapper for existing path-based callers. SourceBroker
    /// owns the path and the local helper receives complete bytes on stdin.
    public static func embedImage(at path: String, model: Model = .clipImage, timeout: TimeInterval = 20) -> (dim: Int, data: Data)? {
        guard let bytes = try? SourceBroker().completeSnapshot(path, maxBytes: VisionImageAnalyzer.maxImageContainerBytes) else { return nil }
        return embedImageBytes(bytes, model: model, timeout: timeout)
    }

    /// Embed text using local MiniLM (mean-pooled, L2-normalized).
    /// Text hits stdin so argv never leaks the payload.
    public static func embedText(_ text: String, model: Model = .miniLMText, timeout: TimeInterval = 10) -> (dim: Int, data: Data)? {
        let clipped = String(text.prefix(4000))
        guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard model == .miniLMText, isProvisioned(model) else { return nil }
        guard let scriptsDir = scriptsDir() else { return nil }
        let embed = scriptsDir.appendingPathComponent("embed.py").path
        let result = runPython([embed, "--stdin-text", "--model", model.rawValue],
                               input: Data(clipped.utf8), timeout: timeout)
        return parseEmbedding(from: result.stdout, expectedDim: expectedDimension(.miniLMText))
    }

    /// Embed natural-language text into the CLIP joint image-text space (512-d, L2-normalized).
    /// Enables text-to-image search: text and image CLIP vectors share one cosine space.
    public static func embedClipText(_ text: String, timeout: TimeInterval = 10) -> (dim: Int, data: Data)? {
        let clipped = String(text.prefix(4000))
        guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard isProvisioned(.clipImage) else { return nil }
        guard let scriptsDir = scriptsDir() else { return nil }
        let embed = scriptsDir.appendingPathComponent("embed.py").path
        let result = runPython([embed, "--stdin-clip-text"], input: Data(clipped.utf8), timeout: timeout)
        return parseEmbedding(from: result.stdout, expectedDim: expectedDimension(.clipImage))
    }

    // MARK: - Catalog helpers

    /// Persist a normalized Float32 embedding to the `embeddings` table (encrypted).
    @discardableResult
    public static func saveEmbedding(fileID: String, catalog: Catalog, vector: Data, dim: Int, model: Model) -> Bool {
        do {
            try catalog.saveEmbedding(fileID: fileID, model: model.rawValue, dim: dim, vector: vector)
            return true
        } catch { return false }
    }

    /// Compatibility batch wrapper. SourceBroker converts each source path to
    /// a complete snapshot before the helper sees any bytes; the helper never
    /// receives the caller's source paths.
    public static func embedImagesBatch(paths: [String], model: Model = .clipImage, timeout: TimeInterval = 60) -> [String: (dim: Int, data: Data)] {
        guard model == .clipImage, isProvisioned(model), !paths.isEmpty else { return [:] }
        let broker = SourceBroker()
        let items = paths.enumerated().compactMap { index, path -> (id: String, bytes: Data)? in
            guard let bytes = try? broker.completeSnapshot(path, maxBytes: VisionImageAnalyzer.maxImageContainerBytes) else { return nil }
            return (String(index), bytes)
        }
        let embedded = embedImagesBatchBytes(items: items, model: model, timeout: timeout)
        var result: [String: (dim: Int, data: Data)] = [:]
        for (id, value) in embedded {
            guard let index = Int(id), paths.indices.contains(index) else { continue }
            result[paths[index]] = value
        }
        return result
    }

    /// Batch-embed raw images keyed by an opaque id (bytes provided by caller via stdin-batch).
    /// Returned map is keyed by the caller-supplied ids. No path is exposed to the helper.
    public static func embedImagesBatchBytes(
        items: [(id: String, bytes: Data)], model: Model = .clipImage, timeout: TimeInterval = 60
    ) -> [String: (dim: Int, data: Data)] {
        guard model == .clipImage, isProvisioned(model), !items.isEmpty else { return [:] }
        var out: [String: (Int, Data)] = [:]
        guard let worker = PersistentWorker(model: model) else { return [:] }
        defer { worker.close() }
        for item in items {
            if let embedded = worker.embedImageBytes(item.bytes, timeout: timeout) {
                out[item.id] = embedded
            }
        }
        return out
    }

    // MARK: - Search helpers (cosine on normalized vectors)

    /// Cosine similarity for two L2-normalized Float32 blobs (little-endian, vDSP-accelerated).
    public static func cosineSimilarity(_ a: Data, _ b: Data) -> Float? {
        guard !a.isEmpty, a.count == b.count, a.count % 4 == 0 else { return nil }
        let n = a.count / 4
        var dot: Float = 0
        var finite = true
        a.withUnsafeBytes { ap in
            b.withUnsafeBytes { bp in
                guard let pa = ap.baseAddress?.assumingMemoryBound(to: Float.self),
                      let pb = bp.baseAddress?.assumingMemoryBound(to: Float.self) else {
                    finite = false
                    return
                }
                for index in 0..<n where !pa[index].isFinite || !pb[index].isFinite {
                    finite = false
                    break
                }
                guard finite else { return }
                vDSP_dotpr(pa, 1, pb, 1, &dot, vDSP_Length(n))
            }
        }
        guard finite, dot.isFinite else { return nil }
        if dot == 0 {
            // Fallback if withUnsafeBytes leased a reallocated buffer — recompute scalar safely.
            var s: Double = 0
            for i in 0..<n {
                let fa = a.withUnsafeBytes { $0.load(fromByteOffset: i*4, as: Float.self) }
                let fb = b.withUnsafeBytes { $0.load(fromByteOffset: i*4, as: Float.self) }
                s += Double(fa * fb)
            }
            guard s.isFinite else { return nil }
            return Float(max(-1, min(1, s)))
        }
        return Float(max(-1, min(1, Double(dot))))
    }

    /// Split a long document into overlapping text chunks for chunked embedding.
    public static func textChunks(_ text: String, chunkChars: Int = 900, overlapChars: Int = 120) -> [String] {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count > chunkChars else { return s.isEmpty ? [] : [s] }
        var out: [String] = []
        var start = s.startIndex
        while start < s.endIndex {
            let end = s.index(start, offsetBy: chunkChars, limitedBy: s.endIndex) ?? s.endIndex
            out.append(String(s[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            if end == s.endIndex { break }
            start = s.index(end, offsetBy: -overlapChars, limitedBy: s.startIndex) ?? s.startIndex
        }
        return out.filter { !$0.isEmpty }
    }

    /// Chunk-aware text embedding — returns one embedding per chunk (for files that exceed a single embedding).
    public static func embedTextChunks(_ text: String) -> [(dim: Int, data: Data)] {
        textChunks(text).compactMap { embedText($0) }
    }

    // MARK: - Internals

    static func parseEmbedding(from json: String, expectedDim: Int? = nil) -> (dim: Int, data: Data)? {
        guard let raw = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let dim = o["dim"] as? Int,
              let vec = o["vector"] as? [Double],
              dim > 0, expectedDim == nil || expectedDim == dim,
              let data = vectorData(vec, expectedDim: dim) else { return nil }
        return (dim, data)
    }

    private static func vectorData(_ vector: [Double], expectedDim: Int) -> Data? {
        guard vector.count == expectedDim, expectedDim > 0 else { return nil }
        var data = Data(capacity: expectedDim * 4)
        for value in vector {
            guard value.isFinite else { return nil }
            var float = Float(value)
            guard float.isFinite else { return nil }
            withUnsafeBytes(of: &float) { data.append(contentsOf: $0) }
        }
        return data
    }

    struct RunResult { let stdout: String; let stderr: String; let exitCode: Int32 }

    /// Locate the explicitly configured or locally provisioned Python runtime.
    /// Packaged apps cannot rely on the user's shell PATH, so the optional
    /// model runtime is also searched beside the app resources, in the repo's
    /// ignored `.model-runtime`, and in Application Support.
    private static func pythonExecutable() -> URL? {
        var candidates: [String] = []
        if let configured = ProcessInfo.processInfo.environment["LIBRARIAN_PYTHON"],
           !configured.isEmpty {
            candidates.append(configured)
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("model-runtime/bin/python3").path)
        }
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport
                .appendingPathComponent("PrivateLibrarian/model-runtime/bin/python3").path)
        }
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            candidates.append(URL(fileURLWithPath: home)
                .appendingPathComponent("Library/Containers/com.tejas.private-librarian/Data/Library/Application Support/PrivateLibrarian/model-runtime/bin/python3").path)
        }
        if let repo = repoRoot() {
            candidates.append(repo.appendingPathComponent(".model-runtime/bin/python3").path)
        }
        candidates += ["/usr/local/bin/python3", "/opt/homebrew/bin/python3", "/usr/bin/python3"]
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    static func runPython(_ args: [String], input: Data? = nil, timeout: TimeInterval) -> RunResult {
        guard let python = pythonExecutable() else {
            return RunResult(stdout: "", stderr: "no python3", exitCode: 127)
        }
        let proc = Process()
        proc.executableURL = python
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        // Enforce offline: even with local_files_only, be explicit.
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
        env["HF_DATASETS_OFFLINE"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["DO_NOT_TRACK"] = "1"
        if env["LIBRARIAN_MODELS_DIR"] == nil,
           let root = LocalModelBridge.modelsRoot(for: args) {
            env["LIBRARIAN_MODELS_DIR"] = root.path
        }
        proc.environment = env
        // No shell, no PATH interpolation.
        let outPipe = Pipe(), errPipe = Pipe()
        let inPipe = input != nil ? Pipe() : nil
        proc.standardOutput = outPipe; proc.standardError = errPipe
        proc.standardInput = inPipe
        do { try proc.run() } catch { return RunResult(stdout: "", stderr: "\(error)", exitCode: 127) }
        let outputDone = DispatchSemaphore(value: 0)
        let errorDone = DispatchSemaphore(value: 0)
        let outputBox = BoundedDataBox(limit: 16 * 1024 * 1024)
        let errorBox = BoundedDataBox(limit: 1 * 1024 * 1024)
        DispatchQueue.global(qos: .utility).async {
            let handle = outPipe.fileHandleForReading
            while true {
                let chunk = handle.readData(ofLength: 64 * 1024)
                if chunk.isEmpty { break }
                outputBox.append(chunk)
            }
            outputDone.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            let handle = errPipe.fileHandleForReading
            while true {
                let chunk = handle.readData(ofLength: 64 * 1024)
                if chunk.isEmpty { break }
                errorBox.append(chunk)
            }
            errorDone.signal()
        }
        let inputDone = DispatchSemaphore(value: 0)
        if let inPipe, let input {
            DispatchQueue.global(qos: .utility).async {
                let handle = inPipe.fileHandleForWriting
                do {
                    let chunkSize = 64 * 1024
                    var offset = 0
                    while offset < input.count {
                        let end = min(offset + chunkSize, input.count)
                        try handle.write(contentsOf: input[offset..<end])
                        offset = end
                    }
                } catch {
                    // The helper may exit early; the caller only needs the
                    // process result and bounded diagnostics.
                }
                try? handle.close()
                inputDone.signal()
            }
        } else {
            inputDone.signal()
        }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        var didTimeout = false
        while proc.isRunning, Date() < deadline {
            usleep(30_000)
        }
        if proc.isRunning {
            didTimeout = true
            try? inPipe?.fileHandleForWriting.close()
            proc.terminate()
            let firstDeadline = Date().addingTimeInterval(0.5)
            while proc.isRunning && Date() < firstDeadline { usleep(20_000) }
            if proc.isRunning { proc.interrupt() }
            let secondDeadline = Date().addingTimeInterval(0.5)
            while proc.isRunning && Date() < secondDeadline { usleep(20_000) }
            if proc.isRunning { _ = kill(proc.processIdentifier, SIGKILL) }
        }
        proc.waitUntilExit()
        _ = inputDone.wait(timeout: .now() + 1)
        _ = outputDone.wait(timeout: .now() + 1)
        _ = errorDone.wait(timeout: .now() + 1)
        let outData = outputBox.data()
        let errData = errorBox.data()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        let code: Int32 = didTimeout ? 124 : proc.terminationStatus
        let errMsg = didTimeout ? "timeout after \(timeout)s" : err
        return RunResult(stdout: out, stderr: errMsg, exitCode: code)
    }

    /// Locate embed.py in both SPM (repo root) and bundled app (Resources/scripts).
    static func scriptsDir() -> URL? {
        // Allow explicit override for packaged Helper copies and tests.
        if let env = ProcessInfo.processInfo.environment["LIBRARIAN_SCRIPTS_DIR"],
           FileManager.default.fileExists(atPath: URL(fileURLWithPath: env).appendingPathComponent("embed.py").path) {
            return URL(fileURLWithPath: env)
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("scripts"),
           FileManager.default.fileExists(atPath: res.appendingPathComponent("embed.py").path) {
            return res
        }
        // SPM / tests: walk up from CWD to repo root (Package.swift marker)
        if let root = repoRoot() {
            let d = root.appendingPathComponent("scripts")
            if FileManager.default.fileExists(atPath: d.appendingPathComponent("embed.py").path) {
                return d
            }
        }
        return nil
    }

    /// Resolve Application Support + repo + bundled Resources Models roots; bundled .app uses Resources/Models.
    public static func modelsRoots() -> [URL] {
        var roots: [URL] = []
        if let env = ProcessInfo.processInfo.environment["LIBRARIAN_MODELS_DIR"] {
            roots.append(URL(fileURLWithPath: env))
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("Models"),
           FileManager.default.fileExists(atPath: res.path) {
            roots.append(res)
        }
        // Fallback: explicit Resources/Models inside bundle (same as above but via bundleURL)
        if let bundleModels = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Models").path as String?,
           FileManager.default.fileExists(atPath: bundleModels) {
            roots.append(URL(fileURLWithPath: bundleModels))
        }
        let asURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PrivateLibrarian/Models")
        if let asURL { roots.append(asURL) }
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            roots.append(URL(fileURLWithPath: home)
                .appendingPathComponent("Library/Containers/com.tejas.private-librarian/Data/Library/Application Support/PrivateLibrarian/Models"))
        }
        if let repo = repoRoot() { roots.append(repo.appendingPathComponent("Models")) }
        return roots
    }

    static func repoRoot() -> URL? {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
