import SwiftUI
import AppKit
import LibrarianCore
import LibrarianAppSupport

/// Human-facing preferences first; provider/runtime plumbing stays behind one
/// explicit Advanced disclosure. The normal setup path lives beside Analyze
/// and uses public checkpoints only.
struct SimpleSettingsView: View {
    @EnvironmentObject private var model: LibrarianModel
    @State private var showModelSetup = false
    @State private var showAdvancedModelDetails = false
    @State private var huggingFaceToken = ""
    @State private var hasHuggingFaceToken = false
    @State private var huggingFaceStatus = "Checking Keychain…"
    @State private var copiedCommand = false
    @State private var installingGatedModel = false
    @State private var gatedModelOperation: ModelSetupOperation?
    @State private var gatedModelProgress: ModelSetupProgress?
    @State private var gatedModelStatus: String?
    @State private var gatedModelDetails = ""
    @State private var showGatedModelDetails = false

    var body: some View {
        Form {
            Section("Cleanup quality") {
                Picker("Quality", selection: $model.localModelProfile) {
                    Text("Fast").tag(LocalModelProfile.fast)
                    Text("Balanced").tag(LocalModelProfile.balanced)
                    Text("Quality").tag(LocalModelProfile.quality)
                }
                .pickerStyle(.segmented)

                Text(profileDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 9) {
                    Image(systemName: qualityReady ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(qualityReady ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(qualityReady ? "Ready" : "One-time setup needed")
                            .font(.subheadline.weight(.medium))
                        Text(qualityStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !qualityReady {
                        Button("Set Up…") { showModelSetup = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }

            Section("Folders and Finder access") {
                if model.sources.isEmpty {
                    Text("No folders added yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.sources) { source in
                        HStack(spacing: 9) {
                            Image(systemName: model.needsReauthorization(source)
                                  ? "exclamationmark.triangle.fill"
                                  : model.isPaused(source) ? "pause.circle" : "folder.badge.checkmark")
                                .foregroundStyle(model.needsReauthorization(source) ? .orange : .secondary)
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 2) {
                                Text((source.path as NSString).lastPathComponent)
                                    .lineLimit(1)
                                Text(model.needsReauthorization(source)
                                     ? "Permission needs refresh"
                                     : model.isPaused(source) ? "Paused" : "Allowed for analysis and confirmed Apply")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.needsReauthorization(source) {
                                Button("Allow…") { model.reauthorizeSource(source) }
                            } else {
                                Button("Re-authorize…") { model.reauthorizeSource(source) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                HStack {
                    Button("Add Folder…") { model.addSourceFolder() }
                    Button("Add Exclusion…") { model.addExclusionFolder() }
                }

                Text("Analysis only reads files. Finder changes happen only after you review and confirm an Apply plan, and the last Apply can be undone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !model.excludedPaths.isEmpty {
                    DisclosureGroup("Excluded folders") {
                        ForEach(model.excludedPaths, id: \.self) { path in
                            HStack {
                                Text(path)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Button("Remove") { model.removeExclusion(path) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }

            Section("Optional offline features") {
                Toggle("Transcribe audio locally", isOn: $model.localTranscriptionEnabled)
                    .disabled(!model.isLocalTranscriptionAvailable)

                if !model.isLocalTranscriptionAvailable {
                    Text(model.localTranscriptionStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Privacy") {
                Label("File analysis and AI inference stay on this Mac", systemImage: "lock.shield")
                Label("Network access is used only when you explicitly set up models", systemImage: "arrow.down.circle")
                Label("Finder writes require a separate Apply confirmation", systemImage: "folder.badge.gearshape")

                Text("Downloaded models and the optional local AI runtime live in Private Librarian's app data. Normal analysis loads them offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Advanced local AI details", isExpanded: $showAdvancedModelDetails) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(model.isTier2Provisioned ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                            Text(model.tier2Status)
                                .font(.caption)
                            Spacer()
                            Button("Refresh") { model.refreshModelStatus() }
                                .buttonStyle(.borderless)
                        }

                        Label(
                            model.localModelProfile == .fast
                                ? "Downloaded local AI is off in Fast mode"
                                : "Downloaded local AI follows the selected quality level",
                            systemImage: model.localModelProfile == .fast ? "bolt" : "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Optional gated-model access")
                                .font(.subheadline.weight(.medium))
                            Text("Normal Fast, Balanced, and Quality setup does not require an account or token. This credential is only for explicitly installing optional gated models such as DINOv3.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Image(systemName: hasHuggingFaceToken ? "key.fill" : "key")
                                    .foregroundStyle(hasHuggingFaceToken ? .green : .secondary)
                                Text(huggingFaceStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            SecureField("Paste optional access token", text: $huggingFaceToken)
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                Button("Save in Keychain") { saveHuggingFaceToken() }
                                    .disabled(huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button("Remove Token") { removeHuggingFaceToken() }
                                    .disabled(!hasHuggingFaceToken || installingGatedModel)
                                Spacer()
                                Link("1. Accept DINOv3 access", destination: AppModelSetup.dinov3AgreementURL)
                                Link("Create token", destination: AppModelSetup.huggingFaceAccountURL)
                            }
                            .font(.caption)

                            if model.specialistReadyIDs.contains(LocalModelStack.dinov3.id) {
                                Label("DINOv3 is installed and ready", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                HStack(spacing: 8) {
                                    Button(gatedInstallButtonTitle) { installDINOv3() }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(installingGatedModel || (!hasHuggingFaceToken && huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                                    if installingGatedModel {
                                        ProgressView().controlSize(.small)
                                        Text(gatedModelProgress?.message ?? "Preparing DINOv3…")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Button("Cancel") { cancelDINOv3Install() }
                                            .buttonStyle(.borderless)
                                    }
                                }
                                Text("DINOv3 is optional. After upstream access is approved, save a read token here and install it without opening Terminal.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            if let gatedModelStatus {
                                Text(gatedModelStatus)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            if !gatedModelDetails.isEmpty {
                                DisclosureGroup("DINOv3 setup details", isExpanded: $showGatedModelDetails) {
                                    Text(gatedModelDetails)
                                        .font(.system(.caption2, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Models used by this quality level")
                                .font(.subheadline.weight(.medium))
                            ForEach(selectedModels) { descriptor in
                                modelRow(descriptor)
                            }
                            if !model.specialistReadyIDs.contains(LocalModelStack.dinov3.id) {
                                Text("Optional gated DINOv3 visual clustering is not required for this quality level.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider()

                        HStack {
                            if model.localModelProfile != .fast {
                                Button("Run Setup Again…") { showModelSetup = true }
                            }
                            Button("Open Models Folder") { openModelsFolder() }
                            if model.localModelProfile != .fast {
                                Button {
                                    copySetupCommand(openTerminal: true)
                                } label: {
                                    Label(copiedCommand ? "Command Copied" : "Terminal Fallback", systemImage: "terminal")
                                }
                            }
                        }

                        if model.localModelProfile == .fast {
                            Text("Fast has no setup command and downloads no model runtime or weights.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            DisclosureGroup("Terminal command") {
                                Text(setupCommand)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Text("This profile command installs only public models. Installing DINOv3 is a separate advanced action because its upstream repository requires account approval.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 650)
        .padding(4)
        .onAppear {
            refreshHuggingFaceTokenState()
            model.refreshModelStatus()
        }
        .sheet(isPresented: $showModelSetup) {
            ModelSetupView(
                profile: model.localModelProfile,
                onReady: {},
                onUseFast: { model.localModelProfile = .fast })
                .environmentObject(model)
        }
    }

    private var qualityReady: Bool {
        model.isLocalModelProfileReady(model.localModelProfile)
    }

    private var qualityStatusText: String {
        if model.localModelProfile == .fast {
            return "Fast works immediately with built-in macOS analysis."
        }
        if qualityReady {
            return "This quality level's downloaded local AI is ready and normal analysis runs offline."
        }
        return "Set it up here or let Set Up & Analyze handle it from the main window. No account is required."
    }

    private var profileDescription: String {
        switch model.localModelProfile {
        case .fast:
            return "No downloads. Best when you want the quickest first pass."
        case .balanced:
            return "Recommended. Better visual meaning and ambiguity handling with moderate memory use."
        case .quality:
            return "For harder libraries. Uses more local AI when the cheaper stages are uncertain."
        }
    }

    /// Consumer profiles intentionally list only the public checkpoints that
    /// their one-click installer provisions. DINOv3 remains an optional gated
    /// advanced model and must never make these modes look incomplete.
    private var selectedModels: [LocalModelDescriptor] {
        switch model.localModelProfile {
        case .fast:
            return []
        case .balanced:
            return [
                LocalModelStack.siglip2Base,
                LocalModelStack.paddleOCR,
                LocalModelStack.miniCPM,
            ]
        case .quality:
            return [
                LocalModelStack.siglip2So400m,
                LocalModelStack.paddleOCR,
                LocalModelStack.miniCPM,
                LocalModelStack.lfm,
            ]
        }
    }

    @ViewBuilder
    private func modelRow(_ descriptor: LocalModelDescriptor) -> some View {
        let ready = model.specialistReadyIDs.contains(descriptor.id)
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ready ? .green : .secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(modelDisplayName(descriptor))
                    .font(.caption.weight(.medium))
                Text(modelStatusText(descriptor, ready: ready))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Link("Official page", destination: officialURL(descriptor))
                .font(.caption2)
        }
    }

    private var setupCommand: String {
        let scriptPath = AppModelSetup.setupScriptURL()?.path ?? "./scripts/setup_models.sh"
        let profile: String
        switch model.localModelProfile {
        case .fast:
            return "# Fast uses built-in macOS analysis; no model setup is required."
        case .balanced: profile = "balanced"
        case .quality: profile = "quality"
        }
        return "\(shellQuote(scriptPath)) --specialist-profile \(profile)"
    }

    private func copySetupCommand(openTerminal: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(setupCommand, forType: .string)
        copiedCommand = true
        if openTerminal {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedCommand = false
        }
    }

    private func refreshHuggingFaceTokenState() {
        do {
            hasHuggingFaceToken = try HuggingFaceTokenStore.load() != nil
            huggingFaceStatus = hasHuggingFaceToken
                ? "Optional access token stored in macOS Keychain"
                : "No optional access token saved"
        } catch {
            hasHuggingFaceToken = false
            huggingFaceStatus = error.localizedDescription
        }
    }

    private var gatedInstallButtonTitle: String {
        if installingGatedModel { return "Installing DINOv3…" }
        if !huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Save & Install DINOv3"
        }
        return "Install DINOv3"
    }

    @MainActor
    private func installDINOv3() {
        guard !installingGatedModel else { return }
        do {
            let entered = huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !entered.isEmpty {
                try HuggingFaceTokenStore.save(entered)
                huggingFaceToken = ""
                hasHuggingFaceToken = true
                huggingFaceStatus = "Optional access token stored in macOS Keychain"
            }
            guard let token = try HuggingFaceTokenStore.load(), !token.isEmpty else {
                gatedModelStatus = "Save a Hugging Face read token after accepting DINOv3 access first."
                return
            }

            let operation = ModelSetupOperation()
            gatedModelOperation = operation
            gatedModelProgress = ModelSetupProgress(phase: "starting", message: "Preparing DINOv3…")
            gatedModelStatus = nil
            gatedModelDetails = ""
            showGatedModelDetails = false
            installingGatedModel = true

            Task { @MainActor in
                let watcher = Task { @MainActor in
                    while !Task.isCancelled {
                        if let progress = operation.progress { gatedModelProgress = progress }
                        try? await Task.sleep(nanoseconds: 150_000_000)
                    }
                }
                let result = await AppModelSetup.run(
                    specialist: LocalModelStack.dinov3, token: token, operation: operation)
                watcher.cancel()
                installingGatedModel = false
                gatedModelOperation = nil
                gatedModelProgress = operation.progress
                gatedModelDetails = result.output
                if result.succeeded {
                    gatedModelStatus = "DINOv3 is ready. It remains optional and is used only by advanced visual-similarity routing."
                    model.refreshModelStatus()
                } else if result.cancelled {
                    gatedModelStatus = "DINOv3 setup was cancelled safely."
                } else {
                    let combined = (result.message + "\n" + result.output).lowercased()
                    if combined.contains("401") || combined.contains("403") || combined.contains("gated") || combined.contains("access") {
                        gatedModelStatus = "DINOv3 access was denied. Accept the model terms first, then use a Hugging Face token with read access and try again."
                    } else {
                        gatedModelStatus = "DINOv3 setup did not finish. Open setup details for the exact local error."
                    }
                }
            }
        } catch {
            gatedModelStatus = error.localizedDescription
        }
    }

    @MainActor
    private func cancelDINOv3Install() {
        gatedModelOperation?.cancel()
        gatedModelProgress = ModelSetupProgress(phase: "cancelling", message: "Stopping DINOv3 setup safely…")
    }

    private func saveHuggingFaceToken() {
        do {
            try HuggingFaceTokenStore.save(huggingFaceToken)
            huggingFaceToken = ""
            hasHuggingFaceToken = true
            huggingFaceStatus = "Optional access token stored in macOS Keychain"
        } catch {
            huggingFaceStatus = error.localizedDescription
        }
    }

    private func removeHuggingFaceToken() {
        do {
            try HuggingFaceTokenStore.remove()
            huggingFaceToken = ""
            hasHuggingFaceToken = false
            huggingFaceStatus = "No optional access token saved"
        } catch {
            huggingFaceStatus = error.localizedDescription
        }
    }

    private func openModelsFolder() {
        let env = ProcessInfo.processInfo.environment
        let folder: URL
        if let override = env["LIBRARIAN_MODELS_DIR"], !override.isEmpty {
            folder = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            folder = AppModelSetup.modelsURL()
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private func officialURL(_ descriptor: LocalModelDescriptor) -> URL {
        URL(string: "https://huggingface.co/\(descriptor.hfID)")!
    }

    private func modelDisplayName(_ descriptor: LocalModelDescriptor) -> String {
        switch descriptor.id {
        case LocalModelStack.siglip2Base.id: return "SigLIP2 Base NaFlex"
        case LocalModelStack.siglip2So400m.id: return "SigLIP2 So400m NaFlex"
        case LocalModelStack.dinov3.id: return "DINOv3"
        case LocalModelStack.paddleOCR.id: return "PaddleOCR-VL"
        case LocalModelStack.miniCPM.id: return "MiniCPM-V"
        case LocalModelStack.lfm.id: return "LFM2.5-VL"
        default: return descriptor.id
        }
    }

    private func modelStatusText(_ descriptor: LocalModelDescriptor, ready: Bool) -> String {
        #if os(macOS)
        if descriptor.id == LocalModelStack.paddleOCR.id {
            return "Native macOS Vision OCR is used instead on this platform"
        }
        #endif
        if ready { return "Ready" }
        if descriptor.gated { return "Optional · Hugging Face approval required" }
        return "Needs setup"
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
