import SwiftUI
import AppKit
import LibrarianCore

/// Product settings intentionally expose outcomes instead of implementation
/// plumbing. Model downloads remain an explicit Terminal setup step because
/// the packaged app's runtime network entitlement is deliberately disabled.
struct SimpleSettingsView: View {
    @EnvironmentObject private var model: LibrarianModel
    @State private var showAllModels = false
    @State private var copiedCommand = false

    private var profileBinding: Binding<LocalModelProfile> {
        Binding(
            get: { model.localModelProfile },
            set: { profile in
                model.localModelProfile = profile
                if profile != .fast {
                    model.localEmbeddingsEnabled = true
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("Intelligence") {
                Picker("Mode", selection: profileBinding) {
                    Text("Fast").tag(LocalModelProfile.fast)
                    Text("Balanced").tag(LocalModelProfile.balanced)
                    Text("Quality").tag(LocalModelProfile.quality)
                }
                .pickerStyle(.segmented)

                Text(profileDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Use downloaded local models", isOn: $model.localEmbeddingsEnabled)

                Toggle("Transcribe audio locally", isOn: $model.localTranscriptionEnabled)
                    .disabled(!model.isLocalTranscriptionAvailable)

                if !model.isLocalTranscriptionAvailable {
                    Text(model.localTranscriptionStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                }

                if model.localModelProfile == .fast {
                    Text("Fast works without a download. Installing the two embedding models is optional and improves semantic image search while still avoiding generative models.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The selected stack is downloaded only when you explicitly run the setup command. Inference remains offline afterward.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        copySetupCommand(openTerminal: true)
                    } label: {
                        Label(copiedCommand ? "Command Copied" : "Install in Terminal", systemImage: "terminal")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Copy Command") {
                        copySetupCommand(openTerminal: false)
                    }

                    Button("Open Models Folder") {
                        openModelsFolder()
                    }
                }

                Text(setupCommand)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
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

            Section("Folders") {
                if model.sources.isEmpty {
                    Text("No source folders yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.sources) { source in
                        HStack {
                            Image(systemName: model.needsReauthorization(source) ? "exclamationmark.triangle" : "folder")
                                .foregroundStyle(model.needsReauthorization(source) ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text((source.path as NSString).lastPathComponent)
                                Text(source.path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if model.isPaused(source) {
                                Text("Paused")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                HStack {
                    Button("Add Folder…") { model.addSourceFolder() }
                    Button("Add Exclusion…") { model.addExclusionFolder() }
                }

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
                Label("Runtime networking is disabled", systemImage: "network.slash")
                Label("Source folders are opened read-only", systemImage: "lock.open")
                Label("Models receive broker-owned bytes/text, never source write access", systemImage: "checkmark.shield")

                Text("Official model-page links below open in your browser. The app itself does not download models or send indexed content to those sites.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 650, height: 690)
        .padding(4)
    }

    private var profileDescription: String {
        switch model.localModelProfile {
        case .fast:
            return "Fastest. Deterministic rules + Apple Vision, with local encoders when installed. No generative model is used."
        case .balanced:
            return "Recommended. SigLIP2 + DINOv3 for most images; PaddleOCR and MiniCPM wake only when needed, then unload."
        case .quality:
            return "For hard libraries. Adds Ling and optional larger VLM fallbacks. Models run one-at-a-time and unload between stages."
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
        let provisioned = SpecialistModelBridge.isProvisioned(descriptor)
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
            }

            Spacer()

            Link("Official page", destination: officialURL(descriptor))
                .font(.caption)
        }
        .padding(.vertical, 5)
    }

    private var setupCommand: String {
        let scriptPath: String = {
            if let resourceURL = Bundle.main.resourceURL {
                let bundled = resourceURL.appendingPathComponent("scripts/setup_models.sh")
                if FileManager.default.isExecutableFile(atPath: bundled.path) {
                    return shellQuote(bundled.path)
                }
            }
            return "./scripts/setup_models.sh"
        }()

        let profile: String
        switch model.localModelProfile {
        case .fast: profile = "embeddings"
        case .balanced: profile = "balanced"
        case .quality: profile = "quality"
        }
        return "\(scriptPath) --specialist-profile \(profile)"
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

    private func openModelsFolder() {
        let folder = LibrarianModel.appSupportDir.appendingPathComponent("Models", isDirectory: true)
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
        case LocalModelStack.ling.id: return "Ling 3.0 Tiny"
        case LocalModelStack.lfm.id: return "LFM2.5-VL 3B"
        case LocalModelStack.internVL.id: return "InternVL3.5 4B"
        case LocalModelStack.mimo.id: return "MiMo-VL 7B"
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
