import XCTest
@testable import FilmPositive
import FilmPositiveCore

/// The export sheet's two rows: a Format row over the six families, and a Quality row
/// under it for the three families that have more than one option.
///
/// The defaults are the key assertions here. Picking a family alone must select exactly
/// what the app wrote before the Quality row existed, or an ordinary export quietly changes.
final class ExportChoiceTests: XCTestCase {
    func testEveryFormatBelongsToExactlyOneFamilysOptions() {
        for format in ExportFormat.allCases {
            let owners = ExportFamily.allCases.filter { $0.options.contains(format) }
            XCTAssertEqual(owners, [format.family], "\(format) is owned by \(owners)")
        }
        let listed = ExportFamily.allCases.flatMap(\.options)
        XCTAssertEqual(Set(listed), Set(ExportFormat.allCases), "every format is reachable from some family")
        XCTAssertEqual(listed.count, ExportFormat.allCases.count, "and no format is listed twice")
    }

    func testTheFormatRowsOrder() {
        XCTAssertEqual(ExportFamily.allCases, [.tiff16, .png16, .heic, .avif, .jpeg, .jxl])
    }

    /// Smallest file first in every Quality row.
    func testTheQualityRowsOptionsAndOrder() {
        XCTAssertEqual(ExportFamily.tiff16.options, [.tiff16])
        XCTAssertEqual(ExportFamily.png16.options, [.png16])
        XCTAssertEqual(ExportFamily.heic.options, [.heic8, .heic])
        XCTAssertEqual(ExportFamily.avif.options, [.avif])
        XCTAssertEqual(ExportFamily.jpeg.options, [.jpegMedium, .jpeg, .jpegMaximum])
        XCTAssertEqual(ExportFamily.jxl.options, [.jxlSmall, .jxlFine, .jxlLossless])
    }

    /// Every format has a Quality row. Three have a choice in it, and the other three show
    /// their one depth greyed out.
    func testOnlyHeicJpegAndJxlHaveAChoiceInTheQualityRow() {
        let many = ExportFamily.allCases.filter { $0.options.count > 1 }
        XCTAssertEqual(many, [.heic, .jpeg, .jxl])
        XCTAssertEqual(ExportSheet.qualityName(.tiff16), "16-bit")
        XCTAssertEqual(ExportSheet.qualityName(.png16), "16-bit")
        XCTAssertEqual(ExportSheet.qualityName(.avif), "10-bit")
        XCTAssertEqual(ExportFamily.allCases.map(ExportSheet.name), ["TIFF", "PNG", "HEIC", "AVIF", "JPEG", "JPEG XL"])
    }

    /// The whole point of the defaults: changing the Format row changes no output that
    /// the app was not already writing.
    func testEachFamilyDefaultsToWhatShippedBefore() {
        XCTAssertEqual(ExportFamily.tiff16.default, .tiff16)
        XCTAssertEqual(ExportFamily.png16.default, .png16)
        XCTAssertEqual(ExportFamily.heic.default, .heic)
        XCTAssertEqual(ExportFamily.avif.default, .avif)
        XCTAssertEqual(ExportFamily.jpeg.default, .jpeg)
        XCTAssertEqual(ExportFamily.jxl.default, .jxlFine)
        XCTAssertEqual(ExportFormat.jpeg.lossyQuality, 0.92, "the JPEG default is the quality that shipped")
        for family in ExportFamily.allCases {
            XCTAssertTrue(family.options.contains(family.default), "\(family) default is one of its own options")
            XCTAssertEqual(family.default.family, family, "\(family) default belongs to it")
        }
    }

    /// A stored preference is the case name, so every name the app has ever written must
    /// still resolve (AppModel.Preferences.exportFormat).
    func testStoredPreferenceNamesStillResolve() {
        for name in ["tiff16", "png16", "heic", "avif", "jpeg", "jxlFine", "jxlSmall", "jxlLossless"] {
            XCTAssertNotNil(ExportFormat(rawValue: name), "stored pick \(name)")
        }
        XCTAssertEqual(ExportFormat(rawValue: "heic"), .heic)
        XCTAssertEqual(ExportFormat(rawValue: "jpeg"), .jpeg)
        XCTAssertEqual(ExportFormat(rawValue: "jxlFine"), .jxlFine)
        XCTAssertEqual(ExportFormat(rawValue: "jxlSmall"), .jxlSmall)
        XCTAssertEqual(ExportFormat(rawValue: "jxlLossless"), .jxlLossless)
    }

    /// Two qualities of one format share an extension and a type, which is what makes the
    /// naming rule ("an earlier export of the same frame and format is replaced") true.
    func testAFamilysOptionsShareTheContainer() {
        for family in ExportFamily.allCases {
            for option in family.options {
                XCTAssertEqual(option.fileExtension, family.fileExtension, "\(option) extension")
                XCTAssertEqual(option.utType, family.utType, "\(option) type")
            }
        }
    }

    func testEveryRowHasALabelAndABlurb() {
        for family in ExportFamily.allCases {
            XCTAssertFalse(ExportSheet.name(family).isEmpty, "\(family) label")
            XCTAssertFalse(ExportSheet.blurb(family).isEmpty, "\(family) blurb")
        }
        for format in ExportFormat.allCases {
            XCTAssertFalse(ExportSheet.qualityName(format).isEmpty, "\(format) quality label")
            XCTAssertFalse(ExportSheet.qualityBlurb(format).isEmpty, "\(format) quality blurb")
        }
        // No em-dash anywhere in the sheet's copy.
        let copy = ExportFamily.allCases.map(ExportSheet.blurb) + ExportFormat.allCases.map(ExportSheet.qualityBlurb)
        for line in copy { XCTAssertFalse(line.contains("\u{2014}"), line) }
    }

    /// Labels within one Quality row are distinct, or the menu shows two identical rows.
    func testQualityLabelsAreDistinctWithinAFamily() {
        for family in ExportFamily.allCases where family.options.count > 1 {
            let labels = family.options.map(ExportSheet.qualityName)
            XCTAssertEqual(Set(labels).count, labels.count, "\(family) labels \(labels)")
        }
    }
}
