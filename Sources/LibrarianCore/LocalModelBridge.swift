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

    /// Whether a specific model checkpoint is provisioned under Models/.
    public static func isProvisioned(_ model: Model) -> Bool {
        guard let root = repoRoot() else { return false }
        let cfg = root.appendingPathComponent("Models/\(model.rawValue)/config.json")
        return FileManager.default.fileExists(atPath: cfg.path)
    }

    /// Embed an image file (bounded read via SourceBroker path) using local CLIP.
    /// Returns normalized Float32 vector as Data (little-endian Float32) + dim, or nil.
    public static func embedImage(at path: String, model: Model = .clipImage, timeout: TimeInterval = 20) -> (dim: Int, data: Data)? {
        guard model == .clipImage, isProvisioned(model) else { return nil }
        guard let scriptsDir = scriptsDir() else { return nil }
        let embed = scriptsDir.appendingPathComponent("embed.py").path
        let result = runPython([embed, "--image", path, "--model", model.rawValue], timeout: timeout)
        return parseEmbedding(from: result.stdout)
    }

    /// Embed text using local MiniLM (mean-pooled, L2-normalized).
    public static func embedText(_ text: String, model: Model = .miniLMText, timeout: TimeInterval = 10) -> (dim: Int, data: Data)? {
        let clipped = String(text.prefix(4000))
        guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard model == .miniLMText, isProvisioned(model) else { return nil }
        guard let scriptsDir = scriptsDir() else { return nil }
        let embed = scriptsDir.appendingPathComponent("embed.py").path
        let result = runPython([embed, "--text", clipped, "--model", model.rawValue], timeout: timeout)
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
    /// Returns map path -> (dim, Data). Failures for individual images are skipped, not thrown.
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

    // MARK: - Search helpers (cosine on normalized vectors)

    /// Cosine similarity for two L2-normalized Float32 blobs (little-endian).
    public static func cosineSimilarity(_ a: Data, _ b: Data) -> Float? {
        guard !a.isEmpty, a.count == b.count, a.count % 4 == 0 else { return nil }
        let n = a.count / 4
        var dot: Double = 0
        // Data is little-endian Float32; no alignment assumption.
        for i in 0..<n {
            let fa = a.withUnsafeBytes { $0.load(fromByteOffset: i*4, as: Float.self) }
            let fb = b.withUnsafeBytes { $0.load(fromByteOffset: i*4, as: Float.self) }
            dot += Double(fa * fb)
        }
        // For normalized vectors, dot == cosine. Clamp for float error.
        return Float(max(-1, min(1, dot)))
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

    static func runPython(_ args: [String], timeout: TimeInterval) -> RunResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3"] + args
        // No shell, no PATH interpolation beyond /usr/bin/env python3.
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe; proc.standardError = errPipe
        do { try proc.run() } catch { return RunResult(stdout: "", stderr: "\(error)", exitCode: 127) }
        let deadline = DispatchTime.now() + timeout
        while proc.isRunning, DispatchTime.now() < deadline {
            usleep(30_000)
        }
        if proc.isRunning {
            proc.terminate()
            usleep(200_000)
            if proc.isRunning { proc.interrupt() }
            return RunResult(stdout: "", stderr: "timeout after \(timeout)s", exitCode: 124)
        }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return RunResult(stdout: out, stderr: err, exitCode: proc.terminationStatus)
    }

    /// Locate embed.py in both SPM (repo root) and bundled app (Resources/scripts).
    static func scriptsDir() -> URL? {
        // 1. App bundle: LibrarianApp copies scripts/ into Resources/scripts
        if let res = Bundle.main.resourceURL?.appendingPathComponent("scripts"),
           FileManager.default.fileExists(atPath: res.appendingPathComponent("embed.py").path) {
            return res
        }
        // 2. SPM / tests: walk up from CWD to repo root (Package.swift marker)
        if let root = repoRoot() {
            let d = root.appendingPathComponent("scripts")
            if FileManager.default.fileExists(atPath: d.appendingPathComponent("embed.py").path) {
                return d
            }
        }
        return nil
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
