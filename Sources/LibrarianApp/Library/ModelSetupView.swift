import SwiftUI
import LibrarianCore
import LibrarianAppSupport

/// One human-facing setup flow for the downloaded local models. The default
/// cleanup surface should never make somebody hunt through Settings, Terminal,
/// model IDs, or runtime details just to press Analyze.
struct ModelSetupView: View {
    @EnvironmentObject private var model: LibrarianModel
    @Environment(\.dismiss) private var dismiss

    let profile: LocalModelProfile
    let onReady: () -> Void
    let onUseFast: () -> Void

    @State private var token = ""
    @State private var hasSavedToken = false
    @State private var checkingToken = true
    @State private var installing = false
    @State private var statusMessage: String?
    @State private var setupOutput = ""
    @State private var showDetails = false
    @State private var showTokenField = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Set up \(profile.shortDisplayName)")
                        .font(.title2.bold())
                    Text("One-time setup. After this finishes, analysis runs locally on this Mac.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 11) {
                setupPromise("Your files are not uploaded", icon: "lock.shield")
                setupPromise("Private Librarian prepares its own local AI runtime", icon: "internaldrive")
                setupPromise("You can use Fast immediately with no model download", icon: "bolt")
            }
            .padding(14)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Model access")
                    .font(.headline)

                if checkingToken {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking saved access…")
                            .foregroundStyle(.secondary)
                    }
                } else if !needsGatedAccessToken {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DINOv3 access is already installed")
                                .font(.subheadline.weight(.medium))
                            Text("No Hugging Face token is required for the remaining setup.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if hasSavedToken, !showTokenField {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hugging Face access ready")
                                .font(.subheadline.weight(.medium))
                            Text("Token stored in macOS Keychain")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Change…") { showTokenField = true }
                    }
                } else {
                    Text("DINOv3 requires free access approval from Meta on Hugging Face. Approve it once, create a read token, then paste it here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Link("1. Approve DINOv3 access", destination: AppModelSetup.dinov3AgreementURL)
                        Link("2. Create access token", destination: AppModelSetup.huggingFaceAccountURL)
                    }
                    .font(.caption)

                    SecureField("3. Paste Hugging Face token", text: $token)
                        .textFieldStyle(.roundedBorder)

                    Text("The token is saved in macOS Keychain and is sent to the model downloader through stdin only.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if installing {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView()
                    Text("Preparing local AI and downloading the selected models…")
                        .font(.subheadline.weight(.medium))
                    Text("No Homebrew, Xcode, or separate Python installation is required on Apple-silicon Macs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let statusMessage {
                Label(statusMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if !setupOutput.isEmpty {
                DisclosureGroup("Technical details", isExpanded: $showDetails) {
                    ScrollView {
                        Text(setupOutput)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                    .padding(.top, 4)
                }
                .font(.caption)
            }

            Divider()

            HStack {
                Button("Use Fast Instead") {
                    onUseFast()
                    dismiss()
                }
                .disabled(installing)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(installing)

                Button {
                    installAndContinue()
                } label: {
                    if installing {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Setting Up…")
                        }
                    } else {
                        Text("Install & Continue")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(installing || checkingToken || !canInstall)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { refreshTokenState() }
    }

    private var needsGatedAccessToken: Bool {
        profile != .fast && !model.specialistProvisionedIDs.contains(LocalModelStack.dinov3.id)
    }

    private var canInstall: Bool {
        !needsGatedAccessToken || hasSavedToken || !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func setupPromise(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline)
    }

    @MainActor
    private func refreshTokenState() {
        checkingToken = true
        do {
            hasSavedToken = try HuggingFaceTokenStore.load() != nil
            showTokenField = needsGatedAccessToken && !hasSavedToken
            statusMessage = nil
        } catch {
            hasSavedToken = false
            showTokenField = needsGatedAccessToken
            statusMessage = "Keychain access failed: \(error.localizedDescription)"
        }
        checkingToken = false
    }

    @MainActor
    private func installAndContinue() {
        guard !installing else { return }

        let typedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedToken: String?
        do {
            if !typedToken.isEmpty {
                try HuggingFaceTokenStore.save(typedToken)
                resolvedToken = typedToken
                token = ""
                hasSavedToken = true
                showTokenField = false
            } else if let stored = try HuggingFaceTokenStore.load() {
                resolvedToken = stored
            } else if needsGatedAccessToken {
                statusMessage = "Paste a Hugging Face token to continue, or use Fast with no download."
                showTokenField = true
                return
            } else {
                resolvedToken = nil
            }
        } catch {
            statusMessage = error.localizedDescription
            return
        }

        installing = true
        statusMessage = nil
        setupOutput = ""
        showDetails = false

        Task {
            let result = await AppModelSetup.run(profile: profile, token: resolvedToken)
            installing = false
            setupOutput = result.output

            if result.succeeded {
                model.refreshModelStatus()
                model.localEmbeddingsEnabled = true
                onReady()
                dismiss()
            } else {
                statusMessage = friendlyFailure(result)
                showDetails = false
            }
        }
    }

    private func friendlyFailure(_ result: ModelSetupResult) -> String {
        let combined = (result.message + "\n" + result.output).lowercased()
        if combined.contains("401") || combined.contains("403") ||
            combined.contains("gated") || combined.contains("approval") ||
            combined.contains("agreement") || combined.contains("access denied") {
            return "DINOv3 access is not approved for this Hugging Face account yet. Approve access in the link above, then try again."
        }
        if combined.contains("automatic local-ai runtime") || combined.contains("checksum mismatch") ||
            combined.contains("model python") {
            return "Private Librarian could not prepare its local AI runtime on this Mac. Open Technical details for the exact failure."
        }
        if combined.contains("network") || combined.contains("could not resolve") || combined.contains("timed out") ||
            combined.contains("curl:") {
            return "The model download could not reach its download servers. Check your connection and try again."
        }
        return "Setup did not finish. Try again, or use Fast now and finish model setup later."
    }
}
