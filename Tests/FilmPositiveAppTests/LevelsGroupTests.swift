import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The Levels group's rules, as pure functions. The handles, the midtone's place on the
/// track, the accessibility ids and help, the fold, and the request its histogram renders.
final class LevelsGroupTests: XCTestCase {
    func testHandlesKeepTheirRules() {
        let l = Levels(inBlack: 0.2, gamma: 1, inWhite: 0.8, outBlack: 0.1, outWhite: 0.9)
        XCTAssertEqual(LevelsHandle.inBlack.setting(l, to: 0.95).inBlack, 0.79, accuracy: 1e-12, "black stops 0.01 under white")
        XCTAssertEqual(LevelsHandle.inWhite.setting(l, to: 0.05).inWhite, 0.21, accuracy: 1e-12, "white stops 0.01 over black")
        XCTAssertEqual(LevelsHandle.inBlack.setting(l, to: -0.4).inBlack, 0)
        XCTAssertEqual(LevelsHandle.inWhite.setting(l, to: 1.7).inWhite, 1)
        XCTAssertEqual(LevelsHandle.outBlack.setting(l, to: 0.95).outBlack, 0.89, accuracy: 1e-12, "output black and white do not cross either")
        XCTAssertEqual(LevelsHandle.outWhite.setting(l, to: 0).outWhite, 0.11, accuracy: 1e-12)
        XCTAssertEqual(LevelsHandle.gamma.setting(l, to: 40).gamma, 10)
        XCTAssertEqual(LevelsHandle.gamma.setting(l, to: 0.01).gamma, 0.1)
        XCTAssertEqual(LevelsHandle.gamma.setting(l, to: 1.234567).gamma, 1.2346, "held to the file's grain")
        XCTAssertEqual(LevelsHandle.gamma.setting(l, to: .nan), l, "a non-finite write changes nothing")
        let other = LevelsHandle.inBlack.setting(l, to: 0.3)
        XCTAssertEqual(other.inWhite, l.inWhite)
        XCTAssertEqual(other.gamma, l.gamma, "a handle writes its own field only")
    }

    /// Midtone sits halfway at gamma 1, and LEFT is brighter: a smaller position is a larger
    /// gamma, and a larger gamma lifts the midtones.
    func testTheMidtoneSitsHalfwayAndLeftBrightens() {
        let l = Levels(inBlack: 0.1, inWhite: 0.9)
        XCTAssertEqual(LevelsGeometry.midtonePosition(l), 0.5, accuracy: 1e-12)
        let left = LevelsGeometry.gamma(atPosition: 0.35, l), right = LevelsGeometry.gamma(atPosition: 0.65, l)
        XCTAssertGreaterThan(left, 1)
        XCTAssertLessThan(right, 1)
        XCTAssertGreaterThan(LevelsMath.apply(Levels(gamma: left), to: 0.5), 0.5, "left brightens")
        XCTAssertLessThan(LevelsMath.apply(Levels(gamma: right), to: 0.5), 0.5)
        // The two functions are inverses across the whole range.
        for g in [0.1, 0.5, 1, 2.5, 10] {
            var m = l; m.gamma = g
            XCTAssertEqual(LevelsGeometry.gamma(atPosition: LevelsGeometry.midtonePosition(m), m), g, accuracy: 1e-9)
        }
        // Past either input handle the gamma stops at its range.
        XCTAssertEqual(LevelsGeometry.gamma(atPosition: 0, l), 10, accuracy: 1e-9)
        XCTAssertEqual(LevelsGeometry.gamma(atPosition: 1, l), 0.1, accuracy: 1e-9)
        // Moving black and white carries the midtone with them at the same gamma.
        var moved = l; moved.gamma = 2
        let a = LevelsGeometry.midtonePosition(moved)
        moved.inWhite = 0.7
        XCTAssertLessThan(LevelsGeometry.midtonePosition(moved), a)
    }

    func testIdsAndHelp() {
        XCTAssertEqual(LevelsHandle.allCases.map(\.id),
                       ["levels.inBlack", "levels.gamma", "levels.inWhite", "levels.outBlack", "levels.outWhite"])
        for h in LevelsHandle.allCases {
            XCTAssertTrue(h.help.hasSuffix("."), "\(h): one sentence")
            XCTAssertEqual(h.help.components(separatedBy: ". ").count, 1, "\(h): one sentence")
            XCTAssertFalse(h.help.contains("\u{2014}"), "\(h): no em dash")
            XCTAssertEqual(h.identity, Levels.identity[keyPath: h.path])
        }
    }

    func testTheHistogramRendersThePictureEnteringTheStep() {
        var e = EnhanceSettings(contrast: 0.2, warmth: 0.4)
        e.levels = Levels(gamma: 1.5)
        e.curves.rgb = CurvePoints(sanitising: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)])
        let desired = RenderRequest(imageURL: URL(fileURLWithPath: "/x.CR2"),
                                    develop: DevelopSettings(stock: "generic", base: BaseSettings(mode: .anchor)),
                                    enhance: e, scale: .proxy)
        let levels = EnteringHistogram.request(.levels, from: desired)
        XCTAssertEqual(levels?.scale, .preview)
        XCTAssertEqual(levels?.enhance.contrast, 0.2)
        XCTAssertEqual(levels?.enhance.warmth, 0, "nothing after the step")
        XCTAssertTrue(levels?.enhance.levels.isIdentity ?? false, "and not the step itself")
        let curves = EnteringHistogram.request(.curves, from: desired)
        XCTAssertEqual(curves?.enhance.levels.gamma, 1.5, "Curves sees Levels")
        XCTAssertTrue(curves?.enhance.curves.isIdentity ?? false)
        XCTAssertNil(EnteringHistogram.request(.levels, from: nil))
    }

    /// The view wires each handle as an accessibility slider with its id and help.
    func testTheViewWiresEachHandle() throws {
        let s = try repoSource("Sources/FilmPositive/UI/Inspector/LevelsGroup.swift")
        XCTAssertTrue(s.contains("struct LevelsGroup: View"), "canary: read the right file")
        for needle in [".accessibilityAdjustableAction", ".accessibilityIdentifier(h.id)", ".help(h.help)",
                       "TapGesture(count: 2).onEnded { onSet(h, h.identity) }"] {
            XCTAssertTrue(s.contains(needle), "missing \(needle)")
        }
        let inspector = try repoSource("Sources/FilmPositive/UI/Inspector/InspectorView.swift")
        XCTAssertTrue(inspector.contains("if group == .colour { toneSections() }"), "Levels and Curves follow Color")
        XCTAssertEqual(inspector.components(separatedBy: "toneSections()").count - 1, 2,
                       "one call and the declaration, so they are drawn once")
    }
}
