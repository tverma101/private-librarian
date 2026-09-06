import SwiftUI
import LibrarianCore

/// Shared recovery choices used by both the main and advanced Library surfaces.
/// Recovery changes only the encrypted catalog; source files are never touched.
enum CatalogRecoveryAction: String, Identifiable {
    case startFresh
    case resetKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .startFresh: return "Start with an empty catalog?"
        case .resetKey: return "Create a new encrypted catalog?"
        }
    }
}

/// Compatibility entry point for the primary scene.
///
/// The original implementation grew into a long vertical stack of independent
/// cards. Keep the type name so scene wiring and restoration identifiers remain
/// stable, while the actual product surface is now the unified workspace.
struct CleanerHomeView: View {
    var body: some View {
        WorkspaceHomeView()
            .frame(minWidth: 1040, minHeight: 680)
    }
}

extension LocalModelProfile {
    var shortDisplayName: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .quality: return "Quality"
        }
    }
}

/// Compact wrapping chips are still used by secondary library surfaces.
struct FlowChips: View {
    let items: [String]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 130), spacing: 6)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.background.opacity(0.7), in: Capsule())
                    .help(item)
            }
        }
    }
}
