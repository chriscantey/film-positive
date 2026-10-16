import XCTest
import CoreImage
import FilmSidecar
@testable import FilmPositiveCore

/// The cast estimator as it ships: not a stage in the chain, but the reading Neutralize writes
/// onto Warmth and Tint (`AutoEnhance.neutralisation`). The bounds below were fixed before the
/// estimator's first sweep, and they judge the Warmth and Tint the button writes, rendered
/// through the chain. Every scene is synthetic and says so: no grey card or chart frame has
/// been shot yet.
final class AdaptiveColourTests: XCTestCase {
    typealias AC = AdaptiveColour
    typealias Probe = AdaptiveColourProbe

    /// The scene after the Neutralize button: the Warmth and Tint it writes, rendered.
    func neutralised(_ scene: DecodedFrame, method: AC.Parameters = AutoEnhance.castMethod) throws -> (out: DecodedFrame, n: AutoEnhance.Neutralisation?) {
        let n = try AutoEnhance.neutralisation(scene, current: .identity, method: method)
        var s = EnhanceSettings.identity
        s.warmth = n?.warmth ?? 0; s.tint = n?.tint ?? 0
        return (try CoreImageEnhance().apply(scene, settings: s), n)
    }

    // MARK: No color stage

    /// The chain carries no automatic color stage: it has no configuration at all, and Radiance
    /// alone leaves a cast grey card's color where it was, where a color stage takes |ab|
    /// from 4.23 to 1.33. Fails if a white balance step returns to the chain.
    func testTheChainHasNoColourStage() throws {
        let fields = Mirror(reflecting: CoreImageEnhance()).children.map { $0.label ?? "" }
        XCTAssertEqual(fields, [], "the enhance stage carries no configuration")

        let scene = Probe.mixedScene(cast: (0.92, 1.0, 1.12))
        var s = EnhanceSettings.identity
        s.radiance = 1.0
        let before = Probe.cardLab(scene), after = Probe.cardLab(try CoreImageEnhance().apply(scene, settings: s))
        let d0 = (before.a * before.a + before.b * before.b).squareRoot(), d1 = (after.a * after.a + after.b * after.b).squareRoot()
        let turn = abs(atan2(after.b, after.a) - atan2(before.b, before.a)) * 180 / .pi
        print(String(format: "NO COLOUR STAGE card a* %+.2f -> %+.2f, b* %+.2f -> %+.2f, |ab| %.2f -> %.2f", before.a, after.a, before.b, after.b, d0, d1))
        XCTAssertGreaterThan(d1, 0.8 * d0, "Radiance alone must not neutralise the card")
        XCTAssertLessThan(turn, 5, "Radiance alone must not turn the card's hue")
    }

    /// Radiance 0 renders bit for bit as the chain without Radiance: identity settings return
    /// the frame itself. Fails if the zero case ever falls into the operator.
    func testRadianceZeroIsBitForBit() throws {
        let scene = Probe.mixedScene(cast: (0.9, 1.0, 1.15))
        XCTAssertEqual(try CoreImageEnhance().apply(scene, settings: .identity).pixels, scene.pixels)
    }

    // MARK: The grey card, through Neutralize

    /// A grey card in a scene with no cast stays neutral: its |a*| and |b*| after the Warmth and
    /// Tint Neutralize writes are no larger than max(1.0, before). Under a cast the card's
    /// distance from neutral shrinks and neither axis grows past max(1.0, before). Two casts,
    /// the develop's measured direction (green and blue) and a warm one. Fails if the button
    /// invents a cast on a neutral scene or moves a real one the wrong way.
    func testAGreyCardStaysOrGoesNeutral() throws {
        for (label, cast, mustShrink) in Probe.casts {
            let scene = Probe.mixedScene(cast: cast)
            let before = Probe.cardLab(scene)
            let (out, n) = try neutralised(scene)
            let after = Probe.cardLab(out)
            let d0 = (before.a * before.a + before.b * before.b).squareRoot()
            let d1 = (after.a * after.a + after.b * after.b).squareRoot()
            let w: Double = n?.warmth ?? 0, t: Double = n?.tint ?? 0
            print(String(format: "NEUTRALIZE grey card, %@: warmth %+.4f tint %+.4f, a* %+.2f -> %+.2f, b* %+.2f -> %+.2f, |ab| %.2f -> %.2f",
                         label, w, t, before.a, after.a, before.b, after.b, d0, d1))
            XCTAssertLessThanOrEqual(abs(after.a), max(1.0, abs(before.a)), "\(label): card a*")
            XCTAssertLessThanOrEqual(abs(after.b), max(1.0, abs(before.b)), "\(label): card b*")
            if mustShrink { XCTAssertLessThan(d1, d0, "\(label): the card must move toward neutral") }
        }
    }

    // MARK: The color dominant scene, through Neutralize

    /// A warm sunset field, mostly one saturated hue, with or without a few neutral objects.
    /// Neutralize may shorten the frame's mean (a*, b*) vector by at most 5 percent and turn it
    /// by at most 3 degrees. The CONTROL is the bright patch estimator with its cap and fade
    /// switched off and the whole cast removed, which reads the sunset itself as the light and
    /// must fail the same bound, or this test could not see a neutralizer.
    func testAColourDominantSceneSurvives() throws {
        func verdict(_ f: DecodedFrame, _ p: AC.Parameters, _ label: String) throws -> Bool {
            let (r0, h0) = Probe.meanVector(f)
            let (out, n) = try neutralised(f, method: p)
            let (r1, h1) = Probe.meanVector(out)
            let w: Double = n?.warmth ?? 0, t: Double = n?.tint ?? 0
            print(String(format: "NEUTRALIZE sunset, %@: read %@, warmth %+.4f tint %+.4f, |mean ab| %.2f -> %.2f (%.1f percent), angle %.2f -> %.2f deg",
                         label, n == nil ? "nothing" : "a cast", w, t, r0, r1, 100 * (r1 - r0) / r0, h0, h1))
            return r1 >= (1 - Probe.sunsetShortening) * r0 && abs(h1 - h0) <= Probe.sunsetTurn
        }
        for n in [true, false] {
            XCTAssertTrue(try verdict(Probe.sunset(neutrals: n), AutoEnhance.castMethod, "shipped, neutrals \(n)"),
                          "Neutralize pulls a sunset toward neutral (neutrals \(n))")
        }
        var control = AutoEnhance.castMethod
        control.estimator = .brightPatch; control.castStrength = 1; control.tintShare = 1
        control.castCap = 1000; control.castFade = 1000
        XCTAssertFalse(try verdict(Probe.sunset(neutrals: true), control, "control, uncapped bright patch"),
                       "an uncapped neutraliser must fail this bound, or the test cannot see one")
    }

    // MARK: The mapping onto Warmth and Tint

    /// The Warmth and Tint written land a neutral surface where von Kries gains would
    /// put it, within 0.3 in a* and b*, on the grey card scenes. The same pair then agrees
    /// with the same gains within 0.4 on surfaces of the estimate's a* and b* at L* 35 and 70,
    /// since both are linear maps of linear light. Fails if the solve stops short or the
    /// filter's direction changes.
    func testWarmthAndTintLandTheVonKriesGoal() throws {
        for (label, cast, _) in Probe.casts where cast != (1, 1, 1) {
            let n = try XCTUnwrap(AutoEnhance.neutralisation(Probe.mixedScene(cast: cast), current: .identity))
            print(String(format: "NEUTRALIZE mapping, %@: goal a %+.3f b %+.3f, lands a %+.3f b %+.3f",
                         label, n.goalA, n.goalB, n.neutralA, n.neutralB))
            XCTAssertEqual(n.neutralA, n.goalA, accuracy: 0.3, "\(label) a*")
            XCTAssertEqual(n.neutralB, n.goalB, accuracy: 0.3, "\(label) b*")
            let e = AC.rgb(n.reading.l, n.reading.a, n.reading.b), g = AC.rgb(n.goalL, n.goalA, n.goalB)
            let gains = (g.0 / e.0, g.1 / e.1, g.2 / e.2)
            var q = EnhanceSettings.identity
            q.warmth = n.warmth; q.tint = n.tint
            for l in [35.0, 70.0] {
                let p = AC.rgb(l, n.reading.a, n.reading.b)
                let vk = AC.lab(p.0 * gains.0, p.1 * gains.1, p.2 * gains.2)
                let wt = AutoEnhance.meanLabD50(try CoreImageEnhance().apply(AutoEnhance.patch(l, n.reading.a, n.reading.b), settings: q))
                print(String(format: "  at L %.0f: von Kries a %+.3f b %+.3f, Warmth and Tint a %+.3f b %+.3f", l, vk.1, vk.2, wt.a, wt.b))
                XCTAssertEqual(wt.a, vk.1, accuracy: 0.4, "\(label) a* at L \(l)")
                XCTAssertEqual(wt.b, vk.2, accuracy: 0.4, "\(label) b* at L \(l)")
            }
        }
    }

    /// The reading is made without the frame's own Warmth and Tint, so what Neutralize writes
    /// is absolute: the same values whatever the frame carried, and pressing it again changes
    /// nothing.
    func testNeutralizeIsAbsolute() throws {
        let scene = Probe.mixedScene(cast: (0.92, 1.0, 1.12))
        let first = try XCTUnwrap(AutoEnhance.neutralising(scene, current: .identity))
        var carried = EnhanceSettings.identity
        carried.warmth = 0.4; carried.tint = -0.3; carried.saturation = 0.2
        let fromCarried = try XCTUnwrap(AutoEnhance.neutralising(scene, current: carried))
        XCTAssertEqual(fromCarried.warmth, first.warmth, accuracy: 1e-9)
        XCTAssertEqual(fromCarried.tint, first.tint, accuracy: 1e-9)
        carried.warmth = first.warmth; carried.tint = first.tint
        let again = try XCTUnwrap(AutoEnhance.neutralising(scene, current: carried))
        XCTAssertEqual(again.warmth, first.warmth, accuracy: 1e-9)
        XCTAssertEqual(again.tint, first.tint, accuracy: 1e-9)
    }
}
