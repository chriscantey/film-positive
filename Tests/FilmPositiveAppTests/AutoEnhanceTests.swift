import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The Auto Enhance wand: target lines read from each frame, solved onto our sliders and held
/// only at the clip budget, the cast neutralizer, and the no-color skip.
final class AutoEnhanceTests: XCTestCase {
    typealias Proposal = AutoEnhance.Proposal

    /// A smooth frame: luma ramps left to right across `lo...hi`, tinted by `tint` (added to
    /// R and subtracted from B, so positive is warm).
    static func ramp(lo: Double, hi: Double, tint: Double = 0.06, w: Int = 160, h: Int = 100) -> DecodedFrame {
        var px = [UInt16](); px.reserveCapacity(w * h * 3)
        for _ in 0..<h { for x in 0..<w {
            let v = lo + (hi - lo) * Double(x) / Double(w - 1)
            func c(_ d: Double) -> UInt16 { UInt16(max(0, min(1, v + d)) * 65535) }
            px += [c(tint), c(0), c(-tint)]
        } }
        return DecodedFrame(width: w, height: h, pixels: px)
    }

    static func solid(_ r: Double, _ g: Double, _ b: Double, w: Int = 120, h: Int = 80) -> DecodedFrame {
        let p = [UInt16(r * 65535), UInt16(g * 65535), UInt16(b * 65535)]
        return DecodedFrame(width: w, height: h, pixels: (0..<(w * h)).flatMap { _ in p })
    }

    // MARK: targets, from the frame

    func testTheTargetsReadTheFrame() {
        let s = { (p1: Double) in AutoEnhance.FrameStats(p1: p1, p50: 0.5, p99: 0.9, meanLuma: 0.5, meanSat: 0.2, clipLow: 0, clipHigh: 0) }
        XCTAssertLessThan(AutoEnhance.targets(s(0.3)).dP1, AutoEnhance.targets(s(0.1)).dP1,
                          "a lighter darkest 1% is pulled down harder")
        let dim = AutoEnhance.FrameStats(p1: 0.05, p50: 0.25, p99: 0.6, meanLuma: 0.27, meanSat: 0.2, clipLow: 0, clipHigh: 0)
        let bright = AutoEnhance.FrameStats(p1: 0.3, p50: 0.75, p99: 0.97, meanLuma: 0.72, meanSat: 0.2, clipLow: 0, clipHigh: 0)
        XCTAssertGreaterThan(AutoEnhance.targets(dim).dMeanLuma, AutoEnhance.targets(bright).dMeanLuma, "dim frames are lifted more")
        XCTAssertGreaterThan(AutoEnhance.targets(dim).dP99, 0, "a frame that never reaches white is pushed up at the top")
    }

    /// A frame with no color gets no color lift.
    func testAFrameWithNoColourGetsNoColourLift() throws {
        let grey = Self.ramp(lo: 0.1, hi: 0.9, tint: 0)
        XCTAssertFalse(AutoEnhance.stats(grey).hasColour)
        XCTAssertEqual(AutoEnhance.targets(AutoEnhance.stats(grey)).dSat, 0)
        let p = try AutoEnhance.propose(for: grey, current: .identity)
        XCTAssertEqual(p.saturation, 0)
        XCTAssertEqual(p.vibrance, 0)
    }

    // MARK: the solve lands on the targets

    func testTheSolveLandsTheFrameOnItsTargets() throws {
        let f = Self.ramp(lo: 0.22, hi: 0.78)
        let s0 = AutoEnhance.stats(f)
        let t = AutoEnhance.targets(s0)
        let p = try AutoEnhance.solve(f, base: .identity, targets: t, render: { try CoreImageEnhance().apply($0, settings: $1) })
        let s1 = AutoEnhance.stats(try CoreImageEnhance().apply(f, settings: p.applied(to: .identity)))
        XCTAssertEqual(s1.p1 - s0.p1, t.dP1, accuracy: 0.01, "p1")
        XCTAssertEqual(s1.meanLuma - s0.meanLuma, t.dMeanLuma, accuracy: 0.01, "mean luma")
        XCTAssertEqual(s1.meanSat - s0.meanSat, t.dSat, accuracy: 0.02, "saturation")
    }

    // MARK: the clip guard

    /// The dark end answers only through Black Point; everything else survives a dark breach.
    func testADarkBreachScalesBlackPointAlone() {
        let p = Proposal(blackPoint: 2.0, brightness: 0.4, highlights: -0.2, saturation: 0.2, vibrance: 0.18)
        func render(_ f: DecodedFrame, _ s: EnhanceSettings) -> DecodedFrame {
            // 2% of pixels crushed per unit of Black Point.
            let crushed = Int((s.blackPoint * 0.02 * Double(f.width * f.height)).rounded())
            var px = [UInt16](repeating: 32767, count: f.width * f.height * 3)
            for i in 0..<crushed { px[i * 3] = 0; px[i * 3 + 1] = 0; px[i * 3 + 2] = 0 }
            return DecodedFrame(width: f.width, height: f.height, pixels: px)
        }
        let g = AutoEnhance.guarded(p, on: Self.solid(0.5, 0.5, 0.5, w: 100, h: 100), base: .identity, render: render)
        XCTAssertEqual(g.blackPoint, 1.75, accuracy: 0.02, "4 points at full, 3.5 points at seven eighths, the most that holds")
        XCTAssertEqual(g.brightness, 0.4)
        XCTAssertEqual(g.saturation, 0.2)
    }

    func testTheRealChainNeverBreaksTheBudget() throws {
        for f in [Self.ramp(lo: 0.0, hi: 0.6), Self.ramp(lo: 0.4, hi: 1.0), Self.ramp(lo: 0.2, hi: 0.8, tint: 0.15)] {
            let p = try AutoEnhance.propose(for: f, current: .identity)
            let before = AutoEnhance.stats(f), after = AutoEnhance.stats(try CoreImageEnhance().apply(f, settings: p.applied(to: .identity)))
            XCTAssertLessThanOrEqual(after.clipLow - before.clipLow, AutoEnhance.clipBudgetDark + 1e-9)
            XCTAssertLessThanOrEqual(after.clipHigh - before.clipHigh, AutoEnhance.clipBudgetWhite + 1e-9)
        }
    }

    // MARK: intensity, idempotence, what it keeps

    func testIntensityZeroChangesNothing() throws {
        XCTAssertEqual(try AutoEnhance.propose(for: Self.ramp(lo: 0.2, hi: 0.7), current: .identity, intensity: 0), .none)
    }

    /// The wand reads the frame with its own sliders taken out, so pressing it again on a
    /// frame that carries its values asks for the same values, and sliders it does not own are
    /// kept. With color off, the frame's own warmth is kept too.
    func testPressingItTwiceChangesNothing() throws {
        let f = Self.ramp(lo: 0.15, hi: 0.7)
        var carried = EnhanceSettings(); carried.contrast = 0.2; carried.warmth = 0.3
        let first = try AutoEnhance.propose(for: f, current: carried, readsColour: false)
        let second = try AutoEnhance.propose(for: f, current: first.applied(to: carried), readsColour: false)
        XCTAssertEqual(second.blackPoint, first.blackPoint, accuracy: 1e-9)
        XCTAssertEqual(second.brightness, first.brightness, accuracy: 1e-9)
        let applied = first.applied(to: carried)
        XCTAssertEqual(applied.contrast, 0.2)
        XCTAssertEqual(applied.warmth, 0.3, "with colour off the wand never touches warmth")
    }

    // MARK: the wand's color step

    /// The tone-only wand, step for step, from the public pieces: the reference the flag's off
    /// state must equal.
    static func toneOnlyPropose(for developed: DecodedFrame, current: EnhanceSettings, intensity: Double = 1) throws -> Proposal {
        let render = { (f: DecodedFrame, s: EnhanceSettings) in try CoreImageEnhance().apply(f, settings: s) }
        let proxy = AutoEnhance.sampled(developed, longEdge: 512)
        let base = Proposal.none.applied(to: current)
        let t = AutoEnhance.targets(AutoEnhance.stats(try render(proxy, base)))
        var solved = try AutoEnhance.solve(proxy, base: current, targets: t, render: render)
        let capped = try AutoEnhance.guarded(solved, on: proxy, base: current, render: render)
        if capped.blackPoint < solved.blackPoint - 1e-9 {
            solved = try AutoEnhance.solve(proxy, base: current, targets: t, blackPoint: capped.blackPoint, render: render)
        }
        let k = min(max(intensity, 0), 1)
        solved.blackPoint *= k; solved.brightness *= k; solved.highlights *= k
        solved.saturation *= k; solved.vibrance *= k
        return try AutoEnhance.guarded(solved, on: proxy, base: current, render: render)
    }

    func testTheWandReadsColourByDefault() {
        XCTAssertTrue(AutoEnhance.wandReadsColour)
        XCTAssertEqual(AutoEnhance.wandGreyB, 2.5, "half of the 5 the held-out sweep chose, trimmed in use")
        XCTAssertEqual(AutoEnhance.wbRange, -1.5...1.5, "the neutral solve's clamp and step limit, Neutralize's too")
        XCTAssertEqual(AutoEnhance.wandWarmRange, -3.0...3.0, "the room the wand's warm offset has")
    }

    /// Off, the wand is exactly the tone-only wand: the same proposal, bit for bit, and Warmth
    /// and Tint left as the frame has them.
    func testTheWandWithColorOffIsTheToneOnlyWand() throws {
        for f in [Self.ramp(lo: 0.3, hi: 0.7, tint: -0.04), Self.ramp(lo: 0.15, hi: 0.8)] {
            var carried = EnhanceSettings(); carried.warmth = 0.3; carried.tint = -0.1
            let off = try AutoEnhance.propose(for: f, current: carried, readsColour: false)
            XCTAssertEqual(off, try Self.toneOnlyPropose(for: f, current: carried))
            XCTAssertNil(off.warmth); XCTAssertNil(off.tint)
            let applied = off.applied(to: carried)
            XCTAssertEqual(applied.warmth, 0.3); XCTAssertEqual(applied.tint, -0.1)
        }
    }

    /// On, the wand writes all four Color sliders. Warmth and Tint come from the neutralizer
    /// with the warm offset, read through the tone the wand chose, so a neutral surface lands at
    /// `wandGreyB` in the finished edit's white balance step. Vibrance and Saturation are solved
    /// as the tone-only wand solves them, on the frame balanced by the first read. The
    /// Neutralize button, on the same frame, writes the neutral pair with no offset.
    func testTheWandWithColourOnWritesAllFourColourSliders() throws {
        let f = Self.castRamp(lo: 0.25, hi: 0.8, gains: (0.92, 1.0, 1.12))
        var carried = EnhanceSettings(); carried.warmth = -0.2; carried.tint = 0.3
        let on = try AutoEnhance.propose(for: f, current: carried, readsColour: true)
        let w = try XCTUnwrap(on.warmth), t = try XCTUnwrap(on.tint)
        // The first read balances the frame the solve works on.
        let first = try XCTUnwrap(AutoEnhance.neutralisation(f, current: Proposal.none.applied(to: carried), warmOffset: AutoEnhance.wandGreyB))
        var balanced = carried; balanced.warmth = first.warmth; balanced.tint = first.tint
        let toneOnly = try Self.toneOnlyPropose(for: f, current: balanced)
        XCTAssertEqual(on.saturation, toneOnly.saturation, accuracy: 1e-12)
        XCTAssertEqual(on.vibrance, toneOnly.vibrance, accuracy: 1e-12)
        XCTAssertEqual(on.blackPoint, toneOnly.blackPoint, accuracy: 1e-12)
        XCTAssertEqual(on.brightness, toneOnly.brightness, accuracy: 1e-12)
        XCTAssertNotEqual(on.saturation, 0); XCTAssertNotEqual(on.vibrance, 0)
        // The second read, through the wand's own tone, is what is written.
        let second = try XCTUnwrap(AutoEnhance.neutralisation(f, current: toneOnly.applied(to: balanced), warmOffset: AutoEnhance.wandGreyB))
        XCTAssertEqual(w, second.warmth, accuracy: 1e-12); XCTAssertEqual(t, second.tint, accuracy: 1e-12)
        XCTAssertEqual(second.landedB, AutoEnhance.wandGreyB, accuracy: 0.1, "a neutral lands at the wand's b*")
        XCTAssertGreaterThan(w, second.neutralWarmth, "the offset only warms")
        XCTAssertEqual(t, second.neutralTint, accuracy: 1e-12, "the offset moves Warmth alone")
        let applied = on.applied(to: carried)
        XCTAssertEqual(applied.warmth, w); XCTAssertEqual(applied.tint, t)
        XCTAssertEqual(applied.saturation, on.saturation); XCTAssertEqual(applied.vibrance, on.vibrance)
        // The button: the neutral pair, no offset.
        let button = try XCTUnwrap(AutoEnhance.neutralising(f, current: carried))
        let plain = try XCTUnwrap(AutoEnhance.neutralisation(f, current: carried))
        XCTAssertEqual(button.warmth, plain.neutralWarmth, accuracy: 1e-12)
        XCTAssertEqual(button.tint, plain.neutralTint, accuracy: 1e-12)
        XCTAssertEqual(plain.warmth, plain.neutralWarmth, "no offset on the button")
        // Pressing the wand again asks for the same color.
        let again = try AutoEnhance.propose(for: f, current: on.applied(to: carried), readsColour: true)
        XCTAssertEqual(try XCTUnwrap(again.warmth), w, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(again.tint), t, accuracy: 1e-9)
    }

    /// The offset never cools: a frame whose neutrals already sit warmer than the placeholder
    /// after neutralizing keeps them there.
    func testTheWarmOffsetNeverCools() throws {
        let f = Self.ramp(lo: 0.3, hi: 0.7, tint: -0.04)
        let n = try XCTUnwrap(AutoEnhance.neutralisation(f, current: .identity, warmOffset: -20))
        XCTAssertEqual(n.warmth, n.neutralWarmth, accuracy: 1e-12)
    }

    // MARK: the cast neutralizer

    /// A grey ramp under a real cast: the light's color as linear gains on every pixel, which
    /// is what a change of light does, rather than a constant added in display values.
    static func castRamp(lo: Double, hi: Double, gains: (Double, Double, Double), w: Int = 160, h: Int = 100) -> DecodedFrame {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func enc(_ v: Double) -> UInt16 {
            let c = min(max(v, 0), 1)
            return UInt16(((c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055) * 65535).rounded())
        }
        var px = [UInt16](); px.reserveCapacity(w * h * 3)
        for _ in 0..<h { for x in 0..<w {
            let v = lin(lo + (hi - lo) * Double(x) / Double(w - 1))
            px += [enc(v * gains.0), enc(v * gains.1), enc(v * gains.2)]
        } }
        return DecodedFrame(width: w, height: h, pixels: px)
    }

    /// A blue cast grey ramp is warmed, and its near-grey pixels end within a quarter of the
    /// b* they started at. Step 4's method balances a little PAST neutral on b* (castStrength
    /// 1.13) and removes about half of a* (tintShare 0.50), so the test does not ask for zero.
    func testABlueCastGreyComesBackNeutral() throws {
        let blue = Self.castRamp(lo: 0.25, hi: 0.8, gains: (0.92, 1.0, 1.12))
        let before = try XCTUnwrap(AutoEnhance.cast(blue, mask: AutoEnhance.neutralMask(blue)))
        XCTAssertLessThan(before.b, -3, "the frame reads blue")
        let wt = try XCTUnwrap(AutoEnhance.neutralising(blue, current: .identity))
        var s = EnhanceSettings(); s.warmth = wt.warmth; s.tint = wt.tint
        let out = try CoreImageEnhance().apply(blue, settings: s)
        let after = try XCTUnwrap(AutoEnhance.cast(out, mask: AutoEnhance.neutralMask(blue)))
        print(String(format: "NEUTRALIZE blue ramp: warmth %+.4f tint %+.4f, b* %+.2f -> %+.2f, a* %+.2f -> %+.2f", wt.warmth, wt.tint, before.b, after.b, before.a, after.a))
        XCTAssertLessThan(abs(after.b), 0.25 * abs(before.b), "b* \(before.b) -> \(after.b)")
        XCTAssertLessThanOrEqual(abs(after.a), abs(before.a) + 0.2, "a* never pushed further out")
        XCTAssertGreaterThan(wt.warmth, 0, "a blue cast is warmed")
    }

    /// A deliberately warm frame is left alone: its cast is larger than the estimator's
    /// near-grey threshold and its fade, so the button reads no cast to remove, or moves a
    /// neutral no further than the cap. Either way the frame stays warm.
    func testAWarmSceneIsNotFlattened() throws {
        let sunset = Self.ramp(lo: 0.3, hi: 0.75, tint: 0.16)
        let mask = AutoEnhance.neutralMask(sunset)
        let before = try XCTUnwrap(AutoEnhance.cast(sunset, mask: mask))
        XCTAssertGreaterThan(before.b, 10, "deliberately warm")
        var s = EnhanceSettings()
        if let n = try AutoEnhance.neutralisation(sunset, current: .identity) {
            XCTAssertLessThanOrEqual(n.fraction * n.reading.chroma, AutoEnhance.castMethod.castCap + 1e-9, "never more than the cap")
            s.warmth = n.warmth; s.tint = n.tint
        }
        let after = try XCTUnwrap(AutoEnhance.cast(try CoreImageEnhance().apply(sunset, settings: s), mask: mask))
        print(String(format: "NEUTRALIZE warm ramp: warmth %+.4f tint %+.4f, b* %+.2f -> %+.2f", s.warmth, s.tint, before.b, after.b))
        XCTAssertGreaterThan(after.b, 0.5 * before.b, "still a warm frame, never flattened to grey")
    }

    /// A real-sized proxy reads and solves without trouble. The solve renders an 8 by 8 patch,
    /// since the grey pixels sent to the GPU as one strip pass its texture width on this frame.
    func testALargeFrameNeutralisesWithoutAnOversizedTexture() throws {
        let big = Self.ramp(lo: 0.3, hi: 0.7, tint: -0.04, w: 512, h: 512)
        XCTAssertGreaterThan(AutoEnhance.neutralMask(big).filter { $0 }.count, 16384, "enough grey pixels to have crashed")
        XCTAssertNotNil(try AutoEnhance.neutralising(big, current: .identity))
    }

    func testAColourlessFrameIsLeftAlone() throws {
        XCTAssertNil(try AutoEnhance.neutralising(Self.ramp(lo: 0.2, hi: 0.8, tint: 0), current: .identity))
    }

    // MARK: the model

    @MainActor
    func testTheModelWritesOneUndoStep() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-test-auto-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (model, ids) = try scratchRollModel(frames: 2, in: scratch)
        model.applyAutoEnhance([(ids[0], Proposal(blackPoint: 0.4, brightness: 0.3, highlights: -0.1, saturation: 0.1, vibrance: 0.09)),
                                (ids[1], Proposal(blackPoint: 0.2, brightness: 0, highlights: 0, saturation: 0, vibrance: 0))])
        XCTAssertEqual(model.frame(ids[0])?.sidecar.enhance?.blackPoint, 0.4)
        XCTAssertEqual(model.frame(ids[1])?.sidecar.enhance?.blackPoint, 0.2)
        model.undoManager.undo()
        XCTAssertNil(model.frame(ids[0])?.sidecar.enhance)
        XCTAssertNil(model.frame(ids[1])?.sidecar.enhance)
    }

    /// A wand run resets the whole enhance layer first. A frame with a hand value on
    /// every slider ends with the wand's values and every other field at exactly 0, whether the
    /// proposal carries Warmth and Tint or leaves them nil. One Undo brings the hand values back.
    @MainActor
    func testTheWandResetsTheWholeLayerFirst() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (model, ids) = try scratchRollModel(frames: 2, in: scratch)
        var hand = EnhanceSettings()
        for c in EnhanceControl.all { hand = c.setting(hand, to: 0.37) }
        XCTAssertTrue(EnhanceControl.all.allSatisfy { $0.value(in: hand) == 0.37 }, "a hand value on every slider")
        model.undoManager.beginUndoGrouping()
        for id in ids { model.apply({ SidecarEdits.setEnhance($0, hand) }, to: id, actionName: "Hand") }
        model.undoManager.endUndoGrouping()

        let colour = Proposal(blackPoint: 0.1, brightness: 0.2, highlights: -0.3, saturation: 0.15, vibrance: 0.12,
                              warmth: 0.4, tint: -0.05, shadows: 0.3, exposure: 0.1)
        let tone = Proposal(blackPoint: 0.05, brightness: 0, highlights: 0, saturation: 0, vibrance: 0)
        model.applyAutoEnhance([(ids[0], colour), (ids[1], tone)])

        let wandOwns: Set<String> = ["blackPoint", "brightness", "highlights", "saturation", "vibrance", "warmth", "tint",
                                     "shadows", "exposure"]
        for (id, p) in [(ids[0], colour), (ids[1], tone)] {
            let e = try XCTUnwrap(model.frame(id)?.sidecar.enhance)
            XCTAssertEqual(e, p.applied(to: .identity))
            for c in EnhanceControl.all where !wandOwns.contains(c.id) {
                XCTAssertEqual(e[keyPath: c.path], 0, "\(c.id) kept a hand value through the wand")
            }
        }
        let second = try XCTUnwrap(model.frame(ids[1])?.sidecar.enhance)
        XCTAssertEqual(second.warmth, 0, "a proposal without colour leaves Warmth at 0, not at the hand value")
        XCTAssertEqual(second.tint, 0)
        model.undoManager.undo()
        XCTAssertEqual(model.frame(ids[0])?.sidecar.enhance, hand)
    }

    // MARK: the tone style

    /// The style's Shadows and Exposure follow the lift the frame's target asks for and never
    /// leave -1...1, however large the coefficients.
    func testTheToneStyleStaysInsideTheSliderBox() {
        let t = AutoEnhance.targets(AutoEnhance.stats(Self.ramp(lo: 0.05, hi: 0.4)))
        XCTAssertGreaterThan(t.dMeanLuma, 0, "a dark frame asks for lift")
        let big = AutoEnhance.style((1000, -1000), for: t)
        XCTAssertEqual(big.shadows, 1)
        XCTAssertEqual(big.exposure, -1)
        let s = AutoEnhance.style((2, 1), for: t)
        XCTAssertEqual(s.shadows, 2 * t.dMeanLuma, accuracy: 1e-12)
        XCTAssertEqual(s.exposure, t.dMeanLuma, accuracy: 1e-12)
    }

    /// The solve holds the style it is given and lands the same mean luma with the rest, taking
    /// part of the Brightness lift away.
    func testTheSolveHoldsTheStyleAndStillLandsTheTarget() throws {
        let f = Self.ramp(lo: 0.1, hi: 0.6)
        let t = AutoEnhance.targets(AutoEnhance.stats(f))
        let render = { (f: DecodedFrame, s: EnhanceSettings) in try CoreImageEnhance().apply(f, settings: s) }
        let plain = try AutoEnhance.solve(f, base: .identity, targets: t, render: render)
        let styled = try AutoEnhance.solve(f, base: .identity, targets: t, style: (0.4, 0.15), render: render)
        XCTAssertEqual(styled.shadows, 0.4)
        XCTAssertEqual(styled.exposure, 0.15)
        XCTAssertLessThan(styled.brightness, plain.brightness, "shadow lift and gain take over part of the Brightness lift")
        let s0 = AutoEnhance.stats(f), s1 = AutoEnhance.stats(try render(f, styled.applied(to: .identity)))
        XCTAssertEqual(s1.meanLuma - s0.meanLuma, t.dMeanLuma, accuracy: 0.01, "mean luma")
    }

    /// An Exposure that pushes the whites past the budget is scaled back with the rest of the
    /// upward push, and Shadows, which lifts the bottom, is left alone.
    func testAWhiteBreachScalesExposureToo() {
        let p = Proposal(blackPoint: 0, brightness: 0, highlights: 0, saturation: 0, vibrance: 0, shadows: 0.3, exposure: 0.5)
        func render(_ f: DecodedFrame, _ s: EnhanceSettings) -> DecodedFrame {
            // 2% of pixels clipped white per unit of Exposure.
            let clipped = Int((max(s.exposure, 0) * 0.02 * Double(f.width * f.height)).rounded())
            var px = [UInt16](repeating: 32767, count: f.width * f.height * 3)
            for i in 0..<clipped { px[i * 3] = 65535; px[i * 3 + 1] = 65535; px[i * 3 + 2] = 65535 }
            return DecodedFrame(width: f.width, height: f.height, pixels: px)
        }
        let g = AutoEnhance.guarded(p, on: Self.solid(0.5, 0.5, 0.5, w: 100, h: 100), base: .identity, render: render)
        XCTAssertEqual(g.exposure, 0.25, accuracy: 0.01, "1 point at full, half a point at half, the most that holds")
        XCTAssertEqual(g.shadows, 0.3)
    }

    /// On a black-and-white stock the style is zero, so the Arista roll is unchanged by it.
    /// The same frame read as a color stock is the control while the style is on.
    func testTheToneStyleIsZeroOnAMonoStock() throws {
        let dark = Self.ramp(lo: 0.05, hi: 0.45, tint: 0.08)
        let mono = try AutoEnhance.propose(for: dark, current: .identity, mono: true)
        XCTAssertEqual(mono.shadows, 0)
        XCTAssertEqual(mono.exposure, 0)
        let t = AutoEnhance.targets(AutoEnhance.stats(dark))
        let colour = try AutoEnhance.propose(for: dark, current: .identity)
        let want = AutoEnhance.style(AutoEnhance.toneStyle, for: t)
        if want.shadows != 0 { XCTAssertNotEqual(colour.shadows, 0, "control: a colour stock gets the style") }
        XCTAssertLessThanOrEqual(abs(colour.shadows), 1)
        XCTAssertLessThanOrEqual(abs(colour.exposure), 1)
    }

    // MARK: Shadows answers for Black Point

    /// With Brightness held, the solve frees Shadows in its place, keeps it inside -1...1, and
    /// still lands the mean luma. A dark frame asks for lift, so Shadows goes up.
    func testTheHoldFreesShadowsInsideTheSliderBox() throws {
        let f = Self.ramp(lo: 0.05, hi: 0.45)
        let t = AutoEnhance.targets(AutoEnhance.stats(f))
        let render = { (f: DecodedFrame, s: EnhanceSettings) in try CoreImageEnhance().apply(f, settings: s) }
        let held = try AutoEnhance.solve(f, base: .identity, targets: t, holdBrightness: -0.2, render: render)
        XCTAssertEqual(held.brightness, -0.2)
        XCTAssertGreaterThan(held.shadows, 0, "Shadows buys back the midtones")
        XCTAssertLessThanOrEqual(abs(held.shadows), 1)
        let s0 = AutoEnhance.stats(f), s1 = AutoEnhance.stats(try render(f, held.applied(to: .identity)))
        XCTAssertEqual(s1.meanLuma - s0.meanLuma, t.dMeanLuma, accuracy: 0.02, "mean luma")
        let whole = try AutoEnhance.propose(for: f, current: .identity, holdBrightness: -0.2)
        XCTAssertLessThanOrEqual(abs(whole.shadows), 1)
        XCTAssertLessThanOrEqual(whole.brightness, 0, "the guard only ever scales the hold toward 0")
        XCTAssertGreaterThanOrEqual(whole.brightness, -0.2)
    }

    /// A black-and-white stock keeps the free set it has without a hold, whatever hold the wand
    /// carries, and still writes no color.
    func testTheHoldIsIgnoredOnAMonoStock() throws {
        let tinted = Self.ramp(lo: 0.05, hi: 0.45, tint: 0.08)
        let held = try AutoEnhance.propose(for: tinted, current: .identity, mono: true, holdBrightness: -0.2)
        let free = try AutoEnhance.propose(for: tinted, current: .identity, mono: true, holdBrightness: nil)
        XCTAssertEqual(held, free)
        XCTAssertEqual(held.shadows, 0)
        XCTAssertEqual(held.saturation, 0)
        XCTAssertNil(held.warmth)
        XCTAssertNil(held.tint)
    }

    // MARK: the upper-midtone target

    /// No shape, no target, and the shape moves no other target. On a black-and-white stock
    /// there is never one, whatever the shape, so the target is color-only and Arista is
    /// unchanged.
    func testTheP75TargetIsOffWithoutAShapeAndOnMono() {
        let s = AutoEnhance.stats(Self.ramp(lo: 0.05, hi: 0.6, tint: 0.08))
        XCTAssertNil(AutoEnhance.targets(s, p75Shape: nil).dP75)
        XCTAssertNil(AutoEnhance.targets(s, mono: true, p75Shape: 0.01).dP75)
        let on = AutoEnhance.targets(s, p75Shape: 0.01)
        XCTAssertEqual(try XCTUnwrap(on.dP75), on.dMeanLuma + 0.01, accuracy: 1e-12)
        var off = on; off.dP75 = nil
        XCTAssertEqual(off, AutoEnhance.targets(s, p75Shape: nil), "the other targets do not move")
    }

    /// The target acts: asking p75 to rise further than the mean lands a higher p75 than the
    /// same solve without it.
    func testTheP75TargetMovesTheUpperMidtones() throws {
        let f = Self.ramp(lo: 0.05, hi: 0.6)
        let render: (DecodedFrame, EnhanceSettings) throws -> DecodedFrame = { try CoreImageEnhance().apply($0, settings: $1) }
        let s = AutoEnhance.stats(f)
        var up = AutoEnhance.targets(s, p75Shape: nil); up.dP75 = up.dMeanLuma + 0.06
        let without = try AutoEnhance.solve(f, base: .identity, targets: AutoEnhance.targets(s, p75Shape: nil), render: render)
        let with = try AutoEnhance.solve(f, base: .identity, targets: up, render: render)
        let p0 = AutoEnhance.stats(try render(f, without.applied(to: .identity))).p75
        let p1 = AutoEnhance.stats(try render(f, with.applied(to: .identity))).p75
        XCTAssertGreaterThan(p1, p0 + 0.005, "p75 \(p0) without the target, \(p1) with it")
    }

    // MARK: black and white

    /// On a black-and-white stock the wand writes no color key, however much tint the
    /// scan carries. The same tinted frame read as a color stock is the control, and there the
    /// wand does write color, so the test cannot pass by the frame simply having none.
    func testTheWandWritesNoColourOnAMonoStock() throws {
        let tinted = Self.ramp(lo: 0.15, hi: 0.7, tint: 0.08)
        XCTAssertTrue(AutoEnhance.stats(tinted).hasColour, "the control frame carries colour")
        let asColour = try AutoEnhance.propose(for: tinted, current: .identity)
        XCTAssertTrue(asColour.saturation != 0 || asColour.warmth != nil,
                      "control: read as a colour stock the wand writes colour on this frame")
        let mono = try AutoEnhance.propose(for: tinted, current: .identity, mono: true)
        XCTAssertEqual(mono.saturation, 0)
        XCTAssertEqual(mono.vibrance, 0)
        XCTAssertNil(mono.warmth)
        XCTAssertNil(mono.tint)
        let written = mono.applied(to: .identity)
        for (name, key) in [("saturation", \EnhanceSettings.saturation), ("vibrance", \.vibrance), ("warmth", \.warmth), ("tint", \.tint)] {
            XCTAssertEqual(written[keyPath: key], 0, "\(name) written on a black-and-white stock")
        }
        XCTAssertNotEqual(mono, .none, "the tone half still runs")
        XCTAssertEqual(AutoEnhance.targets(AutoEnhance.stats(tinted), mono: true).dSat, 0)
    }

    /// The app tells the wand which frames are black and white, from each frame's effective
    /// stock.
    @MainActor
    func testTheModelTellsTheWandAFrameIsMono() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (model, ids) = try scratchRollModel(frames: 2, in: scratch)
        let first = try XCTUnwrap(model.frame(ids[0]))
        var develop = try XCTUnwrap(model.effectiveDevelop(for: first))
        develop.stock = ProfileLibrary.monoStockID
        model.undoManager.beginUndoGrouping()
        model.apply({ SidecarEdits.setDevelop($0, develop) }, to: ids[0], actionName: "Stock")
        model.undoManager.endUndoGrouping()
        XCTAssertEqual(model.wandJob(try XCTUnwrap(model.frame(ids[0])))?.2, true)
        XCTAssertEqual(model.wandJob(try XCTUnwrap(model.frame(ids[1])))?.2, false)
    }

    /// A bulk run shows it is working (the button's spinner, and the frame being read marked in
    /// the grid) and clears both when it ends. One frame shows nothing.
    @MainActor
    func testABulkRunShowsProgressAndClearsIt() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (model, ids) = try scratchRollModel(frames: 3, in: scratch)
        model.selection = [ids[0]]
        model.autoEnhanceSelection()
        XCTAssertFalse(model.enhanceRunning, "one frame reads too fast to need a spinner")
        model.selection = Set(ids)
        model.autoEnhanceSelection()
        XCTAssertTrue(model.enhanceRunning)
        model.neutraliseCastSelection()   // refused while a run is going
        var waited = 0
        while model.enhanceRunning && waited < 600 { try await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
        XCTAssertFalse(model.enhanceRunning)
        XCTAssertNil(model.enhanceReading)
    }
}

/// The manifest regression: the rule over 116 frames that each carry a reference edit, at 512 px.
/// Two passes.
///
/// 1. The rule as it asks, before the clip guard, printed beside the reference edit's changes.
///    The lines are fitted to a different set of edits, so the comparison is printed and not
///    asserted.
/// 2. The wand as it ships, with the guard: no frame over the budget at either end.
///
/// About nine minutes, so it runs only when asked: FP_ENHANCE_MANIFEST=1 and the fixture at
/// $FP_FIXTURES/enhance-ab.
final class AutoEnhanceManifestTests: XCTestCase {
    struct Sums { var p1 = 0.0, luma = 0.0, sat = 0.0, hue = 0.0 }

    func testTheRuleOverTheManifest() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FP_ENHANCE_MANIFEST"] == "1", let root = env["FP_FIXTURES"] else {
            throw XCTSkip("set FP_ENHANCE_MANIFEST=1 to run the 116-frame manifest regression")
        }
        let dir = URL(fileURLWithPath: root).appendingPathComponent("enhance-ab")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix("-off.jpg") }.sorted()
        XCTAssertGreaterThanOrEqual(names.count, 100, "the manifest is on disk")
        var rule = Sums(), ship = Sums(), photos = Sums(), n = 0.0
        var overBudget: [String] = []
        for name in names {
            let id = String(name.dropLast("-off.jpg".count))
            guard let off = AutoEnhance.load(dir.appendingPathComponent(name), longEdge: 512),
                  let ph = AutoEnhance.load(dir.appendingPathComponent("\(id)-ref.jpg"), longEdge: 512) else { continue }
            let s0 = AutoEnhance.stats(off), sp = AutoEnhance.stats(ph)
            func add(_ sums: inout Sums, _ out: DecodedFrame) {
                let s = AutoEnhance.stats(out)
                sums.p1 += abs(s.p1 - s0.p1); sums.luma += abs(s.meanLuma - s0.meanLuma)
                sums.sat += abs(s.meanSat - s0.meanSat); sums.hue += AutoEnhance.hueShift(off, out)
            }
            add(&photos, ph)
            let asked = try AutoEnhance.propose(for: off, current: .identity, clipGuard: false)
            add(&rule, try CoreImageEnhance().apply(off, settings: asked.applied(to: .identity)))
            let shipped = try AutoEnhance.propose(for: off, current: .identity)
            let out = try CoreImageEnhance().apply(off, settings: shipped.applied(to: .identity))
            add(&ship, out)
            let s1 = AutoEnhance.stats(out)
            if s1.clipLow - s0.clipLow > AutoEnhance.clipBudgetDark + 1e-9 || s1.clipHigh - s0.clipHigh > AutoEnhance.clipBudgetWhite + 1e-9 { overBudget.append(id) }
            n += 1
        }
        for (label, s) in [("photos", photos), ("rule", rule), ("shipped", ship)] {
            print(String(format: "MANIFEST %@ n=%d p1 %.4f luma %.4f sat %.4f hue %.2f", label, Int(n), s.p1 / n, s.luma / n, s.sat / n, s.hue / n))
        }
        XCTAssertEqual(overBudget, [], "frames over the clip budget")
    }
}
