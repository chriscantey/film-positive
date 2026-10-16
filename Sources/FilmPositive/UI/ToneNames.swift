import FilmSidecar

/// The one place the three tone settings are NAMED and EXPLAINED for a person.
///
/// Two separate contracts live here, and keeping them apart is the whole point of the
/// file.
///
/// The stored value never moves. `ToneMode.print` keeps its raw value `print` forever,
/// so every sidecar already on disk keeps reading and every export keeps its `print`
/// render name. The WORD a person sees for that third setting can change. Renaming it is
/// one edit to `third` below, and nothing else in the app has to be found.
///
/// The help text is the second contract. It says what each setting gives you, in plain
/// words, with no numbers and no operator names, and it does not tell people which setting
/// to leave on, which is not the picker's job. It is one line on the Tone row's info icon.
enum ToneNames {

    /// The display name of the third tone. This is the constant the whole app reads.
    /// Change it here and the segmented control, the Positive sheet's Tone row, the help
    /// text and any caption all follow. The sidecar value stays `print` regardless.
    ///
    /// The stored value stays `print` whatever the word, so a frame developed under an
    /// earlier name reads back the same. It is the lab-print look.
    static let third = "Bold"

    static let noTone = "None"
    static let flat = "Flat"

    static func name(for mode: ToneMode) -> String {
        switch mode {
        case .none: return noTone
        case .flat: return flat
        case .print: return third
        }
    }

    static let all: [ToneMode] = [.none, .flat, .print]

    /// The display name of the slider at the top of Tone's rows (`StretchControl`). The row
    /// label, its undo name and the thin-negative warning all read this one constant, so the
    /// word can change here alone. The sidecar attribute stays `Stretch` regardless.
    static let stretch = "Stretch"

    /// The Tone row's info icon. One sentence on hover, and at most two short ones in the
    /// click popover saying what Flat and Bold do. Built from the names above, so a rename
    /// follows.
    ///
    /// This icon explains the tones, and the segmented control speaks only while the frames
    /// disagree.
    static var infoHover: String {
        "\(noTone) is the plain scan, \(flat) is even and editable, \(third) adds contrast."
    }

    static var infoPopover: String {
        "\(flat) puts black and white in the same place on every frame, so a roll matches. "
            + "\(third) adds contrast for the look of a lab print."
    }
}

extension ToneMode {
    /// The name a person sees. Always read through this or `ToneNames`, never as a
    /// literal at the call site.
    var displayName: String { ToneNames.name(for: self) }
}
