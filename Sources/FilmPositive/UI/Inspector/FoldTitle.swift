import SwiftUI

/// An inspector title that folds the part it names (`SectionFold`). The title keeps its own
/// style, passed in as `label`, and a closed part gets a small chevron beside it. The
/// header row it sits in stays, so a Reset or a wand on that row is still in reach while
/// the body is folded.
///
/// A plain button, so the title looks like a title and not a button. That makes the fold a
/// hidden gesture on an open part, which is why the accessibility label and the hover help
/// both say what a press does.
struct FoldTitle<Styled: View>: View {
    let title: String
    let open: Bool
    let action: () -> Void
    let label: Styled

    init(_ title: String, open: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Styled) {
        self.title = title
        self.open = open
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                label
                if !open {
                    Image(systemName: SectionFold.chevron)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(SectionFold.help(title, open: open))
        .accessibilityLabel(SectionFold.accessibilityLabel(title, open: open))
        .accessibilityAddTraits(.isHeader)
    }
}
