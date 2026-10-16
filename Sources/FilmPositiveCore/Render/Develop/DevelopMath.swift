import Foundation
import FilmSidecar

// The develop kernel, CPU reference. Every stage is stated as a formula in the comments
// below and each one is asserted from that formula on synthetic frames whose base, dye
// gammas and pixel values the test chooses (`DevelopMathTests`). The accelerated table
// path the UI runs is checked against THIS, never the other way round.
//
// Order: anchor (P99.8 clip-guarded green, or luminance for mono) -> base from ratios ->
// density above base -> quantised density q (16-bit over D_MIN...D_MAX) -> per-channel
// histograms over the inset area -> physics normalization (floor at film base with a
// toe, green ceiling from the frame, red and blue ceilings from the stock's dye gammas)
// -> optional auto tone (per-frame gamma putting the median at LEVEL_TARGET) -> 16-bit
// positive, cropped, flipped, rotated.

public enum DevelopConstants {
    // THE INVERSION STAGE'S OWN CHOICES, not film facts.

    /// Stage choice, the density window: density is quantised to 16 bits over -0.3 to 4.0 D.
    public static let dMin = -0.3
    public static let dMax = 4.0
    public static var dRange: Double { dMax - dMin }
    /// Stage choice: 6 percent of each edge is kept out of the statistics.
    public static let inset = 0.06
    /// Stage choice, the anchor percentile: green's P99.8 sets the base level. P0.5
    /// and P99.5 are each channel's low and high percentiles, and P99.5 is green's ceiling.
    public static let pAnchor = 0.998
    public static let pLo = 0.005
    public static let pHi = 0.995
    /// Stage choice, the density floor: every channel's range starts 0.05 D below film base.
    public static let dToe = -0.05
    /// Stage choice: a channel at or above this is direct light, never base.
    public static let clipGuard: UInt16 = 65000

    // MARK: Flat, the anchored tone (2026-09-14)
    //
    // THE APP'S OWN CHOICES FOR THIS TONE, not film facts. Flat is a flat, editable base
    // image: it may flatten a frame, it must never add contrast, and every frame of a roll
    // lands on the same black, white and midtone targets. It places both ends on constants
    // and lets the middle sit where the exposure put it.
    //
    //     placedBlack   0.20    picked by eye, swept on 41 UltraMax frames
    //     placedWhite   0.92    the same pick, the pair judged together
    //     middleGray    0.461   sRGB spec: 18 percent linear through the transfer function
    //     gainCap       2.0     the bound the auto tone assessment declared
    //     exponentMin   0.65    swept on a set of rolls, the widest usable band
    //     exponentMax   1.0     the never-add-contrast rule itself

    /// The floor the frame's measured black is placed on, and the ceiling its own white is
    /// placed on. A LIFTED black and a held-back white, deliberately: a consistent lifted
    /// black is what reads as flat and editable, and at 16 bits everything outside the band
    /// is still recoverable by a Black Point move downstream.
    ///
    /// These two numbers are picked by eye, and the pair decides whether the operator
    /// flattens or sharpens. Measured over 41 UltraMax frames (swept exactly with no
    /// re-render), where C90 is luma P90 minus P10 in 8-bit and "gaining" is against the
    /// same frame's flat render:
    ///
    ///     floor / ceiling   gaining C90   C90 spread   P1 range    P50 range
    ///     0.04 / 0.96        32 of 41        136       11 to 48    57 to 144
    ///     0.12 / 0.94        10 of 41        121       31 to 65    72 to 150
    ///     0.20 / 0.92         3 of 41        106       52 to 81    88 to 155
    ///     0.24 / 0.90         0 of 41         98       62 to 89    95 to 157
    ///     0.30 / 0.88         0 of 41         86       77 to 101  106 to 161
    ///     (flat reference)    0 of 41        148       11 to 91    33 to 174
    ///
    /// 0.20 / 0.92 is what ships: three frames of the roll still gain. 0.24 / 0.90 takes that
    /// to zero and is the next stop for a flatter result.
    public static let placedBlack = 0.20
    public static let placedWhite = 0.92
    /// The white the placement stage lands on when the tone is Bold (`.print`). Flat keeps
    /// `placedWhite` 0.92 for the editable base. Bold gets its own because a print may reach
    /// paper white, and under Flat's 92 percent ceiling the shoulder cannot raise it.
    ///
    /// Picked by eye from a sweep of whites (1.00 scored 6.0 against 2.0 for 0.96 and 1.0
    /// for 0.92 at gamma 2.3, exposure +0.30). Listed with Bold below.
    public static let printPlacedWhite = 1.0
    /// Middle gray: 18 percent linear through the sRGB transfer function is
    /// 1.055 * 0.18^(1/2.4) - 0.055 = 0.4614.
    public static let middleGray = 0.461
    /// The most the black placement is allowed to stretch a frame. Without it a frame whose
    /// black floats very high would be expanded by an unbounded factor.
    public static let gainCap = 2.0
    /// The exponent bounds. The UPPER bound is 1.0 on purpose and it is the whole of the
    /// "never add contrast" rule: an exponent above 1 darkens the midtones and steepens the
    /// curve. The lower bound is the operator declining to rescue a very dark frame.
    /// The assessment swept it and 0.65 is the widest usable band.
    public static let exponentMin = 0.65
    public static let exponentMax = 1.0

    // MARK: Bold, the print tone (`.print`, 2026-09-14)
    //
    // THE APP'S OWN CHOICES FOR THIS TONE, not film facts. Bold is Flat plus one stage: the
    // same placement, then a paper gamma in the flat base's density space about mid-gray,
    // with a soft toe and shoulder, so Bold and Flat differ in contrast and nothing else.
    //
    //     printGamma          2.3      picked by eye from a contrast sweep
    //     printExposure       0.30 D   the same pick, judged together with the gamma
    //     printPlacedWhite    1.0      picked by eye from a sweep of whites (above)
    //     printBlack          0.02     the print-tone build's limit, in every variant judged
    //     printWhite          0.98     the same
    //     paperDensityRange   2.4797   the sheet: Kodak Endura Premier, E-4070
    //
    // The gamma is not derived from the endpoints. Carrying the Flat targets onto the print
    // limits (0.20 to 0.02, 0.92 to 0.98) gives 2.550 as a span and disagrees by a factor of
    // three one end at a time, and 2.550 crushes the top 22 percent of the Flat range into
    // 2 percent of the output.

    /// The slope the print stage applies in the flat base's density space, about the
    /// mid-gray pivot.
    ///
    /// Picked by eye from a contrast sweep (gamma 2.3 at exposure +0.30 scored 6.5 against
    /// 2.5 for a paper-derived 1.7567).
    ///
    /// This is the number to turn if Bold has too much or too little contrast.
    public static let printGamma = 2.3

    /// The paper exposure offset, **in density units**, added to the straight gamma's
    /// output before the knees:
    ///
    ///     d' = pivotD + printGamma * (d - pivotD) + printExposure
    ///
    /// It is the print's exposure time: a POSITIVE value adds density, so the print gets
    /// DARKER and its highlights pull back off the shoulder. 0.30 D is a full stop. Without
    /// it skin lands high and meets the shoulder.
    ///
    /// Picked by eye together with `printGamma` from the same contrast sweep. Pass 0
    /// explicitly to get the pre-exposure curve back.
    public static let printExposure = 0.30

    /// The print's black and white limits, as display values. Nothing the stage emits is
    /// outside them, and the toe and the shoulder are what hold that. They are limits, NOT
    /// targets the operator aims the Flat placement at.
    public static let printBlack = 0.02
    public static let printWhite = 0.98

    /// The width of the toe and the shoulder, **in density units, not value units**, which
    /// is the whole reason one constant can serve both ends: a fixed density margin is a
    /// wide span of values next to white and a very narrow one next to black, which is
    /// exactly how a paper curve behaves. In value units a single width either lifts the
    /// blacks into mud or leaves the highlights to clip square.
    ///
    /// Derived from the paper sheet below (`paperDensityRange`): 0.2 D of paper density at
    /// each end, the margin where the paper's curve is already bending. Scaled from the
    /// paper's own density range onto ours:
    ///
    ///     0.2 * (log10(printWhite) - log10(printBlack)) / (Dmax - Dmin)
    ///   = 0.2 * 1.690196 / 2.4797 = 0.13631
    public static var printKneeWidth: Double {
        let displaySpan = log10(printWhite) - log10(printBlack)
        return 0.2 * displaySpan / paperDensityRange
    }

    /// Dmax minus Dmin for a color RA-4 paper, meaned over its three layers:
    /// 2.575 - 0.095. Read off the curve, because the sheet prints no numeric Dmin or Dmax.
    ///
    /// Source: KODAK PROFESSIONAL ENDURA Premier Paper, publication **E-4070** (March
    /// 2013), page 4, "Characteristic Curves", process RA-4 95F 45 sec, Status A
    /// densitometry.
    /// `https://business.kodakmoments.com/sites/default/files/files/resources/paper-endura-techpub-e4070.pdf`
    /// sha256 `6f632cc5943a4adb8da487b86470ddf51c436a52f313241691b5b8b2bab1718f`.
    /// Digitized from the PDF's own vector drawing. Per layer:
    ///
    ///     R   Dmin 0.104   Dmax 2.757
    ///     G   Dmin 0.104   Dmax 2.525
    ///     B   Dmin 0.078   Dmax 2.443
    ///     mean Dmin 0.095, Dmax 2.575
    ///
    /// **E-4021 is a different product.** That publication is Portra ENDURA and Supra
    /// ENDURA, which its own text calls low contrast; Premier is the high-contrast member
    /// of the family and its publication is E-4070.
    public static let paperDensityRange = 2.4797
}

/// JavaScript Math.round: nearest integer, ties toward positive infinity. Written without
/// the `x + 0.5` shortcut so a value like 0.49999999999999994 rounds the way V8 rounds it.
@inline(__always) func jsRound(_ x: Double) -> Double {
    let f = x.rounded(.down)
    return (x - f) >= 0.5 ? f + 1 : f
}

@inline(__always) public func qOfD(_ d: Double) -> Int {
    Int(jsRound(((d - DevelopConstants.dMin) / DevelopConstants.dRange) * 65535))
}

@inline(__always) public func dOfQ(_ q: Int) -> Double {
    DevelopConstants.dMin + (Double(q) / 65535) * DevelopConstants.dRange
}

/// Which tone operator Auto Tone runs.
///
/// `anchored` is what Flat runs: place the frame's measured black first, then a bounded
/// exponent on what is left.
///
/// `print` is `anchored` followed by the paper contrast stage. It shares the placement
/// exactly, so the only difference between a Flat render and a Print render of the same
/// frame is contrast.
public enum AutoToneOperator: String, Sendable, Equatable, CaseIterable {
    case anchored
    case print
}

public struct PrintStage: Equatable, Sendable {
    /// The slope applied in density space about `pivot`.
    public let gamma: Double
    /// The paper exposure offset in density units, added after the gamma and before the
    /// knees. Positive prints darker. `DevelopConstants.printExposure`, which is 0.30.
    public let exposure: Double
    /// The value that maps to itself when `exposure` is 0. `DevelopConstants.middleGray`.
    public let pivot: Double
    /// The floor the toe holds. Nothing the stage emits is below it.
    public let black: Double
    /// The ceiling the shoulder holds. Nothing the stage emits is above it.
    public let white: Double
    /// The width of both knees, **in density units**.
    public let kneeWidth: Double
    /// Whether this frame's own flat black reaches into the toe.
    public let toeEngaged: Bool
    /// Whether this frame's own flat white reaches into the shoulder.
    public let shoulderEngaged: Bool

    /// `exposure` defaults to 0, the pre-exposure algebra exactly, so a stage built by hand
    /// is what it always was. The shipped stage passes `DevelopConstants.printExposure`.
    public init(gamma: Double, pivot: Double, black: Double, white: Double, kneeWidth: Double,
                toeEngaged: Bool, shoulderEngaged: Bool, exposure: Double = 0) {
        self.gamma = gamma; self.exposure = exposure
        self.pivot = pivot; self.black = black; self.white = white
        self.kneeWidth = kneeWidth
        self.toeEngaged = toeEngaged; self.shoulderEngaged = shoulderEngaged
    }

    /// The minimum density the stage may emit, which is `white` read as a density.
    public var minDensity: Double { -log10(white) }
    /// The maximum density the stage may emit, which is `black` read as a density.
    public var maxDensity: Double { -log10(black) }

    /// A sweep override for the paper stage, so a variant strip costs one render each
    /// instead of one rebuild each.
    ///
    /// Every field is optional and nil means "the shipped constant", so an override that
    /// names nothing is the shipped stage exactly. **The app never writes this.** It is
    /// written from the FP_PRINT_* environment variables, which exist so variants can be
    /// looked at before one is picked, without a rebuild per variant.
    public struct Override: Equatable, Sendable {
        public var gamma: Double?
        public var exposure: Double?
        public var kneeWidth: Double?
        public var black: Double?
        public var white: Double?
        /// Where the PLACEMENT sends the frame's own white on a Print render, which is a
        /// different question from `white`: `white` is the paper's Dmin, the ceiling the
        /// shoulder holds, and this is the value the flat base hands the paper stage in
        /// the first place. Overriding it is the only thing in here that touches the
        /// placement, and it touches it for `.print` alone. Nil is
        /// `DevelopConstants.printPlacedWhite`.
        public var placedWhite: Double?

        public init(gamma: Double? = nil, exposure: Double? = nil, kneeWidth: Double? = nil,
                    black: Double? = nil, white: Double? = nil, placedWhite: Double? = nil) {
            self.gamma = gamma; self.exposure = exposure; self.kneeWidth = kneeWidth
            self.black = black; self.white = white; self.placedWhite = placedWhite
        }

        public var isEmpty: Bool {
            gamma == nil && exposure == nil && kneeWidth == nil && black == nil && white == nil
                && placedWhite == nil
        }

        /// FP_PRINT_GAMMA, FP_PRINT_EXPOSURE, FP_PRINT_KNEE, FP_PRINT_BLACK, FP_PRINT_WHITE,
        /// FP_PRINT_PLACED_WHITE.
        /// Nil when none of them is set, so an unset environment cannot change a render.
        /// A variable set to something that is not a number is a typo, not a request, and
        /// it is ignored rather than silently read as zero.
        public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Override? {
            func number(_ key: String) -> Double? { env[key].flatMap(Double.init) }
            let o = Override(gamma: number("FP_PRINT_GAMMA"),
                             exposure: number("FP_PRINT_EXPOSURE"),
                             kneeWidth: number("FP_PRINT_KNEE"),
                             black: number("FP_PRINT_BLACK"),
                             white: number("FP_PRINT_WHITE"),
                             placedWhite: number("FP_PRINT_PLACED_WHITE"))
            return o.isEmpty ? nil : o
        }

        /// The one line a sweep render prints so a strip's label can never disagree with
        /// the numbers that produced it.
        public var summary: String {
            String(format: "gamma %.4f exposure %.4f knee %.5f black %.4f white %.4f placedWhite %.4f",
                   gamma ?? DevelopConstants.printGamma,
                   exposure ?? DevelopConstants.printExposure,
                   kneeWidth ?? DevelopConstants.printKneeWidth,
                   black ?? DevelopConstants.printBlack,
                   white ?? DevelopConstants.printWhite,
                   placedWhite ?? DevelopConstants.printPlacedWhite)
        }
    }

    /// Nil, the default and the only value the app ever uses, means every number comes
    /// from `DevelopConstants`.
    public static var override: Override? = nil

    /// The shipped stage, sized against the flat placement the frame actually got, with
    /// any sweep override applied.
    public static func shipped(flatBlack: Double, flatWhite: Double) -> PrintStage {
        let o = PrintStage.override
        return sized(gamma: o?.gamma ?? DevelopConstants.printGamma,
                     exposure: o?.exposure ?? DevelopConstants.printExposure,
                     flatBlack: flatBlack, flatWhite: flatWhite)
    }

    /// The paper stage with NO paper in it: the same straight gamma about mid grey and the
    /// same exposure offset, clamped to 0...1, with no toe, no shoulder and no 0.02 / 0.98
    /// limits. What None and Flat run when the Tone row's Adjust moves their exposure or
    /// contrast. Those two tones are straight lines already, so the knees would put a step
    /// in the slider at its preset: one notch of exposure off Flat would pull its white from
    /// 0.92 to 0.909 through the shoulder. Bold keeps `sized`, knees and all.
    ///
    /// A zero knee width makes `printKnees` a clamp: past either end it returns the limit
    /// outright, and the quadratic (the only place `w` divides) is never reached.
    public static func straight(gamma: Double, exposure: Double) -> PrintStage {
        PrintStage(gamma: gamma, pivot: DevelopConstants.middleGray, black: 0, white: 1,
                   kneeWidth: 0, toeEngaged: false, shoulderEngaged: false, exposure: exposure)
    }

    /// A stage of the given gamma and exposure, sized against the flat placement exactly as
    /// `shipped` sizes Bold's: the pivot, the 0.02 and 0.98 limits and the knee width stay
    /// the constants (or a sweep override of them). `shipped` is this with Bold's two
    /// numbers, so the Tone row's Adjust and Bold build their stage one way.
    public static func sized(gamma: Double, exposure: Double,
                             flatBlack: Double, flatWhite: Double) -> PrintStage {
        let o = PrintStage.override
        let stage = PrintStage(gamma: gamma,
                               pivot: DevelopConstants.middleGray,
                               black: o?.black ?? DevelopConstants.printBlack,
                               white: o?.white ?? DevelopConstants.printWhite,
                               kneeWidth: o?.kneeWidth ?? DevelopConstants.printKneeWidth,
                               toeEngaged: false, shoulderEngaged: false,
                               exposure: exposure)
        let k = stage.kneeWidth
        let blackD = DevelopMath.printStraightDensity(flatBlack, stage)
        let whiteD = DevelopMath.printStraightDensity(flatWhite, stage)
        return PrintStage(gamma: stage.gamma, pivot: stage.pivot,
                          black: stage.black, white: stage.white, kneeWidth: k,
                          toeEngaged: blackD > stage.maxDensity - k,
                          shoulderEngaged: whiteD < stage.minDensity + k,
                          exposure: stage.exposure)
    }
}

/// What the tone step will do to this frame: the whole of pass 2's tone stage, and the
/// numbers the inspector shows. Nothing here is per pixel; the LUT is built from it once.
public struct ToneStep: Equatable, Sendable {
    /// Which operator produced this step.
    public let op: AutoToneOperator
    /// The frame's own P0.5 in the post-physics normalized domain, 0...1.
    public let black: Double
    /// Where `black` is sent. `DevelopConstants.placedBlack`.
    public let placedBlack: Double
    /// Where the frame's own white is sent. `DevelopConstants.placedWhite`.
    public let placedWhite: Double
    /// The linear gain applied after the black is subtracted.
    public let gain: Double
    /// True when `gain` was cut by the cap rather than by the measurement.
    public let gainAtCap: Bool
    /// The frame's own P50 the exponent was derived from, after the black subtraction and
    /// the gain.
    public let median: Double
    public let exponent: Double
    /// True when the exponent was cut by a bound rather than by the measurement.
    public let exponentAtBound: Bool
    /// The paper contrast stage, present only for `print`. Everything above it describes
    /// the placement, which `print` shares with `flat` unchanged.
    public let printStage: PrintStage?
    public init(op: AutoToneOperator, black: Double, placedBlack: Double, placedWhite: Double,
                gain: Double, gainAtCap: Bool, median: Double, exponent: Double, exponentAtBound: Bool,
                printStage: PrintStage? = nil) {
        self.op = op; self.black = black; self.placedBlack = placedBlack; self.placedWhite = placedWhite
        self.gain = gain; self.gainAtCap = gainAtCap; self.median = median
        self.exponent = exponent; self.exponentAtBound = exponentAtBound
        self.printStage = printStage
    }

    /// The one line the inspector shows. It names a clamp that fired, because a silent one
    /// is indistinguishable from an operator that hit its target.
    public var inspectorSummary: String {
        var text = String(format: "black %.2f -> %.2f, white -> %.2f, exponent %.2f",
                          black, placedBlack, placedWhite, exponent)
        if exponentAtBound { text += " (at the bound)" }
        if gainAtCap { text += String(format: ", gain %.2f (at the cap)", gain) }
        if let p = printStage {
            text += String(format: ", then print gamma %.2f, toe at %.2f, shoulder at %.2f",
                           p.gamma, p.black, p.white)
            // Only when it is doing something. A line that reads "exposure 0.00" on
            // every shipped render teaches the eye to skip the number, which is
            // exactly the wrong habit for the one knob a sweep is about to turn.
            if p.exposure != 0 { text += String(format: ", exposure %+.2f D", p.exposure) }
            // Same rule as the exposure above: named only when it is not the shipped
            // constant. `white -> %.2f` at the top of the line already carries the value,
            // and this says outright that the placement ceiling was moved for this render,
            // which is the thing a sweep strip's label has to be able to prove.
            if placedWhite != DevelopConstants.printPlacedWhite {
                text += String(format: ", placed white %.2f", placedWhite)
            }
        }
        return text
    }
}

public struct DevelopInput: Sendable {
    /// The base pair as RESOLVED by `BaseResolver`: picked, from the film edge, estimated from
    /// the picture, or neutral. It is the
    /// base every measurement in `analyze` is taken through, and the manual axes never
    /// change it.
    public var ratios: BaseRatios
    /// The two manual color axes, in printer points. Identity unless a person moved them.
    public var colourAxes: ColourAxes = .identity

    /// The axes as per-channel DENSITY offsets, which is the one and only form in which
    /// they reach the kernel.
    ///
    /// THE ORDERING: any processing happens after what the film profile does, and never
    /// undoes it.
    ///
    /// So the stock's channel balance always runs when the profile declares it, at full
    /// strength, measured from the film. The grade is a density offset applied to the
    /// RENDERED value only (`density(_:base:mono:box:axisOffsets:)`), never to the
    /// histograms the balance is fitted to.
    ///
    /// What that buys, and it is the property the whole naming argument rests on: `q` is
    /// linear in density, so one printer point is 0.025 density and 381.02 q units on every
    /// frame, identically. The unit is a unit.
    ///
    /// Folding the axes into the base pair would put them UPSTREAM of the histograms, so the
    /// balance would re-fit to the graded frame and cancel part of the grade: 63.3, 64.3 and
    /// 100.2 percent retained on three scenes. Switching the balance OFF while an axis is
    /// moved would cost cinestill-800t the whole of the contrast operator its profile
    /// declares, about 35 percent measured over 8 frames, and put a step in the control at
    /// zero. Here nothing switches and nothing re-fits, so moving an axis off zero changes
    /// the picture by exactly the points asked for.
    public var axisOffsets: [Double] {
        let o = colourAxes.logOffsets
        return [o.r, o.g, o.b]
    }
    /// The same two axes in printer points, acting on the stock's HIGHLIGHT end: a
    /// profile-building function that trims a stock's red and blue contrast. Identity unless
    /// a caller sets it, and no frame's sidecar reaches it (`RenderService.developInput`
    /// leaves it identity). Set after `init` rather than through it, so every existing call
    /// site stays as it was.
    public var highlightAxes: ColourAxes = .identity

    /// The highlight axes as per-channel DENSITY offsets on the physics CEILINGS, the one
    /// form in which they reach the kernel (`DevelopMath.physicsRanges`).
    ///
    /// The Base axes' own pattern, `logOffsets`, NEGATED, and the sign is the whole point.
    /// The remap is `(q - floor) / (ceiling - floor)`, so a LOWER ceiling reaches white
    /// sooner and makes that channel BRIGHTER toward the top of the range. Warm must make
    /// the highlights warmer on screen, so Warm lowers red's ceiling and raises blue's;
    /// Magenta lowers both red's and blue's together. Green's ceiling never moves (its
    /// `logOffsets` term is exactly 0), so the tone step, which reads green alone, cannot
    /// see these axes at all. The floor is not touched, so the effect is zero at the dark
    /// end and grows toward the highlights, which is what makes it a highlights control.
    ///
    /// Mono ignores them, as it ignores the Base axes: `analyze` does not pass them for a
    /// mono frame, because the mono table reads channel 0's range.
    public var ceilingOffsets: [Double] {
        let o = highlightAxes.logOffsets
        return [-o.r, 0, -o.b]
    }
    public var dyeGamma: DyeGamma
    public var mono: Bool
    public var autoTone: Bool
    /// Which operator `autoTone` runs. Defaulted so every existing call site keeps the
    /// behavior it had.
    public var autoToneOperator: AutoToneOperator
    /// Whether the STOCK asks for each color channel to be balanced on its own before the
    /// tone step. Declared by the film profile, never by a button: see
    /// `DevelopMath+Balance.swift` for why that distinction is the whole design.
    public var balanceChannels: Bool
    /// How far toward the full balance to go, from the PROFILE FILE, 0 being the exact
    /// identity and 1 the whole operator. Azure ships 1. It is a parameter of the stock
    /// rather than of the code: changing it is editing a profile, not editing Swift.
    public var balanceStrength: Double
    /// Where `ratios` came from, carried so the analysis can tell the inspector. It is
    /// reporting only, and it describes the RESOLVED pair: the manual axes are not a base
    /// source and never change this.
    public var baseSource: BaseSource?

    public init(ratios: BaseRatios, dyeGamma: DyeGamma, mono: Bool, autoTone: Bool,
                colourAxes: ColourAxes = .identity,
                autoToneOperator: AutoToneOperator = .anchored,
                balanceChannels: Bool = false, balanceStrength: Double = 1,
                baseSource: BaseSource? = nil) {
        self.ratios = ratios; self.dyeGamma = dyeGamma; self.mono = mono; self.autoTone = autoTone
        self.colourAxes = colourAxes
        self.autoToneOperator = autoToneOperator
        self.balanceChannels = balanceChannels; self.balanceStrength = balanceStrength
        self.baseSource = baseSource
    }

    /// The Tone row's Adjust, the person's own four tone values. nil, the default, runs the
    /// operator's own tone step unadjusted. Non-nil builds the
    /// step from these values (`DevelopMath.adjustedTone`), with `autoTone` still deciding
    /// whether the placement is MEASURED, so None stays unmeasured and its physics range
    /// does not move.
    public var toneAdjust: ToneAdjust? = nil

    /// The Tone row's Stretch, 0...1, clamped where it is read
    /// (`DevelopMath.stretchedGreenCeiling`). 1, the default, maps the frame's own green
    /// ceiling to white exactly as before; lower values blend it toward `whiteDensity`.
    public var stretch: Double = 1
    /// The stock's reference white density, the ceiling Stretch 0 maps to white
    /// (`ProfileLibrary.whiteDensity(for:)`).
    public var whiteDensity: Double = ProfileLibrary.genericWhiteDensity
}

public struct ChannelRange: Equatable, Sendable {
    public var lo: Int
    public var hi: Int

    /// Public so a test outside this module can hand the channel balance a range it
    /// chose, and assert the two endpoints it gets back against arithmetic rather than
    /// against whatever a real frame happened to produce.
    public init(lo: Int, hi: Int) { self.lo = lo; self.hi = hi }
}

/// Everything pass 1 learns about a frame. Small; the density buffer travels separately.
public struct FrameAnalysis: Sendable {
    /// Anchor code value: P99.8 of clip-guarded green (luminance for mono).
    public let anchor: Int
    /// Base per channel, `[anchor * rg, anchor, anchor * bg]` (all equal for mono).
    public let base: [Double]
    /// Percentile ranges per channel over the inset area (P0.5, P99.5), lab modes only.
    public let percentile: [ChannelRange]
    /// Physics ranges per channel: floor at the toe below film base, ceilings from the
    /// green ceiling times the dye gammas.
    public let physics: [ChannelRange]
    /// Coarse 1024-bin density histogram per channel over the inset area.
    public let coarse: [[UInt32]]
    /// Samples in the inset area.
    public let sampleCount: Int
    /// Auto tone: what pass 2's tone stage will do, or nil when the toggle is off.
    public let tone: ToneStep?
    /// The per-channel balance the STOCK asked for, or nil when it asked for none, which is
    /// every stock but one. It runs BEFORE `tone`, and `tone` was measured through it.
    public let balance: ChannelBalance?
    /// Where `base` came from, for the info icon beside Auto color. nil only for an
    /// analysis built by hand, where no resolver ran.
    public var baseSource: BaseSource?
    /// The frame's own green ceiling and its stock's reference, for the Tone row's thin
    /// warning. nil only for an analysis built by hand.
    public var stretch: StretchReading?

    public init(anchor: Int, base: [Double], percentile: [ChannelRange], physics: [ChannelRange],
                coarse: [[UInt32]], sampleCount: Int, tone: ToneStep? = nil,
                balance: ChannelBalance? = nil,
                baseSource: BaseSource? = nil) {
        self.anchor = anchor; self.base = base; self.percentile = percentile; self.physics = physics
        self.coarse = coarse; self.sampleCount = sampleCount; self.tone = tone
        self.balance = balance
        self.baseSource = baseSource
    }

    /// The median the tone exponent was derived from.
    public var median: Double? { tone?.median }
}

public struct DensityFrame: Sendable {
    public let width: Int
    public let height: Int
    /// Quantised density, RGB interleaved, 0...65535 over D_MIN...D_MAX.
    public let q: [UInt16]
}

public enum DevelopMath {

    // MARK: pass 1

    /// Anchor: histogram of every fourth row and column, skipping any pixel with a channel
    /// at or above the clip guard (direct light is never base), then the P99.8 from the top.
    public static func anchor(_ f: DecodedFrame, mono: Bool) -> Int {
        var hist = [UInt32](repeating: 0, count: 65536)
        var n = 0
        let w = f.width, h = f.height
        f.pixels.withUnsafeBufferPointer { p in
            var y = 0
            while y < h {
                var x = 0
                while x < w {
                    let i = (y * w + x) * 3
                    let r = p[i], g = p[i + 1], b = p[i + 2]
                    if g >= DevelopConstants.clipGuard || r >= DevelopConstants.clipGuard || b >= DevelopConstants.clipGuard {
                        x += 4; continue
                    }
                    let bin = mono ? min(65535, Int(jsRound(Double(Int(r) + Int(g) + Int(b)) / 3))) : Int(g)
                    hist[bin] += 1
                    n += 1
                    x += 4
                }
                y += 4
            }
        }
        var gA = 65535
        if n > 0 {
            let target = Double(n) * (1 - DevelopConstants.pAnchor)
            var s = 0.0
            var b = 65535
            while b >= 0 {
                s += Double(hist[b])
                if s >= target { gA = b; break }
                b -= 1
            }
        }
        return gA
    }

    public static func base(anchor: Int, ratios: BaseRatios, mono: Bool) -> [Double] {
        let g = Double(anchor)
        return mono ? [g, g, g] : [g * ratios.rg, g, g * ratios.bg]
    }

    /// Density above base, quantised, plus the inset-area histograms. Double throughout.
    ///
    /// `box`, when given, is the region the HISTOGRAMS are accumulated over, in place of
    /// the 6 percent inset of the whole scan. The quantised density is still produced for
    /// every pixel; only the statistics move. The inset exists to keep the scan's outer
    /// edge out of the numbers, and a crop box is a better version of the same idea: it is
    /// the picture, with none of the rebate ring. The rebate renders to black, so leaving
    /// it in pulls the median and the P0.5 down on every frame in the same direction
    /// (measured across one roll: `m` low by 0.0001 to 0.0624, mean 0.0137).
    /// - Parameter axisOffsets: per-channel density offsets from the manual color axes, in
    ///   density units, applied to the RENDERED value and deliberately NOT to the histograms.
    ///
    ///   That split is the whole design of the axes, and it is exact rather than approximate.
    ///   `d` is `log10(base) - log10(pixel)` and `q` is linear in `d`, so offsetting
    ///   `log10(base)` by a constant shifts every pixel of that channel by the SAME amount:
    ///   one printer point is 0.025 density, which is 381.02 q units on every frame, always.
    ///   That is what makes the unit a unit.
    ///
    ///   The histograms stay ungraded so that everything measured FROM them, above all the
    ///   stock's channel balance, describes the film rather than the person's grade. An
    ///   operator that re-fits to the graded frame undoes the grade (63 percent retained on one
    ///   measured scene). An operator fitted to the film leaves it alone.
    public static func density(_ f: DecodedFrame, base: [Double], mono: Bool, box: CropBox? = nil,
                               axisOffsets: [Double] = [0, 0, 0])
        -> (q: [UInt16], hist: [[UInt32]], sampleCount: Int) {
        let w = f.width, h = f.height, npx = w * h
        var q = [UInt16](repeating: 0, count: npx * 3)
        var hist0 = [UInt32](repeating: 0, count: 65536)
        var hist1 = [UInt32](repeating: 0, count: 65536)
        var hist2 = [UInt32](repeating: 0, count: 65536)
        let x0 = box.map { max(0, $0.x0) } ?? Int((Double(w) * DevelopConstants.inset).rounded(.down))
        let x1 = box.map { min(w, $0.x1) } ?? Int((Double(w) * (1 - DevelopConstants.inset)).rounded(.up))
        let y0 = box.map { max(0, $0.y0) } ?? Int((Double(h) * DevelopConstants.inset).rounded(.down))
        let y1 = box.map { min(h, $0.y1) } ?? Int((Double(h) * (1 - DevelopConstants.inset)).rounded(.up))
        let dMin = DevelopConstants.dMin, dRange = DevelopConstants.dRange
        let logBase = base.map { log10($0) }
        let logBaseMono = log10((base[0] + base[1] + base[2]) / 3)
        var nS = 0

        f.pixels.withUnsafeBufferPointer { p in
            q.withUnsafeMutableBufferPointer { qp in
                hist0.withUnsafeMutableBufferPointer { h0 in
                hist1.withUnsafeMutableBufferPointer { h1 in
                hist2.withUnsafeMutableBufferPointer { h2 in
                    for y in 0..<h {
                        let inRow = y >= y0 && y < y1
                        for x in 0..<w {
                            let i = y * w + x
                            let inArea = inRow && x >= x0 && x < x1
                            if inArea { nS += 1 }
                            if mono {
                                let s = Double(Int(p[i * 3]) + Int(p[i * 3 + 1]) + Int(p[i * 3 + 2]))
                                let v = s / 3
                                let d = logBaseMono - log10(v > 0 ? v : 1)
                                var qi = Int(jsRound(((d - dMin) / dRange) * 65535))
                                qi = qi < 0 ? 0 : (qi > 65535 ? 65535 : qi)
                                let u = UInt16(qi)
                                qp[i * 3] = u; qp[i * 3 + 1] = u; qp[i * 3 + 2] = u
                                if inArea { h0[qi] += 1; h1[qi] += 1; h2[qi] += 1 }
                            } else {
                                for c in 0..<3 {
                                    let v = Double(p[i * 3 + c])
                                    let d = logBase[c] - log10(v > 0 ? v : 1)
                                    // The HISTOGRAM bin, ungraded, which is what the stock's
                                    // operators are measured from.
                                    var hi = Int(jsRound(((d - dMin) / dRange) * 65535))
                                    hi = hi < 0 ? 0 : (hi > 65535 ? 65535 : hi)
                                    // The RENDERED value, carrying the grade. Offset in the
                                    // continuous domain before quantising, so the unit is not
                                    // rounded twice.
                                    var qi = Int(jsRound(((d + axisOffsets[c] - dMin) / dRange) * 65535))
                                    qi = qi < 0 ? 0 : (qi > 65535 ? 65535 : qi)
                                    qp[i * 3 + c] = UInt16(qi)
                                    if inArea {
                                        switch c { case 0: h0[hi] += 1; case 1: h1[hi] += 1; default: h2[hi] += 1 }
                                    }
                                }
                            }
                        }
                    }
                }}}
            }
        }
        return (q, [hist0, hist1, hist2], nS)
    }

    static func percentiles(_ hist: [UInt32], sampleCount: Int) -> ChannelRange {
        var lo = 0, hi = 65535
        let tLo = Double(sampleCount) * DevelopConstants.pLo
        let tHi = Double(sampleCount) * DevelopConstants.pHi
        var s = 0.0
        for b in 0..<65536 { s += Double(hist[b]); if s >= tLo { lo = b; break } }
        s = 0
        for b in 0..<65536 { s += Double(hist[b]); if s >= tHi { hi = b; break } }
        return ChannelRange(lo: lo, hi: max(hi, lo + 1))
    }

    /// Physics normalization: floor at the toe below film base for every channel, green
    /// ceiling from the frame, red and blue ceilings from the dye gammas.
    ///
    /// `ceilingOffsets` are the Stock row's highlight axes as per-channel density offsets on
    /// each CEILING (`DevelopInput.ceilingOffsets`), added in the continuous domain before
    /// quantizing. Zero leaves the ranges exactly unchanged, since `x + 0.0` is `x`.
    ///
    /// THE CLAMP: a ceiling can never fall to or below the floor. However far a typed value
    /// pulls it down, it stops one code value above the floor, the same guard a degenerate
    /// frame always had, so the remap's divisor is never zero or negative.
    public static func physicsRanges(greenHi: Int, dyeGamma: DyeGamma,
                                     ceilingOffsets: [Double] = [0, 0, 0]) -> [ChannelRange] {
        let gHiD = dOfQ(greenHi)
        let lo = qOfD(DevelopConstants.dToe)
        return zip([dyeGamma.r, dyeGamma.g, dyeGamma.b], ceilingOffsets).map { g, offset in
            ChannelRange(lo: lo, hi: max(qOfD(gHiD * g + offset), lo + 1))
        }
    }

    /// The frame's own normalized green median, from the coarse histogram, taking the
    /// containing bin's low edge.
    static func normalisedMedian(coarseGreen: [UInt32], sampleCount: Int, green: ChannelRange) -> Double {
        var acc = 0.0
        var medQ = green.lo
        let half = Double(sampleCount) * 0.5
        for b in 0..<1024 { acc += Double(coarseGreen[b]); if acc >= half { medQ = b << 6; break } }
        return Double(medQ - green.lo) / Double(green.hi - green.lo)
    }

    /// Anchored auto tone: place the frame's measured black, then a bounded exponent on
    /// what is left.
    ///
    ///     b     = the frame's own P0.5, in the post-physics normalized domain
    ///     gain  = min(1 / (1 - b), gainCap)
    ///     m     = the frame's own P50, after that same stretch
    ///     g     = clamp(ln(middleGray) / ln(m), exponentMin, exponentMax)
    ///     out   = placedBlack + (placedWhite - placedBlack) * clamp((v - b) * gain, 0, 1) ^ g
    ///
    /// Two measured numbers, four declared constants, three declared bounds, and every one
    /// of them reported. `greenPercentile.lo` is the P0.5 of green density and needs no new
    /// measurement: it is already in the analysis.
    /// `balance`, when present, is the GREEN channel's balance, and it is applied to the two
    /// numbers this operator measures before they are used. The balance runs first in the
    /// render, so a black and a median measured on unbalanced data and then applied to
    /// balanced data would put the roll's black somewhere other than `placedBlack`, which is
    /// the one thing Flat exists to guarantee. Pushing them through is exact: the balance is
    /// non-decreasing, so it carries a percentile to that percentile.
    public static func anchoredAutoTone(coarseGreen: [UInt32], sampleCount: Int,
                                        greenPercentile: ChannelRange, greenPhysics: ChannelRange,
                                        balance: ChannelBalance? = nil) -> ToneStep {
        // The WHOLE balance, not just green's endpoints: the strength changes the map, so
        // measuring through the endpoints alone would measure a curve the render is not
        // applying.
        func through(_ x: Double) -> Double {
            guard let b = balance else { return x }
            return balanced(x, b.channels[1], strength: b.strength)
        }
        let span = Double(greenPhysics.hi - greenPhysics.lo)
        // The measured black, in the same 0...1 domain pass 2's remap produces. Clamped
        // only against the degenerate frame whose P0.5 sits at or above the ceiling, which
        // would otherwise divide by zero in the gain.
        var b = Double(greenPercentile.lo - greenPhysics.lo) / span
        b = through(b)
        b = b < 0 ? 0 : (b > 0.98 ? 0.98 : b)
        let wantGain = 1 / (1 - b)
        let gain = min(wantGain, DevelopConstants.gainCap)
        // The median, put through the same stretch, so the exponent is derived from the
        // frame the exponent will actually see.
        var raw50 = normalisedMedian(coarseGreen: coarseGreen, sampleCount: sampleCount, green: greenPhysics)
        raw50 = through(raw50)
        var m = (raw50 - b) * gain
        m = m < 0.02 ? 0.02 : (m > 0.98 ? 0.98 : m)
        let wantExponent = log(DevelopConstants.middleGray) / log(m)
        let lo = DevelopConstants.exponentMin, hi = DevelopConstants.exponentMax
        let g = wantExponent < lo ? lo : (wantExponent > hi ? hi : wantExponent)
        return ToneStep(op: .anchored, black: b,
                        placedBlack: DevelopConstants.placedBlack,
                        placedWhite: DevelopConstants.placedWhite,
                        gain: gain, gainAtCap: wantGain > DevelopConstants.gainCap,
                        median: m, exponent: g,
                        exponentAtBound: wantExponent < lo || wantExponent > hi)
    }

    /// Print tone: the anchored placement, with the paper contrast stage attached. Exactly
    /// the same two measurements and the same bounds as Flat, which is what makes the two
    /// modes comparable on the same frame.
    ///
    /// The ONE number the two placements do not have to share is the white. Flat's ceiling
    /// is the editable base's and stays 0.92. Print reads `DevelopConstants.printPlacedWhite`,
    /// because a print may reach paper white and Flat's 92 percent would cap every print
    /// render below it with no way for the shoulder to raise it. That constant is 1.0, so a
    /// Print render places its white a full stop above Flat's and the paper shoulder is
    /// what holds the top down.
    ///
    /// The value that actually ran is carried in `ToneStep.placedWhite` and sizes the
    /// paper stage's shoulder, so the inspector reports the render rather than the constant.
    public static func printAutoTone(coarseGreen: [UInt32], sampleCount: Int,
                                     greenPercentile: ChannelRange, greenPhysics: ChannelRange,
                                     balance: ChannelBalance? = nil) -> ToneStep {
        let flat = anchoredAutoTone(coarseGreen: coarseGreen, sampleCount: sampleCount,
                                    greenPercentile: greenPercentile, greenPhysics: greenPhysics,
                                    balance: balance)
        let placedWhite = PrintStage.override?.placedWhite ?? DevelopConstants.printPlacedWhite
        return ToneStep(op: .print, black: flat.black,
                        placedBlack: flat.placedBlack, placedWhite: placedWhite,
                        gain: flat.gain, gainAtCap: flat.gainAtCap,
                        median: flat.median, exponent: flat.exponent,
                        exponentAtBound: flat.exponentAtBound,
                        printStage: PrintStage.shipped(flatBlack: flat.placedBlack,
                                                       flatWhite: placedWhite))
    }

    // MARK: the paper contrast stage
    //
    // A pure function of one flat output value, computed entirely in density space because
    // that is the space a paper's characteristic curve lives in. Two parts, in this order.
    //
    //   1. A straight gamma about the mid-gray pivot:
    //
    //          d  = -log10(v),  pivotD = -log10(pivot)
    //          dp = pivotD + gamma * (d - pivotD)
    //
    //      The pivot maps to itself exactly and the slope in density space is exactly
    //      `gamma`, both by construction, which is what the tests assert.
    //
    //   2. A quadratic soft knee at each end, also in density space. Density is what makes
    //      one width serve both ends: the same density margin is a wide span of VALUES next
    //      to white and a very narrow one next to black, which is how a paper curve
    //      actually behaves. Write the knee in value units instead and a width that keeps
    //      the highlights soft lifts the blacks into mud.
    //
    //          shoulder (approaching paper white, so low density), for dp below
    //          T = minDensity + w:
    //              y = dp + (T - dp)^2 / (4w)   until dp = T - 2w, then y = minDensity
    //          toe (approaching Dmax, so high density), for dp above T = maxDensity - w:
    //              y = dp - (dp - T)^2 / (4w)   until dp = T + 2w, then y = maxDensity
    //
    //      Value and first derivative are continuous at both junctions (slope 1 where a
    //      knee starts, slope 0 where it closes), so the whole map is C1. It is
    //      non-decreasing in dp and therefore non-decreasing in the output value, and
    //      nothing leaves [black, white]. The knees cannot overlap: the gap between them is
    //      1.690 density and each is 0.136 wide.
    //
    //      A quadratic rather than a rational or a tanh knee for one reason: it reaches its
    //      limit at a finite input. A paper cannot print whiter than Dmin or blacker than
    //      Dmax, so the limit is reached in the real thing too, and an asymptotic knee
    //      would leave the operator unable to place either endpoint at all.

    /// The straight gamma as a DENSITY, plus the paper exposure offset. Separated so a
    /// test can assert the pivot and the slope without the knees in the way, and so the
    /// knees can work in the same space.
    ///
    /// The offset is added here rather than folded into the gamma because it is a
    /// different physical thing: the gamma is the paper's contrast and it pivots about
    /// mid-gray, the offset is how long the paper was exposed and it slides the whole
    /// curve. At `exposure` 0 this is the pre-exposure expression term for term.
    @inline(__always)
    public static func printStraightDensity(_ v: Double, _ stage: PrintStage) -> Double {
        guard v > 0 else { return .infinity }
        let pivotD = -log10(stage.pivot)
        return pivotD + stage.gamma * (-log10(v) - pivotD) + stage.exposure
    }

    /// The straight gamma as a value. `pivot * (v / pivot)^gamma * 10^(-exposure)`, which
    /// is the same thing written without the logs.
    @inline(__always)
    public static func printStraight(_ v: Double, _ stage: PrintStage) -> Double {
        v > 0 ? stage.pivot * pow(v / stage.pivot, stage.gamma) * pow(10, -stage.exposure) : 0
    }

    /// The toe and the shoulder, on a density.
    @inline(__always)
    public static func printKnees(density d: Double, _ stage: PrintStage) -> Double {
        let w = stage.kneeWidth
        var y = d
        let shoulder = stage.minDensity + w
        if y < shoulder {
            let s = shoulder - y
            y = s >= 2 * w ? stage.minDensity : y + (s * s) / (4 * w)
        }
        let toe = stage.maxDensity - w
        if y > toe {
            let s = y - toe
            y = s >= 2 * w ? stage.maxDensity : y - (s * s) / (4 * w)
        }
        return y
    }

    /// The whole paper contrast stage: one flat output value in, one print value out.
    @inline(__always)
    public static func printTone(_ v: Double, _ stage: PrintStage) -> Double {
        pow(10, -printKnees(density: printStraightDensity(v, stage), stage))
    }

    /// Pass 1.
    ///
    /// `toneBox` restricts the percentile and coarse histograms to the picture when the
    /// frame has a crop. The ANCHOR is deliberately not restricted: the anchor is the film
    /// base, and the film base is the rebate, which lives outside every crop box. So the
    /// two measurements read the two regions each of them actually needs.
    public static func analyze(_ f: DecodedFrame, input: DevelopInput, toneBox: CropBox? = nil) -> (FrameAnalysis, DensityFrame) {
        let a = anchor(f, mono: input.mono)
        // The RESOLVED base, ungraded. The manual axes ride along as a density offset on the
        // rendered value, which keeps every measurement below describing the film.
        let b = base(anchor: a, ratios: input.ratios, mono: input.mono)
        let (q, hist, nS) = density(f, base: b, mono: input.mono, box: toneBox,
                                    axisOffsets: input.axisOffsets)
        let pct = (0..<3).map { percentiles(hist[$0], sampleCount: nS) }
        var coarse = [[UInt32]](repeating: [UInt32](repeating: 0, count: 1024), count: 3)
        for c in 0..<3 { for bin in 0..<65536 { coarse[c][bin >> 6] &+= hist[c][bin] } }
        // The Stretch control replaces the measured green ceiling with one blended toward the
        // stock's reference white. At stretch 1, and on any frame whose own ceiling reaches
        // the reference, this is the measured code value itself, so those renders are
        // byte-identical to a render without the control.
        let greenHi = stretchedGreenCeiling(pct[1].hi, whiteDensity: input.whiteDensity,
                                            stretch: input.stretch)
        let filmPhys = physicsRanges(greenHi: greenHi, dyeGamma: input.mono ? .neutral : input.dyeGamma)
        // The highlight axes move the red and blue ceilings the RENDER uses, and nothing
        // that is measured. Identity, and every mono frame, take the film's ranges
        // unchanged.
        let phys = input.mono || input.highlightAxes.isIdentity
            ? filmPhys
            : physicsRanges(greenHi: greenHi, dyeGamma: input.dyeGamma,
                            ceilingOffsets: input.ceilingOffsets)

        // The balance is measured FIRST and applied first, because the stock asked for it and
        // because the tone step has to see the frame the tone step will actually operate on.
        // The frame is measured on its own. It reads the FULL histograms rather than the
        // coarse green, because a 0.1 percent clip is finer than a 1024-bin histogram can
        // resolve honestly.
        var balance: ChannelBalance? = nil
        if input.balanceChannels {
            // It takes the strength the stock's profile set. At strength 1, which is what
            // Azure ships, `with` copies every field unchanged.
            //
            // Measured through the FILM's ranges, never the graded ones. The balance stretches
            // each channel's own 99.9th percentile to white, so measuring it through a moved
            // ceiling would re-fit to the grade and cancel it, the same 63 percent retention
            // measured for the Base axes.
            balance = frameBalance(hist: hist, sampleCount: nS, physics: filmPhys)
                .with(strength: input.balanceStrength)
        }

        var tone: ToneStep? = nil
        if input.autoTone {
            switch input.autoToneOperator {
            case .anchored:
                tone = anchoredAutoTone(coarseGreen: coarse[1], sampleCount: nS,
                                        greenPercentile: pct[1], greenPhysics: phys[1], balance: balance)
            case .print:
                tone = printAutoTone(coarseGreen: coarse[1], sampleCount: nS,
                                     greenPercentile: pct[1], greenPhysics: phys[1], balance: balance)
            }
        }
        // The Tone row's Adjust replaces the step's four values and keeps what was
        // measured. nil never reaches this, so a frame nobody adjusted runs the lines above
        // and nothing else.
        if let adjust = input.toneAdjust {
            tone = adjustedTone(measured: tone, adjust: adjust)
        }
        var analysis = FrameAnalysis(anchor: a, base: b, percentile: pct, physics: phys, coarse: coarse,
                                     sampleCount: nS, tone: tone, balance: balance,
                                     baseSource: input.baseSource)
        analysis.stretch = StretchReading(ownCeiling: dOfQ(pct[1].hi), whiteDensity: input.whiteDensity)
        return (analysis, DensityFrame(width: f.width, height: f.height, q: q))
    }

    // MARK: pass 2

    public struct CropBox: Equatable, Sendable {
        public var x0: Int, y0: Int, x1: Int, y1: Int
        public init(x0: Int, y0: Int, x1: Int, y1: Int) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
        public var width: Int { x1 - x0 }
        public var height: Int { y1 - y0 }
    }

    /// The anchored tone LUT:
    ///
    ///     out = placedBlack + (placedWhite - placedBlack) * clamp((v - black) * gain, 0, 1) ^ exponent
    ///
    /// The measured black lands on `placedBlack` exactly and the frame's own white on
    /// `placedWhite` exactly, both by construction. A table, so the per-pixel cost is zero.
    public static func anchoredToneLUT(_ step: ToneStep) -> [UInt16] {
        var lut = [UInt16](repeating: 0, count: 65536)
        let b = step.black, gain = step.gain, g = step.exponent
        let lo = step.placedBlack, span = step.placedWhite - step.placedBlack
        for i in 0..<65536 {
            var y = (Double(i) / 65535 - b) * gain
            y = y < 0 ? 0 : (y > 1 ? 1 : y)
            lut[i] = UInt16(jsRound((lo + span * pow(y, g)) * 65535))
        }
        return lut
    }

    /// The print tone LUT: the anchored placement and then the paper contrast stage, both
    /// evaluated in Double for every entry.
    ///
    /// Composed here rather than by running the anchored LUT's OUTPUT through the stage,
    /// which would quantise the flat value to 16 bits and then quantise again. One table,
    /// one rounding, so Print costs exactly what Flat costs per pixel.
    public static func printToneLUT(_ step: ToneStep) -> [UInt16] {
        guard let stage = step.printStage else { return anchoredToneLUT(step) }
        var lut = [UInt16](repeating: 0, count: 65536)
        let b = step.black, gain = step.gain, g = step.exponent
        let lo = step.placedBlack, span = step.placedWhite - step.placedBlack
        for i in 0..<65536 {
            var y = (Double(i) / 65535 - b) * gain
            y = y < 0 ? 0 : (y > 1 ? 1 : y)
            let flat = lo + span * pow(y, g)
            lut[i] = UInt16(jsRound(printTone(flat, stage) * 65535))
        }
        return lut
    }

    /// The tone table for a step. One table, applied to all three channels, because both
    /// operators measure green and apply what they find everywhere.
    public static func toneLUT(_ step: ToneStep) -> [UInt16] {
        switch step.op {
        case .anchored: return anchoredToneLUT(step)
        case .print: return printToneLUT(step)
        }
    }

    /// The three tables a render applies, one per channel: the stock's balance first, then
    /// the tone step, composed into one lookup so the per-pixel cost is a single read and
    /// there is a single rounding.
    ///
    /// Nil when there is nothing to do at all. It stays nil rather than becoming an identity
    /// table: an identity built by round-tripping a transfer function is not guaranteed to
    /// be the identity, and applying one would make the output stop being byte-identical.
    ///
    /// With no balance, which is every stock but one, this returns three references to the
    /// single tone table Swift's copy-on-write hands back, so the bytes and the cost are
    /// those of one tone table.
    public static func renderLUTs(_ analysis: FrameAnalysis) -> [[UInt16]]? {
        switch (analysis.balance, analysis.tone) {
        case (nil, nil):
            return nil
        case (nil, .some(let step)):
            let one = toneLUT(step)
            return [one, one, one]
        case (.some(let balance), nil):
            return balanceLUTs(balance)
        case (.some(let balance), .some(let step)):
            let tone = toneLUT(step)
            return balanceLUTs(balance).map { channel in
                var out = [UInt16](repeating: 0, count: 65536)
                for i in 0..<65536 { out[i] = tone[Int(channel[i])] }
                return out
            }
        }
    }

    /// The 16-bit positive: per-channel remap through the physics ranges, optional tone
    /// LUT, cropped to `box`, flipped horizontally, then rotated clockwise.
    public static func render(_ d: DensityFrame, analysis: FrameAnalysis, box: CropBox? = nil,
                              flip: Bool = true, rotate: Int = 0) -> DecodedFrame {
        let bx = box ?? CropBox(x0: 0, y0: 0, x1: d.width, y1: d.height)
        let cw = bx.width, ch = bx.height
        let outW = (rotate == 90 || rotate == 270) ? ch : cw
        let outH = (rotate == 90 || rotate == 270) ? cw : ch
        var out = [UInt16](repeating: 0, count: cw * ch * 3)
        // Three tables, one per channel: balance then tone, composed. With no balance they
        // are three references to one buffer, so this costs what one table costs.
        let luts: [[UInt16]]? = renderLUTs(analysis)

        @inline(__always) func dstIdx(_ cxIn: Int, _ cy: Int) -> Int {
            var cx = cxIn
            if flip { cx = cw - 1 - cx }
            switch rotate {
            case 90: return cx * ch + (ch - 1 - cy)
            case 180: return (ch - 1 - cy) * cw + (cw - 1 - cx)
            case 270: return (cw - 1 - cx) * ch + cy
            default: return cy * cw + cx
            }
        }

        d.q.withUnsafeBufferPointer { qp in
            out.withUnsafeMutableBufferPointer { op in
                for c in 0..<3 {
                    let lo = analysis.physics[c].lo, hi = analysis.physics[c].hi
                    let scale = 65535.0 / Double(hi - lo)
                    let lut = luts?[c]
                    for y in bx.y0..<bx.y1 {
                        for x in bx.x0..<bx.x1 {
                            let i = y * d.width + x
                            var v = Int(jsRound(Double(Int(qp[i * 3 + c]) - lo) * scale))
                            v = v < 0 ? 0 : (v > 65535 ? 65535 : v)
                            if let lut { v = Int(lut[v]) }
                            op[dstIdx(x - bx.x0, y - bx.y0) * 3 + c] = UInt16(v)
                        }
                    }
                }
            }
        }
        return DecodedFrame(width: outW, height: outH, pixels: out)
    }
}
