import SwiftUI

/// The two Develop rows that open sliders under them, Base and Tone.
///
/// The row's own title, the icon and the word, is the button that shows and hides its
/// sliders. Stock is not one of them: it is a choice of film and nothing else, and its title
/// is a plain label.
///
/// One place for each row's words and ids, so the titles cannot drift apart. The folds
/// themselves are remembered preferences (`showsColourAxes`, `showsToneAdjust`), and the rule
/// for when the sliders are on screen is the fold alone (`PositiveRows.axesShown`,
/// `ToneAdjustRows.shown`): a closed row is closed, edits or not, and its lit title is the
/// sign that it carries edits.
enum DevelopRow: String, CaseIterable, Sendable {
    case base
    case tone

    /// The word on screen, and the first half of the accessibility label.
    var title: String {
        switch self {
        case .base: return PositiveNames.base
        case .tone: return "Tone"
        }
    }

    /// The leading icon.
    var symbol: String {
        switch self {
        case .base: return PositiveNames.baseSymbol
        case .tone: return "dial.medium"
        }
    }

    /// The title's accessibility id, the one anything that drives the toggle by id finds.
    var identifier: String {
        switch self {
        case .base: return "positive.adjust"
        case .tone: return "tone.adjust"
        }
    }

    /// The hover help: what a press does now.
    func help(open: Bool) -> String {
        "\(open ? "Hide" : "Show") the \(title) sliders"
    }

    /// What the title says to Accessibility, in the section titles' form.
    func accessibilityLabel(open: Bool) -> String {
        SectionFold.accessibilityLabel(title, open: open)
    }

    /// Whether the title is lit: some selected frame has this row's values in use.
    func lit(_ summary: SelectionSummary) -> Bool {
        switch self {
        case .base: return summary.colourAxesInUse
        case .tone: return summary.toneAdjustInUse || summary.stretchInUse
        }
    }

    /// The remembered fold this title toggles.
    func isOpen(_ prefs: Preferences) -> Bool {
        switch self {
        case .base: return prefs.showsColourAxes
        case .tone: return prefs.showsToneAdjust
        }
    }
}

/// A Develop row's title as the button that folds its sliders.
///
/// Drawn the way `FoldTitle` draws a section title: a plain button, so the title reads as a
/// title, with the section chevron beside the word while the fold is closed and nothing
/// extra while it is open. The chevron follows the REMEMBERED fold, the thing a press
/// changes, so it agrees with the hover help and the accessibility label. A closed row hides
/// its sliders even while it carries edits, and then the lit title is what says they are there.
///
/// The info icon is NOT inside this button. It sits beside it in the row with its own
/// click, so a press on the icon opens its popover and never folds, and a press on the
/// title folds and never opens the popover.
struct DevelopRowTitle: View {
    let row: DevelopRow
    let open: Bool
    let lit: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Label(row.title, systemImage: row.symbol)
                    // Lit in the accent, plain otherwise.
                    .foregroundStyle(lit ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                if !open {
                    Image(systemName: SectionFold.chevron)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.help(open: open))
        .accessibilityLabel(row.accessibilityLabel(open: open))
        .accessibilityValue(lit ? "adjusted" : "")
        .accessibilityIdentifier(row.identifier)
    }
}

/// A Develop row's sliders, held together under their title, so the sliders read as
/// belonging to the row above them.
///
/// The rows are quiet: indented a little, and each row's label and icon drawn lighter and
/// one size smaller than the titles above them, so the group reads as under its title with
/// no line of its own. The only lines are the Form's separators. No caption: each row's own
/// label says what it does. One Form row for the whole group, so no Form separator falls
/// between its rows.
struct DevelopSliderGroup<Rows: View>: View {
    let rows: Rows

    init(@ViewBuilder rows: () -> Rows) {
        self.rows = rows()
    }

    @State private var labelColumn: CGFloat = 0

    /// How far the sliders sit in from the row's leading edge. Every point of it comes off
    /// the tracks, so it is the least that still reads as indented under the title.
    static var indent: CGFloat { 14 }
    /// The gap between a row's label column and its track.
    static var labelGap: CGFloat { 12 }
    /// The gap between two slider rows. The group is one Form row, so the Form's own row
    /// padding is not between them; this keeps the pitch near the 40 pt of a slider row
    /// that is a Form row of its own.
    static var rowGap: CGFloat { 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowGap) {
            rows
        }
        // Out of the Form, a LabeledContent splits label and content at its own column
        // and lets a fixed-width label run into the track. This style lays each row out
        // itself: the label at its natural width on the group's one label column, the
        // track in the rest.
        .labeledContentStyle(DevelopGroupRowStyle())
        .environment(\.developLabelColumn, labelColumn > 0 ? labelColumn : nil)
        .onPreferenceChange(DevelopLabelWidth.self) { labelColumn = $0 }
        .padding(.leading, Self.indent)
    }
}

/// A slider row inside a `DevelopSliderGroup`: the label at its natural width, widened to
/// the group's label column so every track in the group starts on one line, then the
/// content (track and readout) in the rest. The label and its icon are quiet, secondary at
/// `.callout`. The track, its fill, its tick and the readout keep their own styles.
struct DevelopGroupRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        DevelopGroupRow(configuration: configuration)
    }
}

private struct DevelopGroupRow: View {
    let configuration: LabeledContentStyleConfiguration
    @Environment(\.developLabelColumn) private var column

    var body: some View {
        HStack(spacing: DevelopSliderGroup<EmptyView>.labelGap) {
            configuration.label
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize()
                .background(GeometryReader { g in
                    Color.clear.preference(key: DevelopLabelWidth.self, value: g.size.width)
                })
                .frame(width: column, alignment: .leading)
            configuration.content
                .frame(maxWidth: .infinity)
        }
    }
}

/// The widest natural label in a group.
struct DevelopLabelWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct DevelopLabelColumnKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// The group's label column, nil until the labels have been measured.
    var developLabelColumn: CGFloat? {
        get { self[DevelopLabelColumnKey.self] }
        set { self[DevelopLabelColumnKey.self] = newValue }
    }
}
