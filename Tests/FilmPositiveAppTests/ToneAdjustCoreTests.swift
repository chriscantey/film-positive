import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The Tone row's Adjust in the kernel.
///
/// The central claim is byte identity: for each of the three tones, a frame whose
/// `toneAdjust` is nil and the same frame whose `toneAdjust` holds that tone's own values
/// build the SAME tables, color and mono, with and without a stock's channel balance. That
/// is what makes the sliders a view of the preset rather than a second operator beside it.
/// And nil is the pre-Adjust code path: the step it builds is the step the untouched
/// functions build, compared field for field.
final class ToneAdjustCoreTests: XCTestCase {

    /// A ramp negative, channels spread the way an orange mask spreads them.
    private func negative(width: Int = 160, height: Int = 120) -> DecodedFrame {
        var px = [UInt16](repeating: 0, count: width * height * 3)
        let spans: [(Double, Double)] = [(6_000, 52_000), (9_000, 61_000), (4_000, 38_000)]
        for y in 0..<height {
            for x in 0..<width {
                // Not linear in t, so the median sits away from the middle and the exponent
                // is a measured number rather than exactly 1.
                let t = pow(Double(y * width + x) / Double(width * height - 1), 1.6)
                for c in 0..<3 {
                    let (lo, hi) = spans[c]
                    px[(y * width + x) * 3 + c] = UInt16(lo + (hi - lo) * t)
                }
            }
        }
        return DecodedFrame(width: width, height: height, pixels: px)
    }

    private func input(_ mode: ToneMode, mono: Bool, balance: Bool,
                       adjust: ToneAdjust?) throws -> DevelopInput {
        let gamma = try ProfileLibrary.bundled().resolveFilm("kodak-gold-200").dyeGamma
        var i = DevelopInput(ratios: BaseRatios(rg: 0.52, bg: 0.74),
                             dyeGamma: mono ? .neutral : gamma, mono: mono,
                             autoTone: mode != .none,
                             autoToneOperator: mode == .print ? .print : .anchored,
                             balanceChannels: balance && !mono)
        i.toneAdjust = adjust
        return i
    }

    private func tables(_ input: DevelopInput) -> (FrameAnalysis, [[UInt16]]) {
        let (an, _) = DevelopMath.analyze(negative(), input: input)
        return (an, DevelopTables(analysis: an, mono: input.mono, axisOffsets: input.axisOffsets).tables)
    }

    private static let cases: [(ToneMode, Bool, Bool)] = [
        (.none, false, false), (.none, false, true), (.none, true, false),
        (.flat, false, false), (.flat, false, true), (.flat, true, false),
        (.print, false, false), (.print, false, true), (.print, true, false),
    ]

    // MARK: byte identity

    /// The requirement, at the table level, for all three tones, color and mono.
    func testNilAndEachTonesOwnValuesBuildIdenticalTables() throws {
        for (mode, mono, balance) in Self.cases {
            let label = "\(mode) mono=\(mono) balance=\(balance)"
            let (anNil, plain) = tables(try input(mode, mono: mono, balance: balance, adjust: nil))
            let (anPre, preset) = tables(try input(mode, mono: mono, balance: balance,
                                                   adjust: ToneAdjust.preset(for: mode)))
            XCTAssertEqual(anNil.tone, anPre.tone, "\(label): the step differs")
            XCTAssertEqual(plain.count, preset.count, label)
            for c in 0..<plain.count {
                XCTAssertTrue(plain[c] == preset[c], "\(label): table \(c) differs")
            }
            if balance { XCTAssertNotNil(anNil.balance, "\(label): no balance ran, so this case proves nothing") }
        }
    }

    /// And the values read back from a sidecar, which are held to four decimals, are still
    /// the preset: the grain the file stores loses nothing these numbers carry.
    func testThePresetsSurviveTheSidecarsGrain() {
        for mode in [ToneMode.none, .flat, .print] {
            XCTAssertEqual(ToneAdjust.preset(for: mode).normalised(), ToneAdjust.preset(for: mode),
                           "\(mode) moves when held to the file's grain")
        }
    }

    /// nil is the pre-Adjust code path: the step `analyze` builds with no adjust is the step
    /// the untouched operators build from the same measurements.
    func testNilRunsTheOperatorsExactlyAsBefore() throws {
        for (mode, mono, balance) in Self.cases {
            let label = "\(mode) mono=\(mono) balance=\(balance)"
            let (an, _) = DevelopMath.analyze(negative(), input: try input(mode, mono: mono, balance: balance, adjust: nil))
            let args = (an.coarse[1], an.sampleCount, an.percentile[1], an.physics[1], an.balance)
            switch mode {
            case .none:
                XCTAssertNil(an.tone, label)
            case .flat:
                XCTAssertEqual(an.tone, DevelopMath.anchoredAutoTone(coarseGreen: args.0, sampleCount: args.1,
                                                                    greenPercentile: args.2, greenPhysics: args.3,
                                                                    balance: args.4), label)
            case .print:
                XCTAssertEqual(an.tone, DevelopMath.printAutoTone(coarseGreen: args.0, sampleCount: args.1,
                                                                 greenPercentile: args.2, greenPhysics: args.3,
                                                                 balance: args.4), label)
            }
        }
    }

    /// `PrintStage.shipped` goes through `sized`, and it must build what its plain body
    /// builds. That body, inlined, against the function.
    func testShippedBuildsTheStageItBuiltBefore() {
        func before(flatBlack: Double, flatWhite: Double) -> PrintStage {
            let stage = PrintStage(gamma: DevelopConstants.printGamma, pivot: DevelopConstants.middleGray,
                                   black: DevelopConstants.printBlack, white: DevelopConstants.printWhite,
                                   kneeWidth: DevelopConstants.printKneeWidth,
                                   toeEngaged: false, shoulderEngaged: false,
                                   exposure: DevelopConstants.printExposure)
            let k = stage.kneeWidth
            let blackD = DevelopMath.printStraightDensity(flatBlack, stage)
            let whiteD = DevelopMath.printStraightDensity(flatWhite, stage)
            return PrintStage(gamma: stage.gamma, pivot: stage.pivot, black: stage.black, white: stage.white,
                              kneeWidth: k, toeEngaged: blackD > stage.maxDensity - k,
                              shoulderEngaged: whiteD < stage.minDensity + k, exposure: stage.exposure)
        }
        XCTAssertNil(PrintStage.override, "a sweep override is set, so this compares the wrong stage")
        for (b, w) in [(0.20, 1.0), (0.20, 0.92), (0.0, 1.0), (0.4, 0.6), (0.05, 0.99)] {
            XCTAssertEqual(PrintStage.shipped(flatBlack: b, flatWhite: w), before(flatBlack: b, flatWhite: w), "\(b) \(w)")
        }
    }

    /// None at its own values is NO step, never an identity table, the rule `renderLUTs`
    /// states. (An anchored step at those values would happen to be an identity too, which
    /// is asserted beside it, but the rule does not lean on that.)
    func testNoneAtItsOwnValuesIsNoStep() {
        XCTAssertNil(DevelopMath.adjustedTone(measured: nil, adjust: ToneAdjust.preset(for: .none)))
        let identity = ToneStep(op: .anchored, black: 0, placedBlack: 0, placedWhite: 1, gain: 1,
                                gainAtCap: false, median: DevelopConstants.middleGray, exponent: 1,
                                exponentAtBound: false)
        let lut = DevelopMath.toneLUT(identity)
        XCTAssertEqual(lut, (0..<65536).map { UInt16($0) })
    }

    // MARK: the sliders move the picture

    /// Mean output of the green table over its whole domain, weighted evenly.
    private func mean(_ t: [[UInt16]]) -> Double {
        let g = t.count == 1 ? t[0] : t[1]
        return g.reduce(0.0) { $0 + Double($1) } / Double(g.count)
    }

    /// Every slider changes the tables away from every preset, None included, color and
    /// mono. A builder that ignored a value would pass the identity test above.
    func testEachValueMovesTheTablesUnderEveryTone() throws {
        for mode in [ToneMode.none, .flat, .print] {
            for mono in [false, true] {
                let p = ToneAdjust.preset(for: mode)
                let (_, base) = tables(try input(mode, mono: mono, balance: false, adjust: p))
                var moves: [(String, ToneAdjust)] = []
                var a = p; a.exposure -= 0.06; moves.append(("exposure", a))
                a = p; a.contrast *= 1.2; moves.append(("contrast", a))
                a = p; a.black = mode == .none ? 0.05 : p.black + 0.05; moves.append(("black", a))
                a = p; a.white = p.white - 0.05; moves.append(("white", a))
                for (name, adjusted) in moves {
                    let (_, t) = tables(try input(mode, mono: mono, balance: false, adjust: adjusted))
                    XCTAssertFalse(t == base, "\(mode) mono=\(mono): \(name) changed nothing")
                }
            }
        }
    }

    /// The directions: Lighter (negative exposure) raises the picture, a lifted black and a
    /// dimmer white do what they say. Measured on the green table's mean.
    func testTheDirectionsAreTheLabels() throws {
        for mode in [ToneMode.flat, .print] {
            let p = ToneAdjust.preset(for: mode)
            let (_, base) = tables(try input(mode, mono: false, balance: false, adjust: p))
            var lighter = p; lighter.exposure -= 0.15
            let (_, l) = tables(try input(mode, mono: false, balance: false, adjust: lighter))
            XCTAssertGreaterThan(mean(l), mean(base), "\(mode): Lighter did not lighten")
            var lifted = p; lifted.black += 0.10
            let (_, b) = tables(try input(mode, mono: false, balance: false, adjust: lifted))
            XCTAssertGreaterThan(mean(b), mean(base), "\(mode): Lifted did not lift")
            var dimmer = p; dimmer.white -= 0.10
            let (_, w) = tables(try input(mode, mono: false, balance: false, adjust: dimmer))
            XCTAssertLessThan(mean(w), mean(base), "\(mode): Dimmer did not dim")
        }
    }

    // MARK: continuity at the preset

    /// The largest move ONE fine arrow step (shift, a tenth of the plain step) off a preset
    /// may make to any table entry, in 16-bit codes. Each is the step's own move in output
    /// value, times the steepest slope the stage after it has, times 65535, rounded up, plus
    /// one code for the table's own rounding:
    ///
    /// - Exposure, 0.01 stop = 0.003 D. The output is multiplied by 10^0.003, so it moves by
    ///   at most v * (10^0.003 - 1) <= 0.00693 for v <= 1, under every tone (Bold's knees
    ///   are slope <= 1 in density and only flatten): 455 + 1 = 456.
    /// - Contrast, 0.005 units = gamma * (2.3^0.005 - 1). d(out)/d(gamma) is
    ///   v * ln(v / pivot), whose size peaks on (0, 1] at v = 1, ln(1 / 0.461) = 0.774.
    ///   None and Flat (gamma 1): 0.774 * 0.00417 = 0.00323, 212 + 1 = 213. Bold (gamma 2.3):
    ///   0.774 * 0.00960 = 0.00743, 487 + 1 = 488.
    /// - Black and white, 0.1 point = 0.001 of placed value. None and Flat pass it straight
    ///   through (slope 1): 66 + 1 = 67. Bold's paper stage is steepest at its white end,
    ///   2.3 * (1 / 0.461)^1.3 * 10^-0.30 = 3.15, and the knees only flatten:
    ///   0.001 * 3.15 * 65535 = 207, + 1 = 208.
    ///
    /// The failure these guard against moves Flat's white from 0.92 to 0.876 on the first
    /// notch of exposure, about 2900 codes, so every bound is far below a knee engaging.
    private static func continuityBound(_ mode: ToneMode, _ slider: ToneSlider) -> Int {
        switch (slider, mode) {
        case (.exposure, _): return 456
        case (.contrast, .print): return 488
        case (.contrast, _): return 213
        case (.black, .print), (.white, .print): return 208
        case (.black, _), (.white, _): return 67
        }
    }

    /// One fine step off each preset, both ways where the span allows, for every tone and
    /// every slider, color and mono: no table entry moves by more than the bound above.
    func testOneFineStepOffEachPresetIsContinuous() throws {
        var checked = 0
        for mode in [ToneMode.none, .flat, .print] {
            for mono in [false, true] {
                let p = ToneAdjust.preset(for: mode)
                let (_, base) = tables(try input(mode, mono: mono, balance: false, adjust: p))
                for slider in ToneSlider.allCases {
                    let fine = slider.keyStep * CentreOriginTrack.fineMultiplier
                    for direction in [-1.0, 1.0] {
                        let target = slider.value(in: p) + direction * fine
                        guard slider.range.contains(target) else { continue }
                        let adjusted = slider.setting(p, to: target)
                        XCTAssertNotEqual(adjusted, p, "\(mode) \(slider): the step changed nothing")
                        let (_, t) = tables(try input(mode, mono: mono, balance: false, adjust: adjusted))
                        var worst = 0
                        for c in 0..<t.count {
                            for i in 0..<t[c].count { worst = max(worst, abs(Int(t[c][i]) - Int(base[c][i]))) }
                        }
                        let bound = Self.continuityBound(mode, slider)
                        print("continuity \(mode) mono=\(mono) \(slider) \(direction > 0 ? "+" : "-"): worst \(worst) of \(bound)")
                        XCTAssertLessThanOrEqual(worst, bound,
                                                 "\(mode) mono=\(mono) \(slider) \(direction > 0 ? "+" : "-"): "
                                                 + "one fine step moved an entry \(worst) codes, bound \(bound)")
                        checked += 1
                    }
                }
            }
        }
        // 3 tones x 2 x (8 directions less the 3 that leave a span: None's black down,
        // None's and Bold's white up) = 3 x 2 x 8 - 2 x 3 = 42.
        XCTAssertEqual(checked, 42, "the sweep skipped cases")
    }

    /// Under None, one plain Lighter step is the straight line: every entry is the identity
    /// times 10^0.03, clamped to white, so white 1.000 stays white.
    func testOneLighterStepUnderNoneIsTheStraightLine() throws {
        let p = ToneAdjust.preset(for: .none)
        let lighter = ToneSlider.exposure.setting(p, to: ToneSlider.exposure.keyStep)
        let step = try XCTUnwrap(DevelopMath.adjustedTone(measured: nil, adjust: lighter))
        let lut = DevelopMath.toneLUT(step)
        let gain = pow(10, ToneSlider.exposure.keyStep * ToneAdjust.densityPerStop)
        XCTAssertEqual(Int(lut[65535]), 65535, "white 1.000 left white under None")
        XCTAssertLessThanOrEqual(abs(Int(lut[65535]) - 65535), Self.continuityBound(.none, .exposure))
        var worst = 0
        for i in 0..<65536 {
            let line = min(65535.0, (Double(i) * gain).rounded())
            worst = max(worst, abs(Int(lut[i]) - Int(line)))
        }
        XCTAssertLessThanOrEqual(worst, 1, "None's table is not the straight line: \(worst) codes off")
        // And the knees are Bold's alone.
        XCTAssertEqual(step.printStage?.kneeWidth, 0)
    }

    // MARK: the presets are the constants, once

    func testThePresetsAreTheDevelopConstants() {
        XCTAssertEqual(ToneAdjust.preset(for: .none), ToneAdjust(exposure: 0, contrast: 1, black: 0, white: 1))
        XCTAssertEqual(ToneAdjust.preset(for: .flat),
                       ToneAdjust(exposure: 0, contrast: 1,
                                  black: DevelopConstants.placedBlack, white: DevelopConstants.placedWhite))
        XCTAssertEqual(ToneAdjust.preset(for: .print),
                       ToneAdjust(exposure: DevelopConstants.printExposure, contrast: DevelopConstants.printGamma,
                                  black: DevelopConstants.placedBlack, white: DevelopConstants.printPlacedWhite))
        // Today's values, so a constant that moves is a decision someone sees here.
        XCTAssertEqual(ToneAdjust.preset(for: .flat), ToneAdjust(exposure: 0, contrast: 1, black: 0.20, white: 0.92))
        XCTAssertEqual(ToneAdjust.preset(for: .print), ToneAdjust(exposure: 0.30, contrast: 2.3, black: 0.20, white: 1.0))
    }

    /// The tuples are written once, from `DevelopConstants`, and the app never names those
    /// constants itself: every view of a preset goes through `ToneAdjust.preset(for:)`.
    func testThePresetTuplesAppearOnceAndComeFromTheConstants() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        // CANARY: a scan that reads nothing reports what a clean tree reports.
        XCTAssertGreaterThan(files.count, 50, "the scan found \(files.count) source files, so it is not reading the tree")

        var definitions = 0
        var body = ""
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            let marker = "public static func preset(for mode: ToneMode) -> ToneAdjust {"
            let parts = text.components(separatedBy: marker)
            definitions += parts.count - 1
            // The function's own closing brace, at its four space indent. The switch inside
            // it closes at eight, which this does not match.
            if parts.count > 1, let end = parts[1].range(of: "\n    }\n") {
                body = String(parts[1][..<end.lowerBound])
            }
            // The app reads presets through the function and never names the constants.
            if url.path.contains("/Sources/FilmPositive/") {
                for name in ["placedBlack", "placedWhite", "printPlacedWhite", "printGamma", "printExposure"] {
                    XCTAssertFalse(text.contains("DevelopConstants.\(name)"),
                                   "\(url.lastPathComponent) names DevelopConstants.\(name): read ToneAdjust.preset(for:)")
                }
            }
        }
        XCTAssertEqual(definitions, 1, "the preset table is defined \(definitions) times")
        for name in ["placedBlack", "placedWhite", "printPlacedWhite", "printGamma", "printExposure"] {
            XCTAssertTrue(body.contains("DevelopConstants.\(name)"), "the preset table does not read \(name)")
        }
        let literal = try NSRegularExpression(pattern: "[0-9]+\\.[0-9]+")
        XCTAssertEqual(literal.numberOfMatches(in: body, range: NSRange(body.startIndex..., in: body)), 0,
                       "the preset table carries a decimal literal, a second copy of a constant:\n\(body)")
    }

    /// The spans keep the white at least 20 points above the black on their own.
    func testTheSpansKeepWhiteTwentyPointsAboveBlack() {
        XCTAssertGreaterThanOrEqual(ToneAdjust.whiteRange.lowerBound - ToneAdjust.blackRange.upperBound,
                                    ToneAdjust.minimumSpan - 1e-12)
        let squeezed = ToneAdjust(exposure: 0, contrast: 1, black: 0.9, white: 0.1).normalised()
        XCTAssertEqual(squeezed?.black, 0.40)
        XCTAssertEqual(squeezed?.white, 0.60)
        XCTAssertNil(ToneAdjust(exposure: .nan, contrast: 1, black: 0, white: 1).normalised())
        XCTAssertNil(ToneAdjust(exposure: 0, contrast: 0, black: 0, white: 1).normalised())
    }
}
