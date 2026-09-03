import SwiftUI
import AppKit
import LibrarianCore
import LibrarianAppSupport

/// Human-facing preferences first; provider/runtime plumbing stays behind one
/// explicit Advanced disclosure. The normal setup path lives beside Analyze.
struct SimpleSettingsView: View {
    @EnvironmentObject private var model: LibrarianModel
    @State private var showModelSetup = false
    @State private var showAdvancedModelDetails = false
    @State private var huggingFaceToken = ""
    @State private var hasHuggingFaceToken = false
    @State private var huggingFaceStatus = "Checking Keychain…"
    @State private var copiedCommand = false

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

                        Toggle("Use downloaded local embeddings", isOn: $model.localEmbeddingsEnabled)

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Hugging Face access")
                                .font(.subheadline.weight(.medium))
                            HStack(spacing: 8) {
                                Image(systemName: hasHuggingFaceToken ? "key.fill" : "key")
                                    .foregroundStyle(hasHuggingFaceToken ? .green : .secondary)
                                Text(huggingFaceStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            SecureField("Paste replacement access token", text: $huggingFaceToken)
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                Button("Save in Keychain") { saveHuggingFaceToken() }
                                    .disabled(huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button("Remove Token") { removeHuggingFaceToken() }
                                    .disabled(!hasHuggingFaceToken)
                                Spacer()
                                Link("DINOv3 access", destination: AppModelSetup.dinov3AgreementURL)
                                Link("Tokens", destination: AppModelSetup.huggingFaceAccountURL)
                            }
                            .font(.caption)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Selected local models")
                                .font(.subheadline.weight(.medium))
                            ForEach(selectedModels) { descriptor in
                                modelRow(descriptor)
                            }
                        }

                        Divider()

                        HStack {
                            Button("Run Setup Again…") { showModelSetup = true }
                            Button("Open Models Folder") { openModelsFolder() }
                            Button {
                                copySetupCommand(openTerminal: true)
                            } label: {
                                Label(copiedCommand ? "Command Copied" : "Terminal Fallback", systemImage: "terminal")
                            }
                        }

                        DisclosureGroup("Terminal command") {
                            Text(setupCommand)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
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
        model.localModelProfile == .fast || model.isTier2Provisioned
    }

    private var qualityStatusText: String {
        if model.localModelProfile == .fast {
            return "Fast works immediately with built-in macOS analysis."
        }
        if model.isTier2Provisioned {
            return "Downloaded local AI is ready and normal analysis runs offline."
        }
        return "Set it up here or let Set Up & Analyze handle it from the main window."
    }

    private var profileDescription: String {
        switch model.localModelProfile {
        case .fast:
            return "No downloads. Best when you want the quickest first pass."
        case .balanced:
            return "Recommended. Better visual meaning and similarity with moderate memory use."
        case .quality:
            return "For harder libraries. Uses more local AI when the cheaper stages are uncertain."
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
        let provisioned = model.specialistProvisionedIDs.contains(descriptor.id)
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: provisioned ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(provisioned ? .green : .secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(modelDisplayName(descriptor))
                    .font(.caption.weight(.medium))
                Text(modelStatusText(descriptor, provisioned: provisioned))
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
                ? "Access token stored in macOS Keychain"
                : "No access token saved"
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
            huggingFaceStatus = "Access token stored in macOS Keychain"
        } catch {
            huggingFaceStatus = error.localizedDescription
        }
    }

    private func removeHuggingFaceToken() {
        do {
            try HuggingFaceTokenStore.remove()
            huggingFaceToken = ""
            hasHuggingFaceToken = false
            huggingFaceStatus = "No access token saved"
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
        case LocalModelStack.siglip2.id: return "SigLIP2"
        case LocalModelStack.dinov3.id: return "DINOv3"
        case LocalModelStack.paddleOCR.id: return "PaddleOCR-VL"
        case LocalModelStack.miniCPM.id: return "MiniCPM-V"
        case LocalModelStack.lfm.id: return "LFM2.5-VL"
        default: return descriptor.id
        }
    }

    private func modelStatusText(_ descriptor: LocalModelDescriptor, provisioned: Bool) -> String {
        #if os(macOS)
        if descriptor.id == LocalModelStack.paddleOCR.id {
            return "Native macOS Vision OCR is used instead on this platform"
        }
        #endif
        if provisioned { return "Installed" }
        if descriptor.gated { return "Not installed · Hugging Face approval required" }
        return "Not installed"
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
