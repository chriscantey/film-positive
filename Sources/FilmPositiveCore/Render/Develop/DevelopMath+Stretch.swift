import Foundation

/// The Stretch control: where a frame's white comes from.
///
/// The develop pass maps each frame's own densest green (P99.5, the green ceiling) to white,
/// with no lower bound in density. A nearly blank negative therefore has its few tenths of a
/// density stretched across the whole output and comes out milky and grainy. Stretch is a
/// per-frame control, not an automatic limit: at 1 (the default) the frame's own ceiling is
/// used, at 0 the stock's reference white density, and between them a geometric blend.
///
/// A frame whose own ceiling already reaches the reference is never changed at any setting,
/// so the control only ever darkens a thin frame and leaves a normal one alone.
extension DevelopMath {

    /// The green density RANGE mapped onto black to white under a stretch setting.
    ///
    ///     o     = own range        = own ceiling - dToe
    ///     r     = reference range  = white density - dToe
    ///     range = o^s * r^(1 - s)
    ///
    /// Geometric, so equal steps of `s` are equal ratios of stretch. `s` is clamped to 0...1,
    /// and a NaN reads as 1. Both guards return `o` itself, untouched: `s == 1`, and
    /// `o >= r` (a frame already at or above the reference).
    public static func stretchedRange(own o: Double, reference r: Double, stretch: Double) -> Double {
        let s = clampedStretch(stretch)
        guard s < 1, o < r, o > 0, r > 0 else { return o }
        return pow(o, s) * pow(r, 1 - s)
    }

    /// The green ceiling CODE VALUE the physics ranges take, under a stretch setting.
    ///
    /// The ceiling is the stretched range plus `dToe`, quantised: `qOfD(range + dToe)`. The
    /// two guards of `stretchedRange` return `ownQ` itself, bit for bit, with no round trip
    /// through density, so stretch 1 and every frame at or above the reference render
    /// exactly as they did without the control.
    public static func stretchedGreenCeiling(_ ownQ: Int, whiteDensity: Double, stretch: Double) -> Int {
        let o = dOfQ(ownQ) - DevelopConstants.dToe
        let r = whiteDensity - DevelopConstants.dToe
        let s = clampedStretch(stretch)
        guard s < 1, o < r, o > 0, r > 0 else { return ownQ }
        return qOfD(stretchedRange(own: o, reference: r, stretch: s) + DevelopConstants.dToe)
    }

    /// A frame is thin when its own range is under a quarter of the reference range,
    /// `o < r / 4`. It drives the Tone row's warning mark and changes no pixels.
    public static func isThin(ownRange o: Double, referenceRange r: Double) -> Bool {
        o < r / 4
    }

    /// `stretch` held to 0...1, a NaN reading as 1 (no change).
    public static func clampedStretch(_ stretch: Double) -> Double {
        stretch.isNaN ? 1 : min(max(stretch, 0), 1)
    }
}

/// What the Stretch control works from on one frame, for the inspector. Measured, never
/// stored: the frame's own green ceiling before any stretch, and the stock's reference.
public struct StretchReading: Equatable, Sendable {
    /// The frame's own green ceiling, density above film base, before the stretch.
    public let ownCeiling: Double
    /// The stock's reference white density (`ProfileLibrary.whiteDensity(for:)`).
    public let whiteDensity: Double

    public init(ownCeiling: Double, whiteDensity: Double) {
        self.ownCeiling = ownCeiling; self.whiteDensity = whiteDensity
    }

    /// The own range, `o = ownCeiling - dToe`.
    public var ownRange: Double { ownCeiling - DevelopConstants.dToe }
    /// The reference range, `r = whiteDensity - dToe`.
    public var referenceRange: Double { whiteDensity - DevelopConstants.dToe }
    /// See `DevelopMath.isThin`.
    public var isThin: Bool { DevelopMath.isThin(ownRange: ownRange, referenceRange: referenceRange) }
    /// How much the negative holds, in stops: the own range times 3.32 (one stop is 0.30
    /// density, 1 / 0.301 = 3.32).
    public var stops: Double { ownRange * 3.32 }
    /// How many times the frame is stretched against a normal one at full Stretch, `r / o`.
    public var stretchFactor: Double { referenceRange / ownRange }
}
