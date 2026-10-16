import SwiftUI
import FilmPositiveCore

/// The Tone row's info icon while a shown frame is thin (`StretchReading.isThin`): the words
/// for the warning mark, in the Base icon's shape (`BaseInfo`).
enum ToneThin {
    /// The words for ONE thin frame: how much the negative holds, in stops, how many times
    /// it is stretched against a normal one, and where the control is.
    static func status(_ reading: StretchReading) -> String {
        let stops = String(format: "%.1f", reading.stops)
        let times = Int(reading.stretchFactor.rounded())
        return "This negative holds very little, about \(stops) stops, so it is stretched "
            + "about \(times) times as far as a normal one to reach white. "
            + "The \(ToneNames.stretch) slider under Tone sets how far."
    }

    /// The words for a SELECTION, lead frame first, or nil when no shown frame is thin, which
    /// leaves the icon exactly as it is without the warning.
    ///
    /// A thin lead frame, or a selection of one, gets the plain status. When the thin frames
    /// are all OTHER than the lead, the words say how many, because the lead frame on screen
    /// is plainly not thin.
    static func status(_ readings: [StretchReading?]) -> String? {
        let thin = readings.filter { $0?.isThin == true }
        guard !thin.isEmpty else { return nil }
        if let lead = readings.first ?? nil, lead.isThin { return status(lead) }
        return "\(thin.count) of \(readings.count) frames hold very little on the negative "
            + "and are stretched far to reach white. "
            + "The \(ToneNames.stretch) slider under Tone sets how far."
    }

    /// The glyph: the warning mark while a shown frame is thin, the plain i otherwise.
    static func symbol(thin: Bool) -> String {
        thin ? "exclamationmark.triangle" : "info.circle"
    }
}

/// The Tone row's info icon. The plain `InfoGlyph` with the tone words while no shown frame
/// is thin; a warning mark with the thin words otherwise, the way `BaseInfoButton` turns
/// for a missing film border.
struct ToneInfoButton: View {
    /// `ToneThin.status` for the selection, nil when no shown frame is thin.
    let thin: String?

    @State private var showsPopover = false

    var body: some View {
        if let thin {
            Button { showsPopover.toggle() } label: {
                // Caption size, as `InfoGlyph` draws every other info icon.
                Image(systemName: ToneThin.symbol(thin: true))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(thin)
            .accessibilityLabel(thin)
            .accessibilityIdentifier("positive.toneInfo")
            .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                Text(thin)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 220, alignment: .leading)
                    .padding(12)
            }
        } else {
            InfoGlyph(text: ToneNames.infoHover, identifier: "positive.toneInfo",
                      popover: ToneNames.infoPopover)
        }
    }
}
