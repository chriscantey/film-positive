import SwiftUI

/// The Help menu's shortcuts panel, in the style of the Settings pages: the Settings width,
/// grouped sections, the keys in a monospaced column on the left, and no prose beyond one
/// line per row.
///
/// NOT EDITABLE, and that is a decision rather than a shortfall. Editable shortcuts means key
/// capture, conflict detection against both the system's shortcuts and our own, persistence
/// and a reset path. That is its own feature.
///
/// ONE WAY OUT: the Done button, which Return also presses. A click outside a macOS sheet
/// does not close it, it beeps. Do not invent another way.
///
/// The footer has room for a documentation link beside Done, and nothing else has to move
/// when one arrives.
struct KeyboardShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // A title, because the sheet otherwise opens straight into the first group's
            // heading and nothing on screen says what the window is.
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            // A rule under the title, mirroring the one above the footer, so the sheet is
            // three bands rather than a heading that floats on top of the list. Without it
            // there is 10 pt of air under the title against 29 pt between one group and the
            // next, so the title and "Sliders" read as a pair instead of as two levels.
            // Spacing alone could buy that back, but the rule says WHY the gap is there.
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(ShortcutCatalog.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.headline)
                            VStack(spacing: 0) {
                                ForEach(Array(group.rows.enumerated()), id: \.offset) { index, row in
                                    if index > 0 { Divider() }
                                    ShortcutLine(row: row)
                                }
                            }
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 560)
    }
}

/// One row: what to press on the left of its own line, what it does on the right.
///
/// The keys are `.monospaced` so ⌘R and ⇧⌘R line up down the column rather than drifting by
/// the width of a glyph, which is the difference between a table and a list of sentences.
private struct ShortcutLine: View {
    let row: ShortcutCatalog.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(row.keys)
                .font(.system(.body, design: .monospaced))
                .frame(width: ShortcutCatalog.keyColumnWidth, alignment: .leading)
            Text(row.what)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.keys), \(row.what)")
    }
}
