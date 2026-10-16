import SwiftUI
import FilmPositiveCore

/// The small icon beside the word Base that says where this frame's color came from.
///
/// The words are a tooltip on hover and a popover on click, and nothing is written on the
/// panel itself. The glyph turns into a
/// warning mark when the film border could not be found, so the one state worth acting on
/// shows with no text at all.
///
/// With no answer yet (no positive, or its render has not landed) the icon keeps its place,
/// hidden, so nothing in the row moves when the answer arrives.
struct BaseInfoButton: View {
    let source: BaseSource?
    /// The words, from `BaseInfo.status`, so a warning that belongs to another selected
    /// frame says so.
    let text: String

    @State private var showsPopover = false

    var body: some View {
        Button {
            showsPopover.toggle()
        } label: {
            // Caption size (10 pt, not the body's 13), as `InfoGlyph` draws every other info
            // icon. Not drawn through `InfoGlyph` itself because the symbol turns into a
            // warning mark.
            Image(systemName: BaseInfo.symbol(for: source))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(text)
        .accessibilityLabel(text)
        .accessibilityIdentifier("positive.baseInfo")
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 220, alignment: .leading)
                .padding(12)
        }
        .opacity(source == nil ? 0 : 1)
        .disabled(source == nil)
    }
}
