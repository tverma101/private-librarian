import SwiftUI
import AppKit
import LibrarianCore
import LibrarianAppSupport

/// Product settings expose outcomes rather than model/runtime plumbing. Model
/// downloads are explicit user actions; normal indexing and inference remain
/// local-files-only after provisioning.
struct SimpleSettingsView: View {
    @EnvironmentObject private var model: LibrarianModel
    @State private var showAllModels = false
    @State private var copiedCommand = false
    @State private var huggingFaceToken = ""
    @State private var hasHuggingFaceToken = false
    @State private var huggingFaceStatus = "Checking Keychain…"
    @State private var isInstallingModels = false
    @State private var setupStatus = ""
    @State private var setupOutput = ""
    @State private var showSetupOutput = false

    var body: some View {
        Form {
            Section("Intelligence") {
                Picker("Mode", selection: $model.localModelProfile) {
                    Text("Fast").tag(LocalModelProfile.fast)
                    Text("Balanced").tag(LocalModelProfile.balanced)
                    Text("Quality").tag(LocalModelProfile.quality)
                }
                .pickerStyle(.segmented)

                Text(profileDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Use downloaded local models", isOn: $model.localEmbeddingsEnabled)

                if model.isTier2Provisioned, !model.localEmbeddingsEnabled {
                    Label("Models are installed — turn this on to use them.", systemImage: "lightbulb")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Toggle("Transcribe audio locally", isOn: $model.localTranscriptionEnabled)
                    .disabled(!model.isLocalTranscriptionAvailable)

                if !model.isLocalTranscriptionAvailable {
                    Text(model.localTranscriptionStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Hugging Face access") {
                HStack(spacing: 8) {
                    Image(systemName: hasHuggingFaceToken ? "key.fill" : "key")
                        .foregroundStyle(hasHuggingFaceToken ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hasHuggingFaceToken ? "Access token saved" : "Access token not saved")
                            .font(.subheadline.weight(.medium))
                        Text(huggingFaceStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("Create / manage token", destination: URL(string: "https://huggingface.co/settings/tokens")!)
                        .font(.caption)
                }

                SecureField("Paste Hugging Face token", text: $huggingFaceToken)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save in Keychain") { saveHuggingFaceToken() }
                        .disabled(huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove Token") { removeHuggingFaceToken() }
                        .disabled(!hasHuggingFaceToken)
                    Spacer()
                    Link("Request DINOv3 access", destination: officialURL(LocalModelStack.dinov3))
                }

                Text("The token is stored in macOS Keychain and is supplied only to an explicit model-install process. It is never written to UserDefaults, model manifests, setup commands, or logs. Gated models still require accepting their license/access terms on Hugging Face.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model setup") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.isTier2Provisioned ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(model.tier2Status)
                        .font(.subheadline)
                    Spacer()
                    Button("Refresh") { model.refreshModelStatus() }
                        .disabled(isInstallingModels)
                }

                if model.localModelProfile == .fast {
                    Text("Fast works without a download. Installing the embedding stack is optional and adds semantic image search and visual clustering without a generative model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Install downloads the selected pinned checkpoints into Private Librarian's app container. After setup, inference uses local files only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        installSelectedModels()
                    } label: {
                        if isInstallingModels {
                            ProgressView()
                                .controlSize(.small)
                            Text("Installing…")
                        } else {
                            Label("Install Selected Models", systemImage: "arrow.down.circle")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstallingModels || !hasHuggingFaceToken)

                    Button {
                        copySetupCommand(openTerminal: true)
                    } label: {
                        Label(copiedCommand ? "Command Copied" : "Terminal Fallback", systemImage: "terminal")
                    }
                    .disabled(isInstallingModels)

                    Button("Open Models Folder") { openModelsFolder() }
                }

                if !hasHuggingFaceToken {
                    Label("Save a Hugging Face token above before installing this stack; DINOv3 is gated.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if !setupStatus.isEmpty {
                    Text(setupStatus)
                        .font(.caption)
                        .foregroundStyle(setupStatusColor)
                        .textSelection(.enabled)
                }

                if !setupOutput.isEmpty {
                    DisclosureGroup("Setup log", isExpanded: $showSetupOutput) {
                        ScrollView {
                            Text(setupOutput)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 180)
                    }
                }

                DisclosureGroup("Terminal command") {
                    Text(setupCommand)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("The Terminal fallback can use an existing `hf auth login`. The in-app installer does not require CLI login because it uses the Keychain token above.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Selected models") {
                ForEach(selectedModels) { descriptor in
                    modelRow(descriptor)
                }

                DisclosureGroup("All available specialist models", isExpanded: $showAllModels) {
                    VStack(spacing: 0) {
                        ForEach(LocalModelStack.all) { descriptor in
                            modelRow(descriptor)
                            if descriptor.id != LocalModelStack.all.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }

            Section("Folders and Finder access") {
                if model.sources.isEmpty {
                    Text("No source folders yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.sources) { source in
                        HStack {
                            Image(systemName: model.needsReauthorization(source) ? "exclamationmark.triangle" : "folder.badge.checkmark")
                                .foregroundStyle(model.needsReauthorization(source) ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text((source.path as NSString).lastPathComponent)
                                Text(source.path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(model.needsReauthorization(source)
                                     ? "Permission needs refresh"
                                     : "Read for analysis · write only after Apply confirmation")
                                    .font(.caption2)
                                    .foregroundStyle(model.needsReauthorization(source) ? .orange : .secondary)
                            }
                            Spacer()
                            if model.isPaused(source) {
                                Text("Paused")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Re-authorize…") { model.reauthorizeSource(source) }
                                .buttonStyle(.borderless)
                        }
                    }
                }

                HStack {
                    Button("Add Folder…") { model.addSourceFolder() }
                    Button("Add Exclusion…") { model.addExclusionFolder() }
                }

                Text("Private Librarian uses macOS security-scoped, user-selected read/write folder permission. Analysis itself still opens source files read-only. Re-authorize a folder once after upgrading from an older read-only build or whenever Apply reports that access was lost.")
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

            Section("Privacy") {
                Label("Indexing and inference use local files only", systemImage: "lock.shield")
                Label("Outbound network access is used only by explicit model setup", systemImage: "arrow.down.circle")
                Label("Analysis opens source files read-only", systemImage: "doc.text.magnifyingglass")
                Label("Finder writes happen only after an Apply confirmation", systemImage: "folder.badge.gearshape")
                Label("Models receive broker-owned bytes/text, never source paths or write authority", systemImage: "checkmark.shield")

                Text("Official model-page links open in your browser. Downloaded checkpoints are verified and normal model workers force local-files-only/offline loading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 690, height: 760)
        .padding(4)
        .onAppear {
            refreshHuggingFaceTokenState()
        }
    }

    private var profileDescription: String {
        switch model.localModelProfile {
        case .fast:
            return "Fastest. Deterministic rules + Apple Vision, with local encoders when installed. No generative model is used."
        case .balanced:
            return "Recommended. SigLIP2 + DINOv3 for most images; specialist OCR and MiniCPM wake only when needed, then unload."
        case .quality:
            return "For hard libraries. Uses the same cheap-first path and adds the bounded LFM2.5-VL 3B fallback for unresolved images. Specialists unload between stages."
        }
    }

    private var selectedModels: [LocalModelDescriptor] {
        switch model.localModelProfile {
        case .fast:
            return [LocalModelStack.siglip2, LocalModelStack.dinov3]
        case .balanced:
            return [
                LocalModelStack.siglip2,
                LocalModelStack.dinov3,
                LocalModelStack.paddleOCR,
                LocalModelStack.miniCPM,
            ]
        case .quality:
            return LocalModelStack.all
        }
    }

    @ViewBuilder
    private func modelRow(_ descriptor: LocalModelDescriptor) -> some View {
        // Uses the cached provisioned set from refreshModelStatus instead of
        // walking model directories on every settings render.
        let provisioned = model.specialistProvisionedIDs.contains(descriptor.id)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: provisioned ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(provisioned ? .green : .secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(modelDisplayName(descriptor))
                        .font(.subheadline.weight(.medium))
                    if descriptor.gated {
                        Text("Gated")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.13), in: Capsule())
                    }
                }
                Text("\(roleText(descriptor)) · \(costText(descriptor.cost)) · \(descriptor.license)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(modelStatusText(descriptor, provisioned: provisioned))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(modelStatusColor(descriptor, provisioned: provisioned))
            }

            Spacer()

            Link("Official page", destination: officialURL(descriptor))
                .font(.caption)
        }
        .padding(.vertical, 5)
    }

    private var setupCommand: String {
        let scriptPath = AppModelSetup.setupScriptURL()?.path ?? "./scripts/setup_models.sh"
        let profile: String
        switch model.localModelProfile {
        case .fast: profile = "embeddings"
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
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open(terminal)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedCommand = false
        }
    }

    @MainActor
    private func installSelectedModels() {
        guard !isInstallingModels else { return }
        let token: String
        do {
            guard let stored = try HuggingFaceTokenStore.load(), !stored.isEmpty else {
                hasHuggingFaceToken = false
                huggingFaceStatus = "Save a token before installing gated models."
                return
            }
            token = stored
        } catch {
            huggingFaceStatus = error.localizedDescription
            return
        }

        isInstallingModels = true
        setupStatus = "Preparing the isolated local-model runtime and downloading the selected pinned checkpoints…"
        setupOutput = ""
        showSetupOutput = false
        let profile = model.localModelProfile

        Task {
            let result = await AppModelSetup.run(profile: profile, token: token)
            isInstallingModels = false
            setupStatus = result.message
            setupOutput = result.output
            showSetupOutput = !result.succeeded
            if result.succeeded {
                model.refreshModelStatus()
                model.localEmbeddingsEnabled = true
            }
        }
    }

    private var setupStatusColor: Color {
        if isInstallingModels { return .secondary }
        if setupStatus.localizedCaseInsensitiveContains("installed and verified") { return .green }
        return .orange
    }

    private func refreshHuggingFaceTokenState() {
        do {
            hasHuggingFaceToken = try HuggingFaceTokenStore.load() != nil
            huggingFaceStatus = hasHuggingFaceToken
                ? "Stored securely in macOS Keychain."
                : "Needed for DINOv3 and other gated Hub repositories."
        } catch {
            hasHuggingFaceToken = false
            huggingFaceStatus = error.localizedDescription
        }
    }

    private func saveHuggingFaceToken() {
        do {
            try HuggingFaceTokenStore.save(huggingFaceToken)
            huggingFaceToken = ""
            hasHuggingFaceToken = true
            huggingFaceStatus = "Stored securely in macOS Keychain."
        } catch {
            huggingFaceStatus = error.localizedDescription
        }
    }

    private func removeHuggingFaceToken() {
        do {
            try HuggingFaceTokenStore.remove()
            huggingFaceToken = ""
            hasHuggingFaceToken = false
            huggingFaceStatus = "Token removed from macOS Keychain."
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
        case LocalModelStack.siglip2.id: return "SigLIP2 So400m NaFlex"
        case LocalModelStack.dinov3.id: return "DINOv3 ViT-B"
        case LocalModelStack.paddleOCR.id: return "PaddleOCR-VL 1.6"
        case LocalModelStack.miniCPM.id: return "MiniCPM-V 4.6"
        case LocalModelStack.lfm.id: return "LFM2.5-VL 3B"
        default: return descriptor.id
        }
    }

    private func roleText(_ descriptor: LocalModelDescriptor) -> String {
        switch descriptor.capability {
        case .imageSemantic: return "image meaning/search"
        case .visualSimilarity: return "visual clustering"
        case .documentOCR: return "OCR fallback"
        case .textReasoning: return "text ambiguity"
        case .visionFallback: return "image fallback"
        case .visionHeavyFallback: return "hard image fallback"
        }
    }

    private func modelStatusText(_ descriptor: LocalModelDescriptor, provisioned: Bool) -> String {
        #if os(macOS)
        if descriptor.id == LocalModelStack.paddleOCR.id {
            return "Unsupported on macOS · native Vision OCR is used"
        }
        #endif
        if provisioned { return "Checkpoint ready · runtime checked above" }
        if descriptor.gated {
            return hasHuggingFaceToken
                ? "Not installed · token ready; gated access must also be approved"
                : "Not installed · Hugging Face token + approved gated access required"
        }
        return "Not installed · use Install Selected Models above"
    }

    private func modelStatusColor(_ descriptor: LocalModelDescriptor, provisioned: Bool) -> Color {
        #if os(macOS)
        if descriptor.id == LocalModelStack.paddleOCR.id { return .orange }
        #endif
        if provisioned { return .green }
        if descriptor.gated { return .orange }
        return .secondary
    }

    private func costText(_ cost: LocalModelCostClass) -> String {
        switch cost {
        case .tiny: return "tiny"
        case .small: return "small"
        case .medium: return "medium"
        case .heavy: return "large"
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
