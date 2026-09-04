import SwiftUI
import LibrarianCore
import LibrarianAppSupport

/// One human-facing setup flow for the downloaded local models. Consumer
/// quality profiles use public checkpoints only: somebody should not need a
/// model-hosting account, Terminal, Homebrew, Xcode, or a global Python install
/// just to press Analyze.
struct ModelSetupView: View {
    @EnvironmentObject private var model: LibrarianModel
    @Environment(\.dismiss) private var dismiss

    let profile: LocalModelProfile
    let onReady: () -> Void
    let onUseFast: () -> Void

    @State private var installing = false
    @State private var statusMessage: String?
    @State private var setupOutput = ""
    @State private var showDetails = false

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
                setupPromise("No account or access token is required", icon: "person.crop.circle.badge.checkmark")
                setupPromise("Private Librarian prepares its own local AI runtime", icon: "internaldrive")
                setupPromise("You can use Fast immediately with no model download", icon: "bolt")
            }
            .padding(14)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Divider()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ready to install")
                        .font(.headline)
                    Text(setupDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if installing {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView()
                    Text("Preparing local AI and downloading the selected models…")
                        .font(.subheadline.weight(.medium))
                    Text("Large model downloads can take several minutes. Keep this setup window open; no separate developer tools are required.")
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
                .disabled(installing)
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(installing)
    }

    private var setupDescription: String {
        switch profile {
        case .fast:
            return "Optional public local encoders can be installed, but Fast itself works without them."
        case .balanced:
            return "Downloads the public local models used for better image meaning and bounded ambiguity handling."
        case .quality:
            return "Downloads the Balanced stack plus the larger public Quality fallback for difficult images."
        }
    }

    private func setupPromise(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline)
    }

    @MainActor
    private func installAndContinue() {
        guard !installing else { return }

        installing = true
        statusMessage = nil
        setupOutput = ""
        showDetails = false

        Task {
            // Normal quality profiles are intentionally public-only. Gated
            // checkpoints such as DINOv3 remain an explicit advanced install
            // and therefore never receive or require a credential here.
            let result = await AppModelSetup.run(profile: profile, token: nil)
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
        if combined.contains("automatic local-ai runtime") || combined.contains("checksum mismatch") ||
            combined.contains("model python") {
            return "Private Librarian could not prepare its local AI runtime on this Mac. Open Technical details for the exact failure."
        }
        if combined.contains("network") || combined.contains("could not resolve") || combined.contains("timed out") ||
            combined.contains("curl:") {
            return "The model download could not reach its download servers. Check your connection and try again."
        }
        if combined.contains("401") || combined.contains("403") || combined.contains("access denied") {
            return "A public model download was unexpectedly denied. Try again later or use Fast for now."
        }
        return "Setup did not finish. Try again, or use Fast now and finish model setup later."
    }
}
