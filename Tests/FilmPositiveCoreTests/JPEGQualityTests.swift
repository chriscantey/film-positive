import XCTest
import Foundation
import FilmSidecar
@testable import FilmPositiveCore

/// The JPEG Quality row, measured rather than assumed.
///
/// Two claims are worth a test here. The three JPEG steps must actually differ in size,
/// in the order the menu lists them, because the menu promises "smallest file first" and
/// a quality that ImageIO ignored would look identical to one it honored. And the middle
/// step must be byte-for-byte what a single-quality exporter writes at 0.92, so the row
/// changes no default output.
///
/// The measured sizes are printed, because any size claim in the Quality info texts has
/// to come from a measurement.
final class JPEGQualityTests: XCTestCase {
    let export = ExportTests()

    func testTheThreeJPEGStepsGrowInMenuOrder() throws {
        let f = try export.levelFrames()[0]
        let rendered = try export.developed(f)
        var sizes: [ExportFormat: Int] = [:]
        for format in ExportFamily.jpeg.options {
            let url = export.out("q-\(format.rawValue)", format)
            try export.exporter.write(rendered, to: url, format: format, colorSpace: .sRGB, metadata: try export.metadata(for: f))
            sizes[format] = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            XCTAssertEqual(try ExportReadback.read(url).bitsPerComponent, 8, "\(format) depth")
        }
        let medium = try XCTUnwrap(sizes[.jpegMedium]), high = try XCTUnwrap(sizes[.jpeg]), maximum = try XCTUnwrap(sizes[.jpegMaximum])
        print("JPEG sizes medium=\(medium) high=\(high) maximum=\(maximum)")
        print("JPEG ratios medium/high=\(String(format: "%.3f", Double(medium) / Double(high))) maximum/high=\(String(format: "%.3f", Double(maximum) / Double(high)))")
        XCTAssertLessThan(medium, high, "Medium is the smaller file")
        XCTAssertLessThan(high, maximum, "Maximum is the larger file")
    }

    /// The default output does not move: High is the same bytes a single-quality exporter
    /// writes at 0.92.
    func testHighIsByteIdenticalToWhatShippedBeforeTheQualityRow() throws {
        let f = try export.levelFrames()[0]
        let rendered = try export.developed(f)
        let metadata = try export.metadata(for: f)
        let new = export.out("q-high-new", .jpeg)
        try export.exporter.write(rendered, to: new, format: .jpeg, colorSpace: .sRGB, metadata: metadata)
        // The single-quality path: the exporter's own quality, with the case naming none of
        // its own.
        let old = Self.tmp.appendingPathComponent("q-high-old.jpg")
        try Exporter(lossyQuality: 0.92).write(rendered, to: old, format: .jpeg, colorSpace: .sRGB, metadata: metadata)
        XCTAssertEqual(try Data(contentsOf: new), try Data(contentsOf: old), "High is exactly today's JPEG")
    }

    /// An 8-bit HEIC is the 10-bit one with the depth stated, so it must read back at 8
    /// and be the smaller file. Reading back at 8 is the part that cannot be assumed:
    /// ImageIO picks 10-bit from a 16-bit source unless the depth is stated.
    func testHeic8IsEightBitAndSmallerThanHeic10() throws {
        let f = try export.levelFrames()[0]
        let rendered = try export.developed(f)
        var sizes: [ExportFormat: Int] = [:]
        for format in ExportFamily.heic.options {
            let url = export.out("q-\(format.rawValue)", format)
            try export.exporter.write(rendered, to: url, format: format, colorSpace: .sRGB, metadata: try export.metadata(for: f))
            sizes[format] = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            let back = try ExportReadback.read(url)
            XCTAssertEqual(back.bitsPerComponent, format.bitsPerComponent, "\(format) depth")
            XCTAssertEqual(back.width, rendered.width); XCTAssertEqual(back.height, rendered.height)
        }
        let eight = try XCTUnwrap(sizes[.heic8]), ten = try XCTUnwrap(sizes[.heic])
        print("HEIC sizes 8-bit=\(eight) 10-bit=\(ten)")
        XCTAssertLessThan(eight, ten, "the 8-bit HEIC is the smaller file")
    }

    static let tmp: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("fp-jpegq-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
}
