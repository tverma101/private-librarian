import SwiftUI
import LibrarianCore

/// Compatibility entry point for the primary scene.
///
/// The original implementation grew into a long vertical stack of independent
/// cards. Keep the type name so scene wiring and restoration identifiers remain
/// stable, while the actual product surface is now the unified workspace.
struct CleanerHomeView: View {
    var body: some View {
        WorkspaceHomeView()
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
