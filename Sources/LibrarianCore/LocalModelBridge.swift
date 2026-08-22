import Accelerate
import Foundation

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

    public enum Model: String, Sendable {
        case clipImage = "clip-vit-base-patch32" // 512-d image embedding (CLIP ViT-B/32)
        case miniLMText = "all-MiniLM-L6-v2"      // 384-d text embedding (MiniLM)
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
            if let root = LocalModelBridge.repoRoot() { env["LIBRARIAN_MODELS_DIR"] = root.appendingPathComponent("Models").path }
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
            // Ensure stdout is non-blocking so availableData cannot block the caller.
            let fd = stdout.fileHandleForReading.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            if flags != -1 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        }

        deinit { close() }

        public func close() {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            try? stdin.fileHandleForWriting.close()
            if proc.isRunning { proc.terminate(); usleep(200_000); if proc.isRunning { proc.interrupt() } }
        }

        /// Send one JSON request line and read one JSON response line with a trustworthy timeout.
        private func call(_ req: [String: Any], timeout: TimeInterval) -> [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            guard !closed, proc.isRunning else { return nil }
            guard let line = try? JSONSerialization.data(withJSONObject: req),
                  let _ = try? stdin.fileHandleForWriting.write(contentsOf: line + Data([10])) else { return nil }
            let deadline = Date().addingTimeInterval(timeout)
            let fd = stdout.fileHandleForReading.fileDescriptor
            while Date() < deadline {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ms = max(0, Int32(deadline.timeIntervalSinceNow * 1000))
                let pr = poll(&pfd, 1, ms)
                if pr > 0, (pfd.revents & Int16(POLLIN)) != 0 {
                    let chunk = stdout.fileHandleForReading.readData(ofLength: 8192)
                    if !chunk.isEmpty {
                        buffer.append(chunk)
                        if let nl = buffer.firstIndex(of: 10) {
                            let lineData = buffer.prefix(upTo: nl)
                            buffer.removeSubrange(...nl)
                            if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] { return obj }
                            continue
                        }
                    } else if !proc.isRunning {
                        return nil
                    }
                } else if pr == 0 {
                    return nil // timeout
                } else {
                    if !proc.isRunning { return nil }
                    if errno == EINTR { continue }
                    usleep(5_000)
                }
                if !proc.isRunning, buffer.isEmpty { return nil }
            }
            return nil
        }

        public func embedImageBytes(_ bytes: Data, timeout: TimeInterval = 20) -> (dim: Int, data: Data)? {
            let b64 = bytes.base64EncodedString()
            guard let obj = call(["op": "image_b64", "data": b64], timeout: timeout),
                  let dim = obj["dim"] as? Int, let vec = obj["vector"] as? [Double], vec.count == dim else { return nil }
            var out = Data(capacity: dim*4); for v in vec { var f = Float(v); withUnsafeBytes(of: &f) { out.append(contentsOf: $0) } }
            return (dim, out)
        }

        public func embedText(_ text: String, timeout: TimeInterval = 10) -> (dim: Int, data: Data)? {
            let clipped = String(text.prefix(4000))
            guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard let obj = call(["op": "text", "data": clipped], timeout: timeout),
                  let dim = obj["dim"] as? Int, let vec = obj["vector"] as? [Double], vec.count == dim else { return nil }
            var out = Data(capacity: dim*4); for v in vec { var f = Float(v); withUnsafeBytes(of: &f) { out.append(contentsOf: $0) } }
            return (dim, out)
        }

        public func embedClipText(_ text: String, timeout: TimeInterval = 10) -> (dim: Int, data: Data)? {
            let clipped = String(text.prefix(4000))
            guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard let obj = call(["op": "clip_text", "data": clipped], timeout: timeout),
                  let dim = obj["dim"] as? Int, let vec = obj["vector"] as? [Double], vec.count == dim else { return nil }
            var out = Data(capacity: dim*4); for v in vec { var f = Float(v); withUnsafeBytes(of: &f) { out.append(contentsOf: $0) } }
            return (dim, out)
        }
    }

    /// Whether a specific model checkpoint is provisioned under any Models root.
    public static func isProvisioned(_ model: Model) -> Bool {
        for root in modelsRoots() {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("\(model.rawValue)/config.json").path) {
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
        return parseEmbedding(from: result.stdout)
    }

    /// Embed an image file (bounded read via SourceBroker path) using local CLIP.
    /// Returns normalized Float32 vector as Data (little-endian Float32) + dim, or nil.
    /// Legacy path-based path — prefer embedImageBytes when already holding broker bytes.
    public static func embedImage(at path: String, model: Model = .clipImage, timeout: TimeInterval = 20) -> (dim: Int, data: Data)? {
        guard model == .clipImage, isProvisioned(model) else { return nil }
        guard let scriptsDir = scriptsDir() else { return nil }
        // Decode under broker-bounded semantics (caps come from caller-supplied maxVisionBytes),
        // but helper input still goes through stdin so argv never leaks the path.
        guard let data = try? SourceBroker().boundedRead(path, limit: Int64(VisionImageAnalyzer.maxVisionBytes)) else { return nil }
        guard !data.isEmpty else { return nil }
        let embed = scriptsDir.appendingPathComponent("embed.py").path
        let result = runPython([embed, "--stdin-image", "--model", model.rawValue], input: data, timeout: timeout)
        return parseEmbedding(from: result.stdout)
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
        return parseEmbedding(from: result.stdout)
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
        return parseEmbedding(from: result.stdout)
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

    /// Batch-embed images listed in `paths` via `embed.py --batch-images` (single warm process).
    /// Bridges path-based callers that do not already hold broker bytes; stdin-bytes path
    /// is preferred inside the indexer pipeline. Returns map path -> (dim, Data).
    public static func embedImagesBatch(paths: [String], model: Model = .clipImage, timeout: TimeInterval = 60) -> [String: (dim: Int, data: Data)] {
        guard model == .clipImage, isProvisioned(model), !paths.isEmpty else { return [:] }
        guard let scriptsDir = scriptsDir() else { return [:] }
        let embed = scriptsDir.appendingPathComponent("embed.py").path
        let listFile = FileManager.default.temporaryDirectory.appendingPathComponent("librarian-embed-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: listFile) }
        let joined = paths.joined(separator: "\n")
        guard (try? joined.write(to: listFile, atomically: true, encoding: .utf8)) != nil else { return [:] }
        let result = runPython([embed, "--batch-images", listFile.path, "--model", model.rawValue], timeout: timeout)
        var out: [String: (Int, Data)] = [:]
        let lines = result.stdout.split(separator: "\n")
        for (idx, line) in lines.enumerated() where idx < paths.count {
            let p = paths[idx]
            if let parsed = parseEmbedding(from: String(line)) {
                out[p] = parsed
            }
        }
        return out
    }

    /// Batch-embed raw images keyed by an opaque id (bytes provided by caller via stdin-batch).
    /// Returned map is keyed by the caller-supplied ids. No path is exposed to the helper.
    public static func embedImagesBatchBytes(
        items: [(id: String, bytes: Data)], model: Model = .clipImage, timeout: TimeInterval = 60
    ) -> [String: (dim: Int, data: Data)] {
        guard model == .clipImage, isProvisioned(model), !items.isEmpty else { return [:] }
        guard let scriptsDir = scriptsDir() else { return [:] }
        let embed = scriptsDir.appendingPathComponent("embed.py").path
        // One file per batch is still simpler than a custom wire format; bytes are small (bounded).
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("librarian-batch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let manifest = tmpDir.appendingPathComponent("manifest.txt")
        var lines: [String] = []
        for (idx, item) in items.enumerated() {
            let f = tmpDir.appendingPathComponent("\(idx).bin")
            try? item.bytes.write(to: f)
            lines.append("\(item.id)\t\(f.path)")
        }
        guard (try? lines.joined(separator: "\n").write(to: manifest, atomically: true, encoding: .utf8)) != nil else { return [:] }
        let result = runPython([embed, "--batch-images-manifest", manifest.path, "--model", model.rawValue], timeout: timeout)
        var out: [String: (Int, Data)] = [:]
        for line in result.stdout.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let id = o["id"] as? String,
                  let dim = o["dim"] as? Int,
                  let vec = o["vector"] as? [Double], vec.count == dim,
                  id != "" else { continue }
            var data = Data(capacity: dim * 4)
            for v in vec { var f = Float(v); withUnsafeBytes(of: &f) { data.append(contentsOf: $0) } }
            out[id] = (dim, data)
        }
        return out
    }

    // MARK: - Search helpers (cosine on normalized vectors)

    /// Cosine similarity for two L2-normalized Float32 blobs (little-endian, vDSP-accelerated).
    public static func cosineSimilarity(_ a: Data, _ b: Data) -> Float? {
        guard !a.isEmpty, a.count == b.count, a.count % 4 == 0 else { return nil }
        let n = a.count / 4
        var dot: Float = 0
        a.withUnsafeBytes { ap in
            b.withUnsafeBytes { bp in
                guard let pa = ap.baseAddress?.assumingMemoryBound(to: Float.self),
                      let pb = bp.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                vDSP_dotpr(pa, 1, pb, 1, &dot, vDSP_Length(n))
            }
        }
        if dot == 0 {
            // Fallback if withUnsafeBytes leased a reallocated buffer — recompute scalar safely.
            var s: Double = 0
            for i in 0..<n {
                let fa = a.withUnsafeBytes { $0.load(fromByteOffset: i*4, as: Float.self) }
                let fb = b.withUnsafeBytes { $0.load(fromByteOffset: i*4, as: Float.self) }
                s += Double(fa * fb)
            }
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

    static func parseEmbedding(from json: String) -> (dim: Int, data: Data)? {
        guard let raw = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let dim = o["dim"] as? Int,
              let vec = o["vector"] as? [Double], vec.count == dim else { return nil }
        var data = Data(capacity: dim * 4)
        for v in vec {
            var f = Float(v)
            withUnsafeBytes(of: &f) { data.append(contentsOf: $0) }
        }
        return (dim, data)
    }

    struct RunResult { let stdout: String; let stderr: String; let exitCode: Int32 }

    /// Pin a stable, non-shim python over the PATH-based `env python3`.
    private static func pythonExecutable() -> URL? {
        for candidate in ["/usr/local/bin/python3", "/opt/homebrew/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        // Fallback only if none of the known candidates exist (still fixed, no shim dir injection).
        return URL(fileURLWithPath: "/usr/bin/python3")
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
        if let root = repoRoot() {
            env["LIBRARIAN_MODELS_DIR"] = root.appendingPathComponent("Models").path
        }
        proc.environment = env
        // No shell, no PATH interpolation.
        let outPipe = Pipe(), errPipe = Pipe()
        let inPipe = input != nil ? Pipe() : nil
        proc.standardOutput = outPipe; proc.standardError = errPipe
        proc.standardInput = inPipe
        do { try proc.run() } catch { return RunResult(stdout: "", stderr: "\(error)", exitCode: 127) }
        if let inPipe, let input {
            inPipe.fileHandleForWriting.write(input)
            // Close writer so helper sees EOF and doesn't block on stdin.
            try? inPipe.fileHandleForWriting.close()
        }
        let deadline = DispatchTime.now() + timeout
        var didTimeout = false
        while proc.isRunning, DispatchTime.now() < deadline {
            usleep(30_000)
        }
        if proc.isRunning {
            didTimeout = true
            proc.terminate()
            usleep(200_000)
            if proc.isRunning { proc.interrupt() }
        }
        // Drain pipes after wait — prevents pipe-buffer deadlock if helper wrote large JSON.
        // We read *after* the process settles but hold pipes open the whole time so data
        // stays available; concurrent draining beyond buffering is not needed at 512-float JSON size.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
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
    static func modelsRoots() -> [URL] {
        var roots: [URL] = []
        if let env = ProcessInfo.processInfo.environment["LIBRARIAN_MODELS_DIR"] {
            roots.append(URL(fileURLWithPath: env))
        }
        if let repo = repoRoot() { roots.append(repo.appendingPathComponent("Models")) }
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
