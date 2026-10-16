import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The Size row reads the capture app's film size name beside its id.
final class FilmSizeLabelTests: XCTestCase {
    typealias S = MetadataSection

    private func text(_ frames: [(String?, String?)]) -> String {
        S.filmSizeText(SharedValue(frames.map { S.filmSizeLabel(id: $0.0, name: $0.1) }))
    }

    func testTheNewCaptureSizesReadByName() {
        XCTAssertEqual(text([("13", nil)]), "120 6x4.5")
        XCTAssertEqual(text([("14", nil)]), "120 6x7")
        XCTAssertEqual(text([("15", nil)]), "110")
        XCTAssertEqual(text([("99", nil)]), "Size 99", "an id nothing here knows keeps its number")
    }

    func testTheCaptureAppsNameWins() {
        XCTAssertEqual(text([("13", "120 6x4.5")]), "120 6x4.5")
        XCTAssertEqual(text([("99", "127 roll")]), "127 roll", "a name reads even when the id is unknown here")
        XCTAssertEqual(text([(nil, "127 roll")]), "127 roll", "an id-less name is the label as given")
        XCTAssertEqual(text([(nil, "  127 roll ")]), "127 roll")
        XCTAssertEqual(text([(nil, "   ")]), "Not recorded", "a blank name is no name")
        XCTAssertEqual(text([("1", nil)]), "Not recorded", "the unknown id is not a size")
    }

    func testSelectionsCompareWhatTheyShow() {
        XCTAssertEqual(text([("13", "120 6x4.5"), ("13", nil)]), "120 6x4.5", "same size, one frame without a name")
        XCTAssertEqual(text([("13", nil), ("14", nil)]), "Multiple")
        XCTAssertEqual(text([(nil, "127 roll"), (nil, "127 roll")]), "127 roll")
    }

    func testTheSidecarNameReachesTheSummary() {
        let capture = CaptureInfo(filmSizeID: "14", filmSizeName: "120 6x7")
        XCTAssertEqual(S.filmSizeLabel(id: capture.filmSizeID, name: capture.filmSizeName), "120 6x7")
    }

    /// Anti: the label-only sizes never join crop detection.
    func testLabelOnlySizesStayOutOfDetection() {
        for id in FilmSize.labelOnlyNames.keys {
            XCTAssertNil(FilmSize.seedCatalog.first { $0.id == id }, "id \(id) must not enter the detection catalogue")
        }
    }
}
