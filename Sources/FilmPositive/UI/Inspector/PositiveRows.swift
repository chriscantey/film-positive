import Foundation
import FilmSidecar
import FilmPositiveCore

/// The one place the Positive section's controls are NAMED for a person, and the one place
/// the rule that decides which of them are on screen is written down.
///
/// The naming half is `ToneNames`' contract again, for the same reason. The sidecar key
/// stays `autoBalance`, so every file already on disk keeps reading. Only the WORD moves.
/// Change it here and the toggle, its undo action name and the help text all follow.
///
/// Which base the switch found is NOT said in a label or a line of text. It lives in one
/// info icon beside the toggle (`BaseInfo`, `BaseInfoButton`), in the words
/// `BaseSource.status` owns.
///
/// The rows half is here rather than in the view so the order has a test that does not need
/// a window.
enum PositiveNames {

    /// The display name of the switch that finds the base from the film border, or estimates
    /// it from the picture. The sidecar key stays `autoBalance`.
    static let autoColor = "Auto Color"

    /// The Base row's leading label and the Base control's undo action name. The control
    /// itself carries only its three segment words, `BaseChoice.title`, and the info icon.
    /// The row leads with this word and `baseSymbol`, in the same shape as Stock and Tone,
    /// so it says what it is for.
    static let base = "Base"

    /// The Base row's leading icon, beside Stock's `film` and Tone's `dial.medium`. A swatch
    /// because the base is the film's color. It is 18 pt wide at the body size, as
    /// `dial.medium` is (`film` is 19), and that width is what puts the word Base where Stock
    /// and Tone start theirs: `drop.halffull`, at 11 pt, leaves the word 2 to 3 pt short of
    /// the others.
    static let baseSymbol = "swatchpalette"

    /// What the Base control does, as its hover help.
    static let baseHelp = "Auto finds the film color, Picked uses yours, None uses none."

    /// Why the Base control will not move on a black and white stock. There is no color base to
    /// find, so the control is inert there (`BaseResolver.resolve` answers 1:1 for a mono
    /// stock before the edge reader runs); this is the interface saying so instead of
    /// offering a control that does nothing.
    static let monoHelp = "Black and white film has no film color."
}

/// The Positive section's row set, pure.
enum PositiveRows {

    /// One row of the Positive section, in the order it is drawn.
    ///
    /// Black & White is an entry in the Stock picker rather than a control of its own,
    /// which is what it is underneath: a stock id, `bw-generic`, chosen like any other film.
    /// A second control saying the same thing in different words would be a second way to
    /// disagree with it.
    enum Row: String, Equatable, Sendable {
        case stock
        case autoColor
        case warmAxis
        case greenAxis
        case tone
    }

    /// Which rows the Positive section draws.
    ///
    /// Stock is ALWAYS drawn and leads the section. The row set does not depend on the Base
    /// control. `autoColor` is not read, and stays so callers and tests keep one shape.
    ///
    /// **The two color axis rows are governed by `mono` and by nothing else.** They are
    /// drawn in every Base state: the axes are a MANUAL DELTA on whatever base was resolved,
    /// and the base is resolved by some route in every state of the control. The control
    /// decides WHERE the base came from, and the axes move it from there.
    ///
    /// Mono hides them, and it is a provable call rather than a judgment about clutter:
    /// `DevelopMath.base` ignores the ratios entirely when `mono` is set, so the axes cannot move a black and white frame by any amount.
    /// `ColourAxisTests.testTheAxesAreInertOnAMonochromeFrame` is that proof. A control with
    /// no possible effect should not be drawn.
    ///
    /// They also fold away behind the Base row's title, and `axesShown` is the whole of that
    /// rule. `axesOpen` defaults to open, so a caller that does not ask gets the rows.
    static func visibleRows(autoColor: SharedValue<Bool?>, mono: Bool = false,
                            axesOpen: Bool = true) -> [Row] {
        guard axesShown(open: axesOpen, mono: mono) else {
            return [.stock, .autoColor, .tone]
        }
        return [.stock, .autoColor, .warmAxis, .greenAxis, .tone]
    }

    /// Whether the two color axis rows are on screen.
    ///
    /// The remembered fold decides, and a closed row is closed whether or not a selected
    /// frame carries an offset: the lit Base title is what says the row holds an edit. Mono
    /// keeps them folded whatever the fold says, because the axes cannot move a black and
    /// white frame.
    static func axesShown(open: Bool, mono: Bool) -> Bool {
        open && !mono
    }
}

/// Which base the inspector's info icon describes, for the selection on screen.
///
/// The words are `BaseSource.status`, so the icon and a headless render cannot drift apart.
///
/// Pure, so the rule has a test that needs no window.
enum BaseInfo {

    /// The source for ONE frame.
    ///
    /// The three rungs the sidecar alone decides (black and white, a picked base, the switch
    /// off) are answered from the sidecar through `BaseResolver` itself, so they are right
    /// the moment an edit lands and never wait on a render. Only the switch-on answer (film
    /// border, estimated, not found) needs a measurement, and that comes from the render's
    /// own analysis. A rendered answer from any other rung is stale (the edit moved the frame
    /// to a different rung and the new render has not landed) and is not used.
    ///
    /// Nil when the frame has no develop layer, or its switch-on render has not landed: the
    /// icon then keeps its place and says nothing rather than guessing.
    static func source(develop: DevelopSettings?, profiles: ProfileLibrary?,
                       rendered: BaseSource?) -> BaseSource? {
        guard let develop, let profiles else { return nil }
        // No measurement is offered, so a switch-on frame resolves to `.notFound` here, which
        // only means "a measurement decides this one".
        let known = BaseResolver.resolve(develop: develop, profiles: profiles,
                                         measureRebate: { nil }, estimatePicture: { nil }).source
        guard known == .notFound else { return known }
        switch rendered {
        case .edge?, .estimated?, .notFound?: return rendered
        default: return nil
        }
    }

    /// The source for a SELECTION, lead frame first.
    ///
    /// A frame whose border could not be found anywhere in the selection wins: it is the one
    /// state a person can act on, and the pick writes every selected frame. Otherwise the
    /// lead frame's answer.
    static func selection(_ sources: [BaseSource?]) -> BaseSource? {
        if sources.contains(where: { $0?.isWarning == true }) { return .notFound }
        return sources.first ?? nil
    }

    /// The words for a SELECTION, which the icon shows on hover and in its popover.
    ///
    /// When the warning comes from a frame OTHER than the lead, the plain status would say
    /// the border was not found while the lead frame on screen plainly developed from its
    /// border. So the words say which part of the selection it is about. A lead frame that
    /// warns itself, or a selection of one, gets the plain status.
    static func status(_ sources: [BaseSource?]) -> String {
        guard let shown = selection(sources) else { return "" }
        let lead = sources.first ?? nil
        guard shown.isWarning, sources.count > 1, lead?.isWarning != true else { return shown.status }
        let warned = sources.filter { $0?.isWarning == true }.count
        return "No film border found on \(warned) of \(sources.count) frames. Pick a spot on the film."
    }

    /// The glyph: a warning mark when the border could not be found, the plain i otherwise.
    static func symbol(for source: BaseSource?) -> String {
        source?.isWarning == true ? "exclamationmark.triangle" : "info.circle"
    }
}
