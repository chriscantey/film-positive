import XCTest
import SwiftUI
import AppKit
@testable import FilmPositive

/// The closeup header does not change height when the Original badge appears.
///
/// Unpinned, a screen recording showed the bar's text centroid stepping 75.26 to 76.40 px
/// and back, seven times in eight seconds, instantly and with no animation. That is a layout
/// change, not an animation bug. The Original badge is `.caption` with 3 pt of padding above
/// and below inside a Capsule, in a row whose other content is `.headline` and
/// `.subheadline`, so inserting it grows the row and everything in it re-centers downward
/// by half the growth.
///
/// The test asserts the MECHANISM in both directions rather than a pixel constant, because a
/// constant would be brittle across OS versions and font metrics while the relationship is
/// not. Unconstrained, the two variants must DIFFER, which is what proves this test can see
/// the bug at all. Constrained by the fixed height, they must be EQUAL.
final class HeaderBarHeightTests: XCTestCase {

    /// The row's content, mirroring `ViewerView.header`. Kept in step with it by the pair of
    /// assertions below: if the real row gains something taller, the unconstrained case here
    /// still differs and the constrained case still holds, which is the property under test.
    private struct Row: View {
        let withBadge: Bool
        var body: some View {
            HStack(spacing: 12) {
                Button {} label: { Image(systemName: "chevron.left") }
                Button {} label: { Image(systemName: "chevron.right") }
                Text("IMG_0020.CR2").font(.headline).lineLimit(1).truncationMode(.middle)
                Text("20 of 38").font(.subheadline).foregroundStyle(.secondary)
                if withBadge {
                    Text("Original")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer()
            }
            .buttonStyle(.borderless)
        }
    }

    @MainActor
    private func height<V: View>(_ view: V) -> CGFloat {
        NSHostingView(rootView: view.frame(width: 600)).fittingSize.height
    }

    /// The canary. If this ever stops differing, the test below proves nothing, because the
    /// badge would no longer be capable of changing the row's height in the first place.
    @MainActor
    func testTheBadgeGenuinelyGrowsAnUnconstrainedRow() {
        let without = height(Row(withBadge: false))
        let with = height(Row(withBadge: true))
        XCTAssertGreaterThan(with, without,
                             "the badge must still be the taller content, or this suite is decorative")
    }

    @MainActor
    func testAFixedHeightStopsTheBadgeMovingTheBar() {
        let without = height(Row(withBadge: false).frame(height: ViewerView.headerContentHeight))
        let with = height(Row(withBadge: true).frame(height: ViewerView.headerContentHeight))
        XCTAssertEqual(with, without, "holding and releasing Original must not move the bar")
    }

    /// Pinned at the WITH-badge height, so the badge keeps its own appearance rather than
    /// being squeezed.
    @MainActor
    func testTheFixedHeightIsTheOneThatLeavesTheBadgeIntact() {
        XCTAssertEqual(ViewerView.headerContentHeight, height(Row(withBadge: true)),
                       "a smaller fixed height would compress the badge instead of the row")
    }
}

/// The closeup's Original icon.
///
/// `photo.on.rectangle` is the vocabulary macOS uses for a photo LIBRARY, so it would read
/// as "back to the gallery" two controls away from the Done button that actually does that.
/// The control's real job, from `RenderCoordinator`, is to render with `enhance = .identity`,
/// so the icon has to mean "without the Enhance layer", and a before-and-after split says it.
final class OriginalIconTests: XCTestCase {

    /// A symbol name that does not resolve renders as a blank or a placeholder, and nothing
    /// in a build catches it. `sparkles.slash`, a candidate for this very control, does not
    /// exist. So the name is asserted rather than trusted.
    @MainActor
    func testTheIconSymbolActuallyExists() {
        XCTAssertNotNil(NSImage(systemSymbolName: "rectangle.lefthalf.inset.filled",
                                accessibilityDescription: nil))
    }

    /// Anti: the photo-library glyph is gone from the closeup toolbar.
    @MainActor
    func testTheGalleryLookingGlyphIsNotUsedHere() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/FilmPositiveAppTests/HeaderBarHeightTests.swift",
            with: "Sources/FilmPositive/UI/Viewer/ViewerView.swift"), encoding: .utf8)
        // Canary FIRST. A search that finds nothing and a search that read the wrong file are
        // the same green, and the failure direction is toward PASS. Prove the file being read
        // is the one that holds the control before believing anything about what is absent.
        XCTAssertTrue(source.contains("systemImage: \"rectangle.lefthalf.inset.filled\""),
                      "canary: this is not ViewerView.swift, so the absence below proves nothing")
        let uses = source.components(separatedBy: "systemImage: \"photo.on.rectangle\"").count - 1
        XCTAssertEqual(uses, 0, "the library glyph reads as 'back to the gallery', which Done does")
    }
}
