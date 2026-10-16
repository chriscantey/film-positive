import Foundation
import FilmSidecar

/// Where the base pair a frame developed through came from, in the words the app shows.
///
/// The info icon beside the inspector's Base control says which of these is in play,
/// in plain words, on hover and on click, so nobody has to guess why a frame looks orange.
/// The same words reach a headless render's log, so the app and the log cannot describe
/// one frame two ways.
public enum BaseSource: Equatable, Sendable {
    /// A base the user picked with the eyedropper, stored in the sidecar. It wins over
    /// everything except a black and white stock.
    case picked
    /// Measured from THIS frame's film edge at render time, carrying the pair it found.
    case edge(BaseRatios)
    /// No film edge it trusts, so estimated from the brightest tail of the visible picture
    /// (`Calibrator.pictureEstimate`), carrying the pair it estimated.
    case estimated(BaseRatios)
    /// No film edge, and the picture gave no estimate either. The base is neutral 1:1.
    case notFound
    /// Finding the base from the film edge is switched off and nothing is picked, so the
    /// base is neutral 1:1 and nothing was looked for.
    case off
    /// A black and white stock. It has no color base, so it develops 1:1.
    case blackAndWhite

    /// What the info icon says, on hover and in its popover, and what a headless render
    /// logs. The ONE place these words live.
    public var status: String {
        switch self {
        case .picked: return "Color from your pick"
        case .edge: return "Color from the film border"
        case .estimated: return "Color estimated from the picture"
        case .notFound: return "Could not find the film border. Pick a spot on the film."
        case .off: return "No film color in use."
        case .blackAndWhite: return "Black and white film"
        }
    }

    /// The one state a person can act on and would otherwise miss: the switch is on and
    /// nothing was found. The info icon draws a warning mark for it instead of the i.
    public var isWarning: Bool { self == .notFound }
}

/// Decides the base pair for one frame. Four rungs, and a black and white stock beside them.
///
///   0. A black and white stock develops 1:1 with no base. Nothing is measured for it.
///   1. A picked base wins: the pair Pick Base wrote into the sidecar, while `base.mode`
///      is `.measured` (the Base control reads Picked).
///   2. The film edge in this very frame, when the edge reader finds one it trusts (it
///      refuses a reading with no sprocket holes behind it) and the Base control reads Auto
///      (the sidecar key `autoBalance`).
///   3. Estimated from the picture, only when the edge reader refused: a per-channel 99.9th
///      percentile over the visible frame (`Calibrator.pictureEstimate`).
///   4. None: a neutral 1:1, and the info icon asks for a pick. With the switch on this
///      means even the estimate was impossible.
///
/// The switch governs rungs 2 and 3 together. Off means a picked base or none, so a user
/// who turns it off gets exactly the negative's own color and nothing guessed.
///
/// The sidecar's `base.mode` IS read. `.measured` with a pair is rung 1.
/// `.anchor` means the pair, if one is stored, is kept for later and not used, and
/// `autoBalance` decides between rungs 2 and 3 and none. That is what lets the Base control
/// go from Picked to Auto and back without picking again. `BaseChoice` is the same reading
/// from the control's side.
///
/// Nothing here writes a sidecar. It only chooses what the develop pass normalizes with.
public enum BaseResolver {
    public struct Resolution: Equatable, Sendable {
        public let ratios: BaseRatios
        public let source: BaseSource
        public init(ratios: BaseRatios, source: BaseSource) {
            self.ratios = ratios; self.source = source
        }
    }

    /// The pair rung 4 and a black and white stock develop through: no correction at all.
    public static let neutral = BaseRatios(rg: 1, bg: 1)

    /// `measureRebate` returns the three channel means off this frame's film edge
    /// (`Calibrator.rebateEstimate`), or nil when the edge reader found none it trusts.
    /// `estimatePicture` returns the three channel values of the picture estimate
    /// (`Calibrator.pictureEstimate`), or nil when none is possible.
    ///
    /// They are closures so the caller owns the memoisation and the decision not to decode
    /// at all. The edge reader is not called for a black and white stock, a picked base, or
    /// the switch off. The estimate is called only after the edge reader refused.
    public static func resolve(develop: DevelopSettings,
                               profiles: ProfileLibrary,
                               measureRebate: () -> [Double]?,
                               estimatePicture: () -> [Double]? = { nil }) -> Resolution {
        if profiles.resolveFilm(develop.stock).profile.isMono {
            return Resolution(ratios: neutral, source: .blackAndWhite)
        }
        if develop.base.mode == .measured, let picked = develop.base.ratios {
            return Resolution(ratios: picked, source: .picked)
        }
        guard develop.autoBalance else { return Resolution(ratios: neutral, source: .off) }
        if let base = measureRebate(), let pair = ratios(fromRebate: base) {
            return Resolution(ratios: pair, source: .edge(pair))
        }
        if let base = estimatePicture(), let pair = ratios(fromRebate: base) {
            return Resolution(ratios: pair, source: .estimated(pair))
        }
        return Resolution(ratios: neutral, source: .notFound)
    }

    /// Three channel means to a pair, the way `Calibrator` does it everywhere else:
    /// `rg = base[0] / base[1]`, `bg = base[2] / base[1]`. Nil on anything that cannot
    /// divide, because a zero or non-finite green would put an infinity in the kernel.
    public static func ratios(fromRebate base: [Double]) -> BaseRatios? {
        guard base.count == 3, base.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let pair = BaseRatios(rg: base[0] / base[1], bg: base[2] / base[1])
        guard pair.rg.isFinite, pair.bg.isFinite, pair.rg > 0, pair.bg > 0 else { return nil }
        return pair
    }
}
