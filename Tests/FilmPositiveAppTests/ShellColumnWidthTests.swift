import XCTest
import AppKit
@testable import FilmPositive

/// Side columns never clip: both sidebars have minimum widths, the center column compresses,
/// and the window minimum equals the sum.
///
/// The window minimum and the three column minimums are one arithmetic claim. A disagreement
/// of 118 pt in the grid and 94 pt in the closeup showed as clipping. These assertions read
/// the constants out of `ShellLayout` itself, so the day somebody widens a column the
/// arithmetic fails here rather than on screen.
///
/// What they cannot prove: that `NavigationSplitView` honors the numbers. That is a screen
/// measurement, taken through the Accessibility tree at the window's minimum, and the
/// reading is written into `ShellLayout`'s own comment.
final class ShellColumnWidthTests: XCTestCase {

    func testWindowMinimumEqualsTheSumOfTheColumns() {
        let sum = ShellLayout.sidebarMin
            + ShellLayout.contentMin
            + ShellLayout.inspectorMin
            + ShellLayout.dividerWidth * ShellLayout.dividerCount
            + ShellLayout.splitInset
        XCTAssertEqual(ShellLayout.windowMinWidth, sum, accuracy: 0.001,
                       "the window minimum is the sum of the columns, the dividers and the split inset")
    }

    /// The failure this catches: a window minimum LARGER than the
    /// sum hides the problem (there is slack to absorb), and a window minimum SMALLER than
    /// the sum guarantees a clip, because the split view overflows rather than compressing.
    /// Only equality is correct, and the test above is the whole of it. This one states the
    /// direction so the intent survives a refactor of the arithmetic.
    func testWindowMinimumIsNeverBelowTheSum() {
        let columnsOnly = ShellLayout.sidebarMin + ShellLayout.contentMin + ShellLayout.inspectorMin
        XCTAssertGreaterThanOrEqual(ShellLayout.windowMinWidth, columnsOnly,
                                    "a window minimum under the three columns is a guaranteed clip")
    }

    /// Two dividers for three columns. Stated so that adding a fourth column has to come
    /// back here and say what it did to the count.
    func testDividerCountMatchesThreeColumns() {
        XCTAssertEqual(ShellLayout.dividerCount, 2, "three columns have two dividers between them")
    }

    /// A column's ideal below its minimum is incoherent, and the layout resolves it silently
    /// by ignoring one of them. Assert each pair instead.
    func testEveryIdealIsAtLeastItsMinimum() {
        XCTAssertGreaterThanOrEqual(ShellLayout.sidebarIdeal, ShellLayout.sidebarMin)
        XCTAssertGreaterThanOrEqual(ShellLayout.contentIdeal, ShellLayout.contentMin)
        XCTAssertGreaterThanOrEqual(ShellLayout.inspectorIdeal, ShellLayout.inspectorMin)
        XCTAssertGreaterThanOrEqual(ShellLayout.sidebarMax, ShellLayout.sidebarIdeal)
        XCTAssertGreaterThanOrEqual(ShellLayout.inspectorMax, ShellLayout.inspectorIdeal)
    }

    /// The sidebar rests at its ideal and does not compress toward a smaller stated minimum,
    /// measured at 240 pt of content in a 248 pt column at every window width. So a sidebar
    /// minimum below its ideal is a number the layout will not honor, and every point of the
    /// gap is a point the window is short.
    func testSidebarMinimumIsItsRestingWidth() {
        XCTAssertEqual(ShellLayout.sidebarMin, ShellLayout.sidebarIdeal, accuracy: 0.001,
                       "the sidebar does not compress below its ideal, so that IS its minimum")
    }

    /// THE WIDEST ONE-LINE ROW SETS THE INSPECTOR MINIMUM, and that row is the green color
    /// axis.
    ///
    /// The rule is that a row is one line and the column follows the row. This is that rule
    /// as an assertion, pinned to a number measured on screen rather than to one derived
    /// here: sweeping the column found the green label wrapping at 355 pt and under, and
    /// landing on one line at 360 and over.
    ///
    /// The IDEAL is asserted too. A default width of 340 sits inside the wrapping band, so
    /// the wrapped row is the ordinary appearance on first open and not something you have
    /// to shrink the window to find. A minimum that holds the row while the ideal does not is
    /// a fix nobody ever sees.
    func testTheInspectorWidthsHoldTheWidestAxisLabelOnOneLine() {
        // Measured, not modeled. A Form's label column is an internal, so this number comes
        // from an Accessibility sweep of the running app.
        let measuredOneLine: CGFloat = 360
        XCTAssertGreaterThanOrEqual(ShellLayout.inspectorMin, measuredOneLine,
                                    "the green axis label wraps to two lines below this width")
        XCTAssertGreaterThanOrEqual(ShellLayout.inspectorIdeal, measuredOneLine,
                                    "the DEFAULT width wraps it, which is the case a user meets")
    }

    /// And that measurement is about the right row. If a rename ever makes some other label
    /// the widest, this fails and the number above has to be re-measured rather than
    /// silently protecting the wrong string.
    func testTheGreenAxisLabelIsStillTheWidestOneInTheInspector() {
        let font = NSFont.preferredFont(forTextStyle: .body)
        func width(_ s: String) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font]).width
        }
        let green = width(ColourAxis.green.label)
        XCTAssertGreaterThan(green, width(ColourAxis.warm.label),
                             "the warm axis is now the wider label, so re-measure the minimum")
        for other in ["Stock", PositiveNames.autoColor, PositiveNames.base, "Tone", "Exposure", "Highlights",
                      "Brightness", "Noise Reduction"] {
            XCTAssertGreaterThan(green, width(other),
                                 other + " is wider than the label the minimum was measured for")
        }
    }

    /// The center column is the one that has to absorb a resize, so it must have the most
    /// room to give. If it were ever the narrowest column, the compression would land on a
    /// side column and the clip would come back.
    func testCenterColumnHasTheMostRoomToGive() {
        let slack = ShellLayout.contentIdeal - ShellLayout.contentMin
        XCTAssertGreaterThan(slack, ShellLayout.sidebarMax - ShellLayout.sidebarMin,
                             "the centre column compresses, so it carries the slack")
        XCTAssertGreaterThan(slack, ShellLayout.inspectorIdeal - ShellLayout.inspectorMin)
    }
}
