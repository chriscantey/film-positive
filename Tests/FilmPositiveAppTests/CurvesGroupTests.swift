import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The Curves editor's hit rules as pure functions, and the view wired to them.
final class CurvesGroupTests: XCTestCase {
    static func p(_ x: Double, _ y: Double) -> CurvePoint { CurvePoint(x: x, y: y) }
    func p(_ x: Double, _ y: Double) -> CurvePoint { Self.p(x, y) }
    static let three = [p(0, 0), p(0.5, 0.6), p(1, 1)]

    func testAClickNearAPointPicksItUpAndElsewhereNothing() {
        XCTAssertEqual(CurveEditing.hit(Self.three, at: Self.p(0.51, 0.59), radius: 0.03), 1)
        XCTAssertEqual(CurveEditing.hit(Self.three, at: Self.p(0.01, 0.02), radius: 0.03), 0, "an end point is picked up too")
        XCTAssertNil(CurveEditing.hit(Self.three, at: Self.p(0.3, 0.8), radius: 0.03))
        // The nearer of two wins.
        let close = [p(0, 0), p(0.40, 0.4), p(0.44, 0.44), p(1, 1)]
        XCTAssertEqual(CurveEditing.hit(close, at: Self.p(0.43, 0.43), radius: 0.05), 2)
    }

    func testAddPutsThePointInOrderWhereTheClickLanded() throws {
        let added = try XCTUnwrap(CurveEditing.add(Self.three, at: Self.p(0.25, 0.4)))
        XCTAssertEqual(added.index, 1)
        XCTAssertEqual(added.points.map(\.x), [0, 0.25, 0.5, 1])
        XCTAssertEqual(added.points[1].y, 0.4)
        XCTAssertNil(CurveEditing.add(Self.three, at: Self.p(0.505, 0.2)), "not on top of a point's x")
        let clamped = try XCTUnwrap(CurveEditing.add(Self.three, at: Self.p(0.75, 1.4)))
        XCTAssertEqual(clamped.points[clamped.index].y, 1, "y held to 0...1")
        // No more than the most the file holds.
        var full = [p(0, 0)]
        for i in 1..<(CurvePoints.maxPoints - 1) { full.append(p(Double(i) / Double(CurvePoints.maxPoints), 0.5)) }
        full.append(p(1, 1))
        XCTAssertEqual(full.count, CurvePoints.maxPoints)
        XCTAssertNil(CurveEditing.add(full, at: Self.p(0.97, 0.5)), "at most CurvePoints.maxPoints")
    }

    func testAMoveIsBoundedByItsNeighbors() {
        let moved = CurveEditing.move(Self.three, index: 1, to: Self.p(0.99, 1.3))
        XCTAssertEqual(moved[1].x, 0.99, accuracy: 1e-12, "stops minGap short of the right neighbor")
        XCTAssertEqual(moved[1].y, 1)
        XCTAssertEqual(CurveEditing.move(Self.three, index: 1, to: Self.p(-0.2, -1))[1].x, 0.01, accuracy: 1e-12)
        XCTAssertEqual(CurveEditing.move(Self.three, index: 1, to: Self.p(-0.2, -1))[1].y, 0)
        // The end points move, inside their edge and their one neighbor.
        let first = CurveEditing.move(Self.three, index: 0, to: Self.p(0.8, 0.3))
        XCTAssertEqual(first[0].x, 0.49, accuracy: 1e-12)
        XCTAssertEqual(first[0].y, 0.3)
        let last = CurveEditing.move(Self.three, index: 2, to: Self.p(1.5, 0.7))
        XCTAssertEqual(last[2].x, 1)
        XCTAssertEqual(last[2].y, 0.7)
        XCTAssertEqual(CurveEditing.move(Self.three, index: 7, to: Self.p(0.5, 0.5)), Self.three, "no such point, no change")
        // Order holds whatever the pointer does, so the sanitiser never drops a point.
        let wild = CurveEditing.move(Self.three, index: 1, to: Self.p(2, 0.5))
        XCTAssertEqual(CurvePoints(sanitising: wild).points.count, 3)
    }

    func testOnlyInteriorPointsCanBeRemoved() {
        XCTAssertNil(CurveEditing.remove(Self.three, index: 0), "the first end point stays")
        XCTAssertNil(CurveEditing.remove(Self.three, index: 2), "and the last")
        XCTAssertEqual(CurveEditing.remove(Self.three, index: 1), [Self.p(0, 0), Self.p(1, 1)])
        XCTAssertNil(CurveEditing.remove(Self.three, index: 5))
    }

    func testChannelsAndTheirDots() {
        XCTAssertEqual(CurveChannel.allCases.map(\.title), ["All", "Red", "Green", "Blue"])
        XCTAssertEqual(CurveChannel.allCases.map(\.histogramChannel), [nil, 0, 1, 2])
        func sidecar(_ c: Curves) -> Sidecar {
            var s = Sidecar(source: SidecarSource(name: "a.CR2", size: 1, mtime: Date(), fingerprint: "x"))
            var e = EnhanceSettings(); e.curves = c; s.enhance = e
            return s
        }
        let lifted = CurvePoints(sanitising: Self.three)
        let summary = SelectionSummary([sidecar(Curves(red: lifted))])
        XCTAssertFalse(CurvesGroup.inUse(summary, .all))
        XCTAssertTrue(CurvesGroup.inUse(summary, .red), "a dot on Red")
        let mixed = SelectionSummary([sidecar(Curves(green: lifted)), sidecar(Curves())])
        XCTAssertTrue(CurvesGroup.inUse(mixed, .green), "a channel some frame moved shows its dot")
        XCTAssertEqual(CurvesGroup.pointCount(3), "3 points")
        XCTAssertEqual(CurvesGroup.pointCount(1), "1 point")
    }

    func testTheViewWiresTheEditor() throws {
        let s = try repoSource("Sources/FilmPositive/UI/Inspector/CurvesGroup.swift")
        XCTAssertTrue(s.contains("struct CurvesGroup: View"), "canary: read the right file")
        for needle in [".accessibilityIdentifier(\"curves.editor\")", ".accessibilityIdentifier(\"curves.channel\")",
                       ".accessibilityValue(Self.pointCount(pts.count))", "SpatialTapGesture(count: 2)",
                       "CurveEditing.add(current, at: start)", "CurveEditing.move(d.points, index: d.index, to: to)"] {
            XCTAssertTrue(s.contains(needle), "missing \(needle)")
        }
        let inspector = try repoSource("Sources/FilmPositive/UI/Inspector/InspectorView.swift")
        let levels = try XCTUnwrap(inspector.range(of: "ToneGroupSection(fold: .levels"))
        let curves = try XCTUnwrap(inspector.range(of: "ToneGroupSection(fold: .curves"))
        XCTAssertLessThan(levels.lowerBound, curves.lowerBound, "Curves follows Levels")
    }
}
