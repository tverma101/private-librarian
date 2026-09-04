import Foundation
import Security
import LibrarianCore

/// Stores a user-supplied Hugging Face access token in the macOS Keychain.
/// The token is never written to UserDefaults, model provenance, command-line
/// arguments, or setup logs. It is only read for an explicit model-install
/// action and is delivered to the bundled setup script over stdin.
public enum HuggingFaceTokenStore {
    public static let service = "com.tejas.private-librarian.huggingface"
    public static let account = "hub-token-v1"

    public enum TokenError: Error, LocalizedError, Equatable {
        case emptyToken
        case invalidEncoding
        case osStatus(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .emptyToken:
                return "Paste a Hugging Face access token first."
            case .invalidEncoding:
                return "The Hugging Face token could not be encoded."
            case .osStatus(let status):
                let detail = (SecCopyErrorMessageString(status, nil) as String?)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let detail, !detail.isEmpty {
                    return "Keychain error \(status): \(detail)"
                }
                return "Keychain error \(status)."
            }
        }
    }

    public static func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TokenError.osStatus(status) }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw TokenError.invalidEncoding
        }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    public static func save(_ rawToken: String) throws {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw TokenError.emptyToken }
        guard let data = token.data(using: .utf8) else { throw TokenError.invalidEncoding }

        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw TokenError.osStatus(updateStatus)
        }

        var insert = identity
        insert[kSecValueData as String] = data
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw TokenError.osStatus(addStatus) }
    }

    public static func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenError.osStatus(status)
        }
    }
}

public struct ModelSetupProgress: Sendable, Equatable {
    public let phase: String
    public let message: String

    public init(phase: String, message: String) {
        self.phase = phase
        self.message = message
    }
}

/// Cancellation handle for one explicit setup run. Access is lock-protected
/// because the SwiftUI main actor requests cancellation while the provisioning
/// process itself is owned by a detached utility task.
public final class ModelSetupOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    public init() {}

    public var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    public func cancel() {
        let runningProcess: Process?
        lock.lock()
        cancellationRequested = true
        runningProcess = process
        lock.unlock()

        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
    }

    fileprivate func attach(_ process: Process) -> Bool {
        lock.lock()
        self.process = process
        let alreadyCancelled = cancellationRequested
        lock.unlock()
        return !alreadyCancelled
    }

    fileprivate func detach(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }
}

public struct ModelSetupResult: Sendable, Equatable {
    public let succeeded: Bool
    public let status: Int32
    public let message: String
    public let output: String
    public let cancelled: Bool

    public init(
        succeeded: Bool,
        status: Int32,
        message: String,
        output: String,
        cancelled: Bool = false
    ) {
        self.succeeded = succeeded
        self.status = status
        self.message = message
        self.output = output
        self.cancelled = cancelled
    }
}

/// Runs the packaged provisioning helper only after an explicit user action.
/// Normal indexing/inference remains local-files-only. A stored HF token is
/// passed to the helper over stdin; the helper scopes it to the provisioning
/// subprocess rather than exporting it for the whole application session.
public enum AppModelSetup {
    public static let huggingFaceAccountURL = URL(string: "https://huggingface.co/settings/tokens")!
    public static let dinov3AgreementURL = URL(string: "https://huggingface.co/facebook/dinov3-vitb16-pretrain-lvd1689m")!
    static let progressPrefix = "__LIBRARIAN_SETUP_STAGE__|"

    public static func setupScriptURL() -> URL? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment

        if let override = env["LIBRARIAN_SCRIPTS_DIR"], !override.isEmpty {
            let candidate = URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("setup_models.sh")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }

        if let resources = Bundle.main.resourceURL {
            let candidate = resources
                .appendingPathComponent("scripts", isDirectory: true)
                .appendingPathComponent("setup_models.sh")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }

        // SwiftPM/Xcode development builds do not guarantee that the test or
        // app executable lives below the checkout. Resolve both the current
        // working directory and this source file's repository root before
        // falling back to executable-parent walking. Packaged builds still hit
        // the Bundle.main Resources path above.
        let sourceFile = URL(fileURLWithPath: #filePath)
        let sourceRepositoryRoot = sourceFile
            .deletingLastPathComponent() // Runtime
            .deletingLastPathComponent() // LibrarianAppSupport
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repository root
        let developmentCandidates = [
            URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("scripts/setup_models.sh"),
            sourceRepositoryRoot.appendingPathComponent("scripts/setup_models.sh"),
        ]
        if let candidate = developmentCandidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) {
            return candidate
        }

        var cursor = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        for _ in 0..<8 {
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
            let package = cursor.appendingPathComponent("Package.swift")
            let script = cursor.appendingPathComponent("scripts/setup_models.sh")
            if fm.fileExists(atPath: package.path), fm.isExecutableFile(atPath: script.path) {
                return script
            }
        }
        return nil
    }

    /// Use Foundation's Application Support result instead of constructing a
    /// `~/Library/Containers/...` path manually. Inside App Sandbox, HOME is
    /// already the container home; appending another Containers path creates a
    /// bogus nested directory and makes freshly installed models invisible to
    /// the runtime.
    public static func applicationSupportURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PrivateLibrarian", isDirectory: true)
    }

    public static func modelsURL() -> URL {
        applicationSupportURL().appendingPathComponent("Models", isDirectory: true)
    }

    public static func run(
        profile: LocalModelProfile,
        token: String?,
        operation: ModelSetupOperation = ModelSetupOperation(),
        onProgress: (@Sendable (ModelSetupProgress) -> Void)? = nil
    ) async -> ModelSetupResult {
        guard let script = setupScriptURL() else {
            return ModelSetupResult(
                succeeded: false,
                status: 127,
                message: "The packaged model setup helper is missing. Reinstall Private Librarian.",
                output: "")
        }

        if operation.isCancellationRequested {
            return cancelledResult(output: "")
        }

        let profileName: String
        switch profile {
        case .fast: profileName = "embeddings"
        case .balanced: profileName = "balanced"
        case .quality: profileName = "quality"
        }
        let trimmedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let appSupport = applicationSupportURL()

        return await Task.detached(priority: .utility) {
            runBlocking(
                script: script,
                profile: profileName,
                token: trimmedToken,
                appSupport: appSupport,
                operation: operation,
                onProgress: onProgress)
        }.value
    }

    static func progress(from line: String) -> ModelSetupProgress? {
        guard line.hasPrefix(progressPrefix) else { return nil }
        let payload = line.dropFirst(progressPrefix.count)
        guard let separator = payload.firstIndex(of: "|") else { return nil }
        let phase = String(payload[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let message = String(payload[payload.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phase.isEmpty, !message.isEmpty else { return nil }
        return ModelSetupProgress(phase: phase, message: message)
    }

    private static func runBlocking(
        script: URL,
        profile: String,
        token: String?,
        appSupport: URL,
        operation: ModelSetupOperation,
        onProgress: (@Sendable (ModelSetupProgress) -> Void)?
    ) -> ModelSetupResult {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        } catch {
            return ModelSetupResult(
                succeeded: false,
                status: 73,
                message: "Could not create Private Librarian Application Support: \(error.localizedDescription)",
                output: "")
        }

        let logURL = fm.temporaryDirectory
            .appendingPathComponent("private-librarian-model-setup-\(UUID().uuidString).log")
        guard fm.createFile(atPath: logURL.path, contents: nil),
              let logHandle = try? FileHandle(forWritingTo: logURL),
              let readHandle = try? FileHandle(forReadingFrom: logURL) else {
            return ModelSetupResult(
                succeeded: false,
                status: 74,
                message: "Could not create a temporary setup log.",
                output: "")
        }
        defer {
            try? readHandle.close()
            try? logHandle.close()
            try? fm.removeItem(at: logURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        var arguments = [script.path, "--specialist-profile", profile]
        if let token, !token.isEmpty {
            arguments.append("--hf-token-stdin")
        }
        process.arguments = arguments
        process.standardOutput = logHandle
        process.standardError = logHandle

        // A sandboxed app's HOME is the container home. Force every helper to
        // the exact same Foundation-resolved directories used by the runtime so
        // Terminal setup, packaged setup, readiness checks, and the Models
        // folder UI cannot drift to different trees.
        var environment = ProcessInfo.processInfo.environment
        let models = appSupport.appendingPathComponent("Models", isDirectory: true)
        environment["LIBRARIAN_APP_SUPPORT_DIR"] = appSupport.path
        environment["LIBRARIAN_MODELS_DIR"] = models.path
        environment["LIBRARIAN_SPECIALIST_MODELS_DIR"] = models
            .appendingPathComponent("specialists", isDirectory: true).path
        environment["LIBRARIAN_MODEL_RUNTIME_DIR"] = appSupport
            .appendingPathComponent("model-runtime", isDirectory: true).path
        process.environment = environment

        let input = Pipe()
        process.standardInput = input

        guard operation.attach(process) else {
            try? input.fileHandleForWriting.close()
            return cancelledResult(output: "")
        }
        defer { operation.detach(process) }

        do {
            try process.run()
        } catch {
            try? input.fileHandleForWriting.close()
            return ModelSetupResult(
                succeeded: false,
                status: 126,
                message: "Could not start model setup: \(error.localizedDescription)",
                output: "")
        }

        if operation.isCancellationRequested, process.isRunning {
            process.terminate()
        }

        if let token, !token.isEmpty {
            // Stdin avoids putting the secret in shell history or argv.
            try? input.fileHandleForWriting.write(contentsOf: Data((token + "\n").utf8))
        }
        try? input.fileHandleForWriting.close()

        var readOffset: UInt64 = 0
        var pending = Data()
        while process.isRunning {
            drainProgress(
                logURL: logURL,
                readHandle: readHandle,
                readOffset: &readOffset,
                pending: &pending,
                final: false,
                onProgress: onProgress)
            Thread.sleep(forTimeInterval: 0.15)
        }
        process.waitUntilExit()
        try? logHandle.synchronize()
        drainProgress(
            logURL: logURL,
            readHandle: readHandle,
            readOffset: &readOffset,
            pending: &pending,
            final: true,
            onProgress: onProgress)

        let data = (try? Data(contentsOf: logURL)) ?? Data()
        var output = String(data: data, encoding: .utf8) ?? ""
        if output.count > 48_000 {
            output = "… earlier setup output omitted …\n" + String(output.suffix(48_000))
        }

        let status = process.terminationStatus
        if status == 0 {
            return ModelSetupResult(
                succeeded: true,
                status: status,
                message: "Selected local models are installed and verified.",
                output: output)
        }
        if operation.isCancellationRequested {
            return cancelledResult(output: output, status: status)
        }
        let lastUsefulLine = output
            .split(separator: "\n")
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        return ModelSetupResult(
            succeeded: false,
            status: status,
            message: lastUsefulLine ?? "Model setup failed with exit status \(status).",
            output: output)
    }

    private static func drainProgress(
        logURL: URL,
        readHandle: FileHandle,
        readOffset: inout UInt64,
        pending: inout Data,
        final: Bool,
        onProgress: (@Sendable (ModelSetupProgress) -> Void)?
    ) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        if size > readOffset {
            do {
                try readHandle.seek(toOffset: readOffset)
                if let chunk = try readHandle.read(upToCount: Int(size - readOffset)), !chunk.isEmpty {
                    readOffset += UInt64(chunk.count)
                    pending.append(chunk)
                }
            } catch {
                // Progress is best-effort UI. The final setup result still comes
                // from the process exit status and complete bounded log below.
            }
        }

        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[..<newline]
            pending.removeSubrange(...newline)
            emitProgress(lineData: Data(lineData), onProgress: onProgress)
        }
        if final, !pending.isEmpty {
            emitProgress(lineData: pending, onProgress: onProgress)
            pending.removeAll(keepingCapacity: false)
        }
    }

    private static func emitProgress(
        lineData: Data,
        onProgress: (@Sendable (ModelSetupProgress) -> Void)?
    ) {
        guard let line = String(data: lineData, encoding: .utf8)?
            .trimmingCharacters(in: .newlines),
              let progress = progress(from: line) else { return }
        onProgress?(progress)
    }

    private static func cancelledResult(output: String, status: Int32 = 130) -> ModelSetupResult {
        ModelSetupResult(
            succeeded: false,
            status: status,
            message: "Model setup was stopped. Verified models were kept; unfinished staged downloads can be retried safely.",
            output: output,
            cancelled: true)
    }
}
