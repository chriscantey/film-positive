import SwiftUI

/// The small info icon the app puts beside a label in place of explanatory text: the words
/// are a tooltip on hover and a popover on click.
///
/// The same icon, size and popover as the inspector's `RowLabel`, which draws through
/// this, so every info icon in the app is one control.
struct InfoGlyph: View {
    let text: String
    let identifier: String
    /// The click popover's words when they say more than the hover line (the Tone row).
    /// Nil shows `text` in both places, which is every other icon.
    var popover: String? = nil
    @State private var showsPopover = false

    var body: some View {
        Button { showsPopover.toggle() } label: {
            Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(text)
        .accessibilityLabel(text)
        .accessibilityIdentifier(identifier)
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            Text(popover ?? text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 220, alignment: .leading)
                .padding(12)
        }
    }
}
