import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The per-channel channel balance: a stock-declared activity that runs BEFORE the tone step,
/// measured PER FRAME.
///
/// Three claims each have their own test below. It is the exact identity when a channel
/// already fills the range. What ships measures the frame in front of it, the way every other
/// automatic step here does. And a stock that declares no activity renders exactly the bytes
/// it would with no balance at all.
final class ChannelBalanceTests: XCTestCase {

    /// A range that makes the physics remap the identity, so a bin index and the value the
    /// renderer produces for it are the same number and every endpoint below is arithmetic
    /// rather than whatever a real frame happened to give.
    private let straight = ChannelRange(lo: 0, hi: 65535)

    private func channel(lo: Double, hi: Double) -> BalanceChannel {
        BalanceChannel(lo: lo, hi: hi,
                       linearLo: DevelopMath.srgbToLinear(lo), linearHi: DevelopMath.srgbToLinear(hi),
                       degenerate: (hi - lo) < DevelopConstants.balanceMinSpan)
    }

    /// `count` samples, one per bin, filling `bins`.
    private func flat(_ bins: ClosedRange<Int>) -> [UInt32] {
        var h = [UInt32](repeating: 0, count: 65536)
        for b in bins { h[b] = 1 }
        return h
    }

    // MARK: the transfer function

    /// The encode has to be the EXACT inverse of the decode. If one is the piecewise IEC form
    /// and the other a 2.2 power law, every test below still passes on shape and every render
    /// is wrong by a little, everywhere, forever.
    func testTheTransferFunctionsAreInverses() {
        for i in stride(from: 0, through: 65535, by: 97) {
            let u = Double(i) / 65535
            XCTAssertEqual(DevelopMath.srgbFromLinear(DevelopMath.srgbToLinear(u)), u, accuracy: 1e-12,
                           "the transfer pair is not an inverse at \(u)")
        }
        XCTAssertEqual(DevelopMath.srgbToLinear(0), 0, accuracy: 1e-15)
        XCTAssertEqual(DevelopMath.srgbToLinear(1), 1, accuracy: 1e-12)
        // Continuous across the piecewise break, which is where a typo in a constant shows.
        XCTAssertEqual(DevelopMath.srgbToLinear(0.04045 - 1e-9),
                       DevelopMath.srgbToLinear(0.04045 + 1e-9), accuracy: 1e-8)
    }

    // MARK: the table

    /// The sharpest test here. A channel already occupying the whole range must come out
    /// untouched, which can only happen if the decode, the stretch, the encode and the
    /// rounding all agree. Catches a transfer mismatch, a rounding drift and an off-by-one
    /// clamp in one assertion.
    func testAFullRangeChannelProducesTheExactIdentity() {
        let lut = DevelopMath.balanceChannelLUT(channel(lo: 0, hi: 1))
        for i in 0..<65536 {
            XCTAssertEqual(Int(lut[i]), i, "the identity stretch moved entry \(i)")
        }
    }

    func testANarrowChannelIsOpenedToTheFullRange() {
        let lo = 0.40, hi = 0.60
        let lut = DevelopMath.balanceChannelLUT(channel(lo: lo, hi: hi))
        XCTAssertEqual(Int(lut[Int((lo * 65535).rounded())]), 0, "the measured low is not sent to black")
        XCTAssertEqual(Int(lut[Int((hi * 65535).rounded())]), 65535, "the measured high is not sent to white")
        XCTAssertEqual(Int(lut[0]), 0)
        XCTAssertEqual(Int(lut[65535]), 65535)
        for i in 1..<65536 {
            XCTAssertGreaterThanOrEqual(lut[i], lut[i - 1], "the table is not non-decreasing at \(i)")
        }
    }

    /// The stretch happens in linear light, not on the encoded value, and this is the one
    /// assertion that can tell the two apart. Stretching 0.4...0.6 encoded would send the
    /// encoded midpoint to exactly half scale; in linear light it lands elsewhere.
    func testTheStretchHappensInLinearLightAndNotOnTheEncodedValue() {
        let lut = DevelopMath.balanceChannelLUT(channel(lo: 0.40, hi: 0.60))
        let mid = Double(lut[Int((0.50 * 65535).rounded())]) / 65535
        let lo = DevelopMath.srgbToLinear(0.4), hi = DevelopMath.srgbToLinear(0.6)
        let linearAnswer = DevelopMath.srgbFromLinear((DevelopMath.srgbToLinear(0.5) - lo) / (hi - lo))
        XCTAssertEqual(mid, linearAnswer, accuracy: 1e-4)
        XCTAssertNotEqual(mid, 0.5, accuracy: 1e-3,
                          "this render is indistinguishable from stretching the encoded value")
    }

    func testAFlatChannelIsLeftAloneRatherThanDividedByNothing() {
        let ch = channel(lo: 0.5, hi: 0.5)
        XCTAssertTrue(ch.degenerate)
        let lut = DevelopMath.balanceChannelLUT(ch)
        for i in stride(from: 0, through: 65535, by: 53) {
            XCTAssertEqual(Int(lut[i]), i, "a degenerate channel was not left as the identity")
        }
    }

    // MARK: measuring

    func testPercentileBinIsTheFirstBinAtOrAboveTheShare() {
        let h = flat(10_000...50_000)          // 40001 samples, one per bin
        XCTAssertEqual(DevelopMath.percentileBin(h, sampleCount: 40_001, 0.001), 10_040)
        XCTAssertEqual(DevelopMath.percentileBin(h, sampleCount: 40_001, 0.999), 49_960)
        XCTAssertEqual(DevelopMath.percentileBin(h, sampleCount: 0, 0.5), 0, "no samples, no crash")
    }

    /// The density histogram has to be moved onto the value axis before two frames can be
    /// added together, because each frame has its own physics range and adding them before
    /// the remap is adding two different rulers.
    func testTheValueHistogramMovesBinsOntoTheAxisTheRendererProduces() {
        // A run that sits ABOVE the range's ceiling: the remap's gain is 65535/32767, so
        // bin 40000 maps past full scale and the whole run has to land on the rail.
        let above = flat(40_000...40_099)                   // 100 samples
        let half = ChannelRange(lo: 0, hi: 32_767)
        let v = DevelopMath.valueHistogram(above, half)
        XCTAssertEqual(Int(v.reduce(0) { $0 + UInt64($1) }), 100, "samples were lost or invented")
        XCTAssertEqual(Int(v[65_535]), 100, "the ceiling did not clamp the whole run")
        // And a run BELOW it is spread out rather than clamped, which is the other half of
        // the same claim: the remap expands, so 100 bins become more than 100.
        let below = flat(1_000...1_099)
        let spread = DevelopMath.valueHistogram(below, half)
        XCTAssertEqual(Int(spread.reduce(0) { $0 + UInt64($1) }), 100)
        XCTAssertEqual(Int(spread[65_535]), 0, "a run well under the ceiling was railed")
        let identity = DevelopMath.valueHistogram(below, straight)
        XCTAssertEqual(Int(identity[1_000]), 1)
        XCTAssertEqual(Int(identity[1_099]), 1)
    }

    /// Each channel is measured on its own. This is the whole of what the activity is for,
    /// stated as one assertion.
    func testEachChannelIsMeasuredOnItsOwn() throws {
        let hist = [flat(10_000...50_000), flat(20_000...60_000), flat(5_000...45_000)]
        let b = DevelopMath.frameBalance(hist: hist, sampleCount: 40_001,
                                         physics: [straight, straight, straight])
        XCTAssertEqual(b.source, .frame)
        XCTAssertEqual(b.channels[0].lo, 10_040.0 / 65535, accuracy: 1e-9)
        XCTAssertEqual(b.channels[1].lo, 20_040.0 / 65535, accuracy: 1e-9)
        XCTAssertEqual(b.channels[2].lo, 5_040.0 / 65535, accuracy: 1e-9)
        XCTAssertEqual(b.channels[0].hi, 49_960.0 / 65535, accuracy: 1e-9)
        XCTAssertEqual(Set(b.channels.map(\.lo)).count, 3, "the three channels read the same low")
        for c in b.channels { XCTAssertFalse(c.degenerate) }
    }

    /// The one way this does nothing while looking healthy: the remap already drove that end
    /// to the rail, the percentile reads exactly 0.000 or 1.000, and the span looks maximally
    /// wide. It has to be reported, not inferred.
    func testAnEndAlreadyAtTheRailIsReported() throws {
        let hist = [flat(30_000...65_535), flat(30_000...65_535), flat(30_000...65_535)]
        let narrow = ChannelRange(lo: 0, hi: 40_000)
        let b = DevelopMath.frameBalance(hist: hist, sampleCount: 35_536,
                                         physics: [narrow, narrow, narrow])
        XCTAssertTrue(b.channels[0].hiAlreadyClipped, "the ceiling was at the rail and nothing said so")
        XCTAssertGreaterThan(b.channels[0].hiClippedShare, 0.5)
        XCTAssertFalse(b.channels[0].degenerate, "a pinned end is not a degenerate channel")
        XCTAssertTrue(b.summary.contains("rail"), "the summary hides that an end did nothing: \(b.summary)")
        XCTAssertTrue(b.summary.contains("this frame"), b.summary)
    }

    // MARK: the tone step measures THROUGH the balance

    /// Flat places the roll's black on `placedBlack`. The balance runs first, so a black
    /// measured on unbalanced data and applied to balanced data would land somewhere else,
    /// and Flat would stop doing the one thing it exists to do.
    func testFlatMeasuresThroughTheBalanceRatherThanAroundIt() throws {
        let coarse = [UInt32](repeating: 40, count: 1024)      // a flat median at the middle
        let pct = ChannelRange(lo: 20_000, hi: 60_000)
        let phys = ChannelRange(lo: 10_000, hi: 60_000)
        let ch = channel(lo: 0.10, hi: 0.90)
        let balance = ChannelBalance(channels: [ch, ch, ch], source: .frame)

        let plain = DevelopMath.anchoredAutoTone(coarseGreen: coarse, sampleCount: 40 * 1024,
                                                 greenPercentile: pct, greenPhysics: phys)
        let through = DevelopMath.anchoredAutoTone(coarseGreen: coarse, sampleCount: 40 * 1024,
                                                   greenPercentile: pct, greenPhysics: phys,
                                                   balance: balance)
        XCTAssertNotEqual(plain.black, through.black, accuracy: 1e-6,
                          "the balance was ignored, so Flat is measuring the wrong frame")
        XCTAssertEqual(through.black, DevelopMath.balanced(plain.black, ch), accuracy: 1e-9,
                       "the black was not pushed through the balance exactly")
        // And it measures through the STRENGTH, not just the endpoints: a weaker balance is
        // a different curve and the tone has to see that one.
        let none = DevelopMath.anchoredAutoTone(coarseGreen: coarse, sampleCount: 40 * 1024,
                                                greenPercentile: pct, greenPhysics: phys,
                                                balance: balance.with(strength: 0))
        XCTAssertEqual(none.black, plain.black, accuracy: 1e-9,
                       "strength 0 is not the identity for the tone measurement")
        // Both still place that black on the same constant, which is Flat's whole promise.
        XCTAssertEqual(through.placedBlack, DevelopConstants.placedBlack)
        XCTAssertEqual(plain.placedBlack, through.placedBlack)
    }

    /// Strength 0 must be the EXACT identity table, checked against arithmetic rather than
    /// shape.
    func testStrengthZeroIsTheIdentity() {
        let ch = channel(lo: 0.30, hi: 0.90)
        let off = DevelopMath.balanceChannelLUT(ch, strength: 0)
        for i in stride(from: 0, through: 65535, by: 37) {
            XCTAssertEqual(Int(off[i]), i, "strength 0 moved entry \(i)")
        }
        let stretched = DevelopMath.balanceChannelLUT(ch, strength: 1)
        XCTAssertEqual(Int(stretched[65535]), 65535, "the stretch did not reach white")
    }

    // MARK: invariance, which is the bar this build was given

    /// A stock that declares no activity gets no balance, one tone table, three references to
    /// it. And with nothing at all to do the answer is NIL
    /// rather than an identity table, because an identity built by round-tripping a transfer
    /// function is not guaranteed to be the identity.
    func testAStockWithNoActivityRendersThroughTheTableItAlwaysDid() {
        let bare = FrameAnalysis(anchor: 1000, base: [1, 1, 1],
                                 percentile: [straight, straight, straight],
                                 physics: [straight, straight, straight],
                                 coarse: [[UInt32]](repeating: [UInt32](repeating: 1, count: 1024), count: 3),
                                 sampleCount: 1024, tone: nil, balance: nil)
        XCTAssertNil(DevelopMath.renderLUTs(bare), "nothing to do must stay nil, never an identity table")

        for op in [AutoToneOperator.anchored, .print] {
            let step = ToneStep(op: op, black: 0.12, placedBlack: 0.20, placedWhite: 0.92,
                                gain: 1.1, gainAtCap: false, median: 0.42, exponent: 0.9,
                                exponentAtBound: false,
                                printStage: op == .print
                                    ? PrintStage.shipped(flatBlack: 0.20, flatWhite: 1.0) : nil)
            let toned = FrameAnalysis(anchor: 1000, base: [1, 1, 1],
                                      percentile: [straight, straight, straight],
                                      physics: [straight, straight, straight],
                                      coarse: bare.coarse, sampleCount: 1024, tone: step, balance: nil)
            let luts = try? XCTUnwrap(DevelopMath.renderLUTs(toned))
            let one = DevelopMath.toneLUT(step)
            XCTAssertEqual(luts?.count, 3)
            for c in 0..<3 { XCTAssertEqual(luts?[c], one, "\(op) channel \(c) is not the shipped table") }
        }
    }

    /// The two render paths have to agree on a balanced frame too, because a table computed
    /// twice is a table that can differ once.
    func testTheTablePathMatchesTheReferenceOnABalancedFrame() throws {
        let f = negative()
        let profiles = try ProfileLibrary.bundled()
        let input = DevelopInput(ratios: BaseRatios(rg: 0.52, bg: 0.74),
                                 dyeGamma: profiles.resolveFilm("kodak-gold-200").dyeGamma,
                                 mono: false, autoTone: true, autoToneOperator: .anchored,
                                 balanceChannels: true)
        let (analysis, density) = DevelopMath.analyze(f, input: input)
        XCTAssertNotNil(analysis.balance, "the activity was declared and no balance was measured")
        XCTAssertEqual(analysis.balance?.source, .frame)
        XCTAssertEqual(DevelopMath.render(density, analysis: analysis).pixels,
                       DevelopTables(analysis: analysis, mono: false).apply(f).pixels,
                       "the accelerated path and the CPU reference disagree under a balance")
    }

    /// And it actually does something, by different amounts per channel. A test that only
    /// proved the two paths agree would pass on an identity.
    func testTheBalanceMovesTheChannelsByDifferentAmounts() throws {
        let f = negative()
        let profiles = try ProfileLibrary.bundled()
        let gamma = profiles.resolveFilm("kodak-gold-200").dyeGamma
        func mean(balanced: Bool) -> [Double] {
            let input = DevelopInput(ratios: BaseRatios(rg: 0.52, bg: 0.74), dyeGamma: gamma,
                                     mono: false, autoTone: false, balanceChannels: balanced)
            let (a, d) = DevelopMath.analyze(f, input: input)
            let out = DevelopMath.render(d, analysis: a)
            var sums = [0.0, 0.0, 0.0]
            for i in stride(from: 0, to: out.pixels.count, by: 3) {
                for c in 0..<3 { sums[c] += Double(out.pixels[i + c]) }
            }
            return sums.map { $0 / Double(out.pixels.count / 3) }
        }
        let plain = mean(balanced: false), balanced = mean(balanced: true)
        let shift = (0..<3).map { balanced[$0] - plain[$0] }
        XCTAssertGreaterThan(shift.map(abs).max() ?? 0, 100, "the balance did nothing to the picture")
        XCTAssertNotEqual(shift[0], shift[1], accuracy: 1,
                          "red and green moved by the same amount, so this is not per channel")
    }

    // MARK: what ships

    /// The balance ships PER FRAME at full strength. Asserted through the shipped
    /// settings-to-input path rather than by constructing a `DevelopInput` by hand, because a
    /// hand-built input would prove nothing about what the app does.
    func testTheShippedPathMeasuresEachFrameAtFullStrength() throws {
        let svc = CPURenderService(profiles: try ProfileLibrary.bundled())
        let settings = DevelopSettings(stock: "harman-switch-azure",
                                       tone: .none, autoBalance: true,
                                       base: BaseSettings(mode: .anchor))
        let input = svc.developInput(for: settings)
        XCTAssertTrue(input.balanceChannels, "the stock's activity did not reach the kernel")
        let (analysis, _) = DevelopMath.analyze(negative(), input: input)
        let balance = try XCTUnwrap(analysis.balance, "no balance was measured")
        XCTAssertEqual(balance.source, .frame, "the balance must measure the frame in front of it")
        XCTAssertEqual(balance.strength, 1, accuracy: 1e-12, "it ships full strength, not a blend")
    }

    // MARK: the strength comes from the profile file

    /// The parameterized shape must be a NO-OP at its defaults, or every existing Azure frame
    /// silently re-renders. Asserted as PIXELS from the two file shapes, not as equal
    /// settings, because equal settings is the thing that would still be true if the strength
    /// never reached the operator.
    func testTheObjectFormAtStrengthOneRendersExactlyTheBareForm() throws {
        let bare = try pixels(activities: #"["balanceChannels"]"#)
        let stated = try pixels(activities: #"[{"name":"balanceChannels","strength":1.0,"scope":"frame"}]"#)
        XCTAssertEqual(bare, stated, "stating the defaults in the file changed the picture")
        // And the operator runs in both, so this is not two identity renders agreeing with
        // each other.
        let off = try pixels(activities: nil)
        XCTAssertNotEqual(bare, off, "the balance did nothing, so the comparison proved nothing")
    }

    /// A different strength in the file is a different picture, and strength 0 is the exact
    /// identity. Together these are what makes the knob real rather than decorative.
    func testADifferentStrengthInTheFileIsADifferentPicture() throws {
        let full = try pixels(activities: #"[{"name":"balanceChannels","strength":1.0}]"#)
        let half = try pixels(activities: #"[{"name":"balanceChannels","strength":0.5}]"#)
        let zero = try pixels(activities: #"[{"name":"balanceChannels","strength":0.0}]"#)
        let off = try pixels(activities: nil)
        XCTAssertNotEqual(full, half, "halving the strength in the file changed nothing")
        XCTAssertEqual(zero, off, "strength 0 is not the exact identity")
    }

    /// Renders the ramp through a hand-written profile, by the shipped settings-to-input
    /// path, so what is under test is what a FILE can say.
    private func pixels(activities: String?) throws -> [UInt16] {
        let fm = FileManager.default
        let dst = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-strength-\(UUID().uuidString)")
        try fm.copyItem(at: try ProfileLibrary.bundled().root, to: dst)
        addTeardownBlock { try? fm.removeItem(at: dst) }
        let body = activities.map { #"{"id":"x","name":"X","activities":\#($0)}"# }
            ?? #"{"id":"x","name":"X"}"#
        try Data(body.utf8).write(to: dst.appendingPathComponent("films/x.json"))
        let svc = CPURenderService(profiles: try ProfileLibrary(root: dst))
        let d = DevelopSettings(stock: "x",
                                tone: .none, autoBalance: true, base: BaseSettings(mode: .anchor))
        let (analysis, density) = DevelopMath.analyze(negative(), input: svc.developInput(for: d))
        return DevelopMath.render(density, analysis: analysis).pixels
    }

    // MARK: a synthetic negative with three differently placed channels

    /// Each channel ramps over its own span, so the three histograms differ and a
    /// per-channel operator has something to find. Not a picture of anything.
    private func negative(width: Int = 160, height: Int = 120) -> DecodedFrame {
        var px = [UInt16](repeating: 0, count: width * height * 3)
        let spans: [(Double, Double)] = [(6_000, 52_000), (9_000, 61_000), (4_000, 38_000)]
        for y in 0..<height {
            for x in 0..<width {
                let t = Double(y * width + x) / Double(width * height - 1)
                for c in 0..<3 {
                    let (lo, hi) = spans[c]
                    px[(y * width + x) * 3 + c] = UInt16(lo + (hi - lo) * t)
                }
            }
        }
        return DecodedFrame(width: width, height: height, pixels: px)
    }
}
