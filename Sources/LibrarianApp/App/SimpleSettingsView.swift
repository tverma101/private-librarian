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
    @State private var terminalLaunchFailed = false

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
                    Label("Models are installed — turn this on to use them.",
                          systemImage: "lightbulb")
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
                        Label(copiedCommand ? "Command Copied" : "Open Terminal + Copy", systemImage: "terminal")
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
            return "For hard libraries. Adds LFM2.5-VL 3B as the largest fallback. Every offered model is bounded for an 11.50 GB Mac ceiling and unloads between stages."
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
        let scriptPath: String = {
            if let override = ProcessInfo.processInfo.environment["LIBRARIAN_SCRIPTS_DIR"] {
                let candidate = URL(fileURLWithPath: override).appendingPathComponent("setup_models.sh")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
            }
            if let resourceURL = Bundle.main.resourceURL {
                let bundled = resourceURL.appendingPathComponent("scripts/setup_models.sh")
                if FileManager.default.isExecutableFile(atPath: bundled.path) {
                    return bundled.path
                }
            }
            // Dev builds (SPM) do not bundle the script: walk up from the
            // executable to the repo root so the copied command is absolute
            // and works even though Terminal opens in the home directory.
            var url = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            for _ in 0..<8 {
                let parent = url.deletingLastPathComponent()
                if url.path == parent.path { break }
                url = parent
                if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                    let script = url.appendingPathComponent("scripts/setup_models.sh")
                    if FileManager.default.isExecutableFile(atPath: script.path) {
                        return script.path
                    }
                    break
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

    private func openModelsFolder() {
        // Open the exact directory scripts/setup_models.sh populates by
        // default (its APP_SUPPORT_DIR default is the app container path).
        // Opening a different Models folder made installed models look lost.
        let env = ProcessInfo.processInfo.environment
        let folder: URL
        if let override = env["LIBRARIAN_MODELS_DIR"], !override.isEmpty {
            folder = URL(fileURLWithPath: override)
        } else if let appSupport = env["LIBRARIAN_APP_SUPPORT_DIR"], !appSupport.isEmpty {
            folder = URL(fileURLWithPath: appSupport, isDirectory: true).appendingPathComponent("Models", isDirectory: true)
        } else {
            let home = env["HOME"] ?? NSHomeDirectory()
            folder = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("Library/Containers/com.tejas.private-librarian/Data/Library/Application Support/PrivateLibrarian", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
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
        if descriptor.gated { return "Not installed · accepted gated access is required" }
        return "Not installed · run the setup command above"
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
