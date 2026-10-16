import XCTest
@testable import FilmPositive

/// The gallery's pill shows the positive count, so the window subtitle is the selection
/// alone.
final class GallerySubtitleTests: XCTestCase {
    func testTheSubtitleIsTheSelectionAlone() {
        XCTAssertEqual(GridView.subtitle(frames: 36, selected: 0), "", "nothing selected, nothing said")
        XCTAssertEqual(GridView.subtitle(frames: 36, selected: 1), "1 selected")
        XCTAssertEqual(GridView.subtitle(frames: 36, selected: 12), "12 selected")
        XCTAssertEqual(GridView.subtitle(frames: 0, selected: 0), "No raw files")
    }

    /// Anti: the count never comes back into the subtitle.
    func testTheSubtitleNeverCarriesThePositiveCount() {
        for selected in [0, 3] {
            XCTAssertFalse(GridView.subtitle(frames: 36, selected: selected).contains("positive"))
            XCTAssertFalse(GridView.subtitle(frames: 36, selected: selected).contains("of 36"))
        }
    }
}
