import XCTest
@testable import FilmPositive

/// A grown range holds until a click away or a frame change.
final class RangeHoldTests: XCTestCase {

    func testAtRestTheSpanIsTheNormalRangeWithNoTicks() {
        let h = RangeHold()
        XCTAssertEqual(h.span(for: 0), -1...1)
        XCTAssertEqual(h.span(for: 0.4), -1...1)
        XCTAssertEqual(h.span(for: -1), -1...1)
        XCTAssertFalse(h.isHolding)
        XCTAssertEqual(h.ticks(for: 0.4), [])
    }

    func testATypedValuePastTheRangeGrowsTheSpanSymmetrically() {
        var h = RangeHold()
        h.edited(to: 2.5)
        XCTAssertTrue(h.isHolding)
        XCTAssertEqual(h.span(for: 2.5), -3...3)
        h = RangeHold()
        h.edited(to: -1.2)
        XCTAssertEqual(h.span(for: -1.2), -2...2, "negative growth is symmetric too")
    }

    func testTheGrownSpanHoldsWhenTheValueComesBackInside() {
        var h = RangeHold()
        h.edited(to: 2.5)
        h.edited(to: 0.4)
        XCTAssertEqual(h.span(for: 0.4), -3...3, "dragged back inside, the span stays grown")
        h.edited(to: -0.9)
        XCTAssertEqual(h.span(for: -0.9), -3...3)
        XCTAssertEqual(h.ticks(for: 0.4), [-1, 1], "the old limits are marked while grown")
    }

    func testTheHoldNeverShrinksWhileHeld() {
        var h = RangeHold()
        h.edited(to: 5.2)
        h.edited(to: 1.5)
        XCTAssertEqual(h.span(for: 1.5), -6...6)
    }

    func testAnEditInsideTheRangeDoesNotHold() {
        var h = RangeHold()
        h.edited(to: 0.7)
        h.edited(to: -1)
        XCTAssertFalse(h.isHolding)
    }

    /// Click away and frame change are the same call: `release`.
    func testReleaseReturnsToTheNormalRange() {
        var h = RangeHold()
        h.edited(to: 2.5)
        h.edited(to: 0.4)
        h.release()
        XCTAssertFalse(h.isHolding)
        XCTAssertEqual(h.span(for: 0.4), -1...1)
        XCTAssertEqual(h.ticks(for: 0.4), [])
    }

    func testAfterReleaseTheSpanStillContainsAValueThatIsOutside() {
        var h = RangeHold()
        h.edited(to: 2.5)
        h.release()
        XCTAssertEqual(h.span(for: 2.5), -3...3, "a value outside keeps a span that contains it")
        XCTAssertEqual(h.ticks(for: 2.5), [-1, 1])
        XCTAssertEqual(h.span(for: -4.1), -5...5)
    }

    /// A value from elsewhere (another frame, Auto Enhance) is contained but never held.
    func testAValueThatWasNotEditedHereIsContainedButNotHeld() {
        let h = RangeHold()
        XCTAssertEqual(h.span(for: 1.8), -2...2)
        XCTAssertFalse(h.isHolding)
        XCTAssertEqual(h.span(for: 0.4), -1...1)
    }

    func testTheSpanIsAlwaysSymmetric() {
        var h = RangeHold()
        for v in [2.5, -3.7, 0.4, 1.01, -0.2, 7] {
            h.edited(to: v)
            let s = h.span(for: v)
            XCTAssertEqual(s.lowerBound, -s.upperBound, "asymmetric at \(v)")
            XCTAssertTrue(s.contains(v))
        }
    }

    func testANonFiniteValueNeverGrowsTheHold() {
        var h = RangeHold()
        h.edited(to: .infinity)
        h.edited(to: .nan)
        XCTAssertFalse(h.isHolding)
    }
}
