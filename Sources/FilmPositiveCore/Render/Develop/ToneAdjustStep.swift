import Foundation
import FilmSidecar

// The Tone row's Adjust. The three tone presets are four numbers each, and the Adjust shows
// those four numbers as sliders:
//
//     exposure   density added at the tone step, POSITIVE IS DARKER, 0.30 is one stop
//     contrast   the slope in density space about mid grey, 1 is none
//     black      where the frame's own black is placed, 0...1
//     white      where the frame's own white is placed, 0...1
//
// nil in the sidecar means "the preset's own values", and a frame at nil runs the preset's
// tone step with no Adjust involved. A preset's values run through the Adjust's
// builder produce the same tables byte for byte (`ToneAdjustCoreTests`), which is what makes
// the sliders a view of the preset rather than a second tone operator beside it.

extension ToneAdjust {

    /// The four values each tone preset runs. The ONE place they are written, and every
    /// one of them is a `DevelopConstants` name, so turning a constant moves the preset and
    /// its sliders together (`ToneAdjustCoreTests` scans the source for a second copy).
    ///
    /// - None: no tone step. Linear between the film base and the frame's own ceiling.
    /// - Flat: the anchored placement, black to `placedBlack`, white to `placedWhite`.
    /// - Bold: the same placement with Bold's own white, then the paper stage at
    ///   `printGamma` and `printExposure`.
    public static func preset(for mode: ToneMode) -> ToneAdjust {
        switch mode {
        case .none:
            return ToneAdjust(exposure: 0, contrast: 1, black: 0, white: 1)
        case .flat:
            return ToneAdjust(exposure: 0, contrast: 1,
                              black: DevelopConstants.placedBlack, white: DevelopConstants.placedWhite)
        case .print:
            return ToneAdjust(exposure: DevelopConstants.printExposure, contrast: DevelopConstants.printGamma,
                              black: DevelopConstants.placedBlack, white: DevelopConstants.printPlacedWhite)
        }
    }

    /// One stop of exposure, in density. The Exposure slider reads `-exposure / this`.
    public static let densityPerStop = 0.30

    /// How far each value may go. The sliders show exactly these spans and the edit clamps
    /// to them, so a typed number cannot leave them either.
    ///
    /// Exposure is plus or minus two stops. Contrast is held in `printGamma` units, where
    /// Flat reads 0 and Bold reads 1: -1 to +1.5 is a slope from 1 / 2.3 to 2.3^1.5. Black
    /// runs 0 to 40 percent and white 60 to 100, so the white always sits at least 20 points
    /// above the black without either slider having to push the other.
    public static let exposureStops: ClosedRange<Double> = -2...2
    public static let contrastUnits: ClosedRange<Double> = -1...1.5
    public static let blackRange: ClosedRange<Double> = 0...0.40
    public static let whiteRange: ClosedRange<Double> = 0.60...1
    public static let minimumSpan = 0.20

    /// The slope for a contrast reading, and back. Bold's own gamma is the unit.
    public static func contrast(units: Double) -> Double { pow(DevelopConstants.printGamma, units) }
    public static func contrastUnits(_ contrast: Double) -> Double { log(contrast) / log(DevelopConstants.printGamma) }

    /// Clamped to the spans above and held to the 4 decimal grain the sidecar writes, so a
    /// value in memory compares equal to the same value read back from disk. Nil when any
    /// value is not a number, the same rule the color axes keep: a NaN defeats every
    /// comparison downstream.
    public func normalised() -> ToneAdjust? {
        guard exposure.isFinite, contrast.isFinite, contrast > 0, black.isFinite, white.isFinite else { return nil }
        func grain(_ x: Double) -> Double { (x * 10000).rounded() / 10000 }
        let e = Self.densityPerStop
        let expo = min(max(exposure, -Self.exposureStops.upperBound * e), -Self.exposureStops.lowerBound * e)
        let lo = Self.contrast(units: Self.contrastUnits.lowerBound)
        let hi = Self.contrast(units: Self.contrastUnits.upperBound)
        return ToneAdjust(exposure: grain(expo),
                          contrast: grain(min(max(contrast, lo), hi)),
                          black: grain(black.clamped(Self.blackRange)),
                          white: grain(white.clamped(Self.whiteRange)))
    }

    /// Whether these are a preset's values, at the sidecar's grain.
    public func isPreset(_ mode: ToneMode) -> Bool {
        normalised() == Self.preset(for: mode).normalised()
    }
}

private extension Double {
    func clamped(_ r: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) }
}

extension DevelopMath {

    /// The tone step built from the Adjust's four values.
    ///
    /// `measured` is the step the preset measured, or nil for None, which measures nothing.
    /// Its black, gain and exponent are kept (None's are 0, 1 and 1, a straight line), and
    /// the four values replace the rest:
    ///
    ///     placedBlack = black, placedWhite = white
    ///     contrast 1 and exposure 0   the anchored step alone
    ///     anything else, Bold         the anchored step, then the paper stage at that gamma
    ///                                 and exposure, sized as Bold's is (`PrintStage.sized`)
    ///     anything else, None, Flat   the anchored step, then the same gamma and exposure as
    ///                                 a straight line, clamped (`PrintStage.straight`)
    ///
    /// So Flat's own values give Flat's step field for field and Bold's give Bold's, which
    /// is the byte identity the Adjust rests on. None at its own values is NO step, never an
    /// identity table (`renderLUTs` says why), so None's tables are untouched too.
    ///
    /// The paper knees belong to Bold alone, and that is what keeps every slider continuous
    /// at its preset. None and Flat are straight lines, so moving their exposure or contrast
    /// by a notch must move the picture by a notch. Given the knees, the first notch would
    /// pull the top of the picture down through the shoulder (Flat's white 0.92 to 0.909,
    /// None's 1.000 to 0.941), a step the slider never asked for. Which tone a step belongs to is
    /// read off `measured`: nil is None, `.anchored` is Flat, `.print` is Bold, so a run whose
    /// service forces the print operator gets the knees it forced.
    /// `ToneAdjustCoreTests.testOneFineStepOffEachPresetIsContinuous` bounds the step.
    public static func adjustedTone(measured: ToneStep?, adjust: ToneAdjust) -> ToneStep? {
        if measured == nil, adjust == ToneAdjust.preset(for: .none) { return nil }
        let black = measured?.black ?? 0
        let gain = measured?.gain ?? 1
        let exponent = measured?.exponent ?? 1
        // None measures no median. Middle grey is the one an exponent of 1 implies
        // (ln(middleGray) / ln(middleGray)), so the step still reads as one consistent story.
        let median = measured?.median ?? DevelopConstants.middleGray
        let gainAtCap = measured?.gainAtCap ?? false
        let exponentAtBound = measured?.exponentAtBound ?? false
        if adjust.contrast == 1 && adjust.exposure == 0 {
            return ToneStep(op: .anchored, black: black,
                            placedBlack: adjust.black, placedWhite: adjust.white,
                            gain: gain, gainAtCap: gainAtCap, median: median,
                            exponent: exponent, exponentAtBound: exponentAtBound)
        }
        return ToneStep(op: .print, black: black,
                        placedBlack: adjust.black, placedWhite: adjust.white,
                        gain: gain, gainAtCap: gainAtCap, median: median,
                        exponent: exponent, exponentAtBound: exponentAtBound,
                        printStage: measured?.op == .print
                            ? PrintStage.sized(gamma: adjust.contrast, exposure: adjust.exposure,
                                               flatBlack: adjust.black, flatWhite: adjust.white)
                            : PrintStage.straight(gamma: adjust.contrast, exposure: adjust.exposure))
    }
}
