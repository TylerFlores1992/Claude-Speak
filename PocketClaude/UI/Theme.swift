import SwiftUI

/// The dark, low-contrast surfaces the Claude apps use.
///
/// Named rather than sprinkled inline so the whole app moves together, and
/// derived from system materials so Dynamic Type, increased contrast and the
/// occasional light-mode screenshot all still work. Nothing here is a fixed hex
/// value pretending to be a design system.
extension Color {
    /// Behind everything.
    static let pcBackground = Color(.systemBackground)
    /// Cards, rows, the composer bar — one step up from the background.
    static let pcCard = Color(.secondarySystemBackground)
    /// The small rounded well behind a row's icon.
    static let pcIconWell = Color(.tertiarySystemBackground)
}

/// A pill that shows a current choice and opens a menu — the model and effort
/// controls in the composer.
struct ChipMenu<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.caption)
                }
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.pcIconWell, in: Capsule())
            .foregroundStyle(.primary)
        }
    }
}
