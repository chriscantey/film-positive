import XCTest
import Foundation
import FilmSidecar
@testable import FilmPositiveCore

/// JPEG XL through libjxl, read back through ImageIO (Apple's decoder), 16-bit,
/// color space and XMP intact, the two presets ordered as the latitude test measured.
final class JXLExportTests: XCTestCase {
    let export = ExportTests()

    func testLibraryIsThePinnedRelease() {
        XCTAssertTrue(JXLEncoder.libraryVersion.hasPrefix("0.12."), JXLEncoder.libraryVersion)
    }

    func testArchiveAndShareReadBackSixteenBitThroughImageIO() throws {
        let f = try export.levelFrames()[0]
        let rendered = try export.developed(f)
        var sizes: [ExportFormat: Int] = [:]
        var errors: [ExportFormat: Double] = [:]
        for format in [ExportFormat.jxlFine, .jxlSmall, .jxlLossless] {
            let url = export.out("jxl-\(format.rawValue)", format)
            try export.exporter.write(rendered, to: url, format: format, colorSpace: .sRGB, metadata: try export.metadata(for: f))
            let bytes = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            sizes[format] = bytes
            let back = try ExportReadback.read(url)
            XCTAssertEqual(back.width, rendered.width); XCTAssertEqual(back.height, rendered.height)
            XCTAssertGreaterThanOrEqual(back.bitsPerComponent, 16, "\(format) depth \(back.bitsPerComponent)")
            var sum = 0.0
            for i in stride(from: 0, to: rendered.pixels.count, by: 5) { sum += abs(Double(back.pixelsRGB[i]) - Double(rendered.pixels[i])) }
            let mean = sum / Double(rendered.pixels.count / 5) / 257
            errors[format] = mean
            print("\(format.rawValue): \(bytes / 1000) kB, mean |d| \(String(format: "%.2f", mean))/255, depth \(back.bitsPerComponent)")
            for n in back.distinctLevels { XCTAssertGreaterThan(n, 1024, "\(format) real 16-bit content, levels \(back.distinctLevels)") }
        }
        XCTAssertLessThan(sizes[.jxlSmall]!, sizes[.jxlFine]!, "small is the smaller file")
        XCTAssertGreaterThan(sizes[.jxlLossless]!, sizes[.jxlFine]!, "lossless is the largest")
        XCTAssertEqual(errors[.jxlLossless]!, 0, accuracy: 1e-9, "lossless is exact")
        XCTAssertLessThan(errors[.jxlFine]!, errors[.jxlSmall]!, "fine is the closer file")
        XCTAssertLessThan(errors[.jxlFine]!, 1.5, "fine near lossless in 8-bit units")
    }

    func testColourSpaceAndMetadataSurvive() throws {
        let f = try export.levelFrames()[0]
        let rendered = try export.developed(f)
        let capture = CaptureInfo(camera: "Leica M6", cameraMake: "Leica", film: "Kodak Gold 200", filmMaker: "Kodak")
        for space in ExportColorSpace.allCases {
            let url = export.out("jxl-\(space.rawValue)", .jxlSmall)
            try export.exporter.write(rendered, to: url, format: .jxlSmall, colorSpace: space, metadata: try export.metadata(for: f, capture: capture))
            let back = try ExportReadback.read(url)
            print("jxl \(space.rawValue): profile \(back.profileName ?? "none"), date \(back.dateTimeOriginal ?? "none"), make \(back.make ?? "none"), model \(back.model ?? "none")")
            XCTAssertNotNil(back.profileName, "\(space) colour space reaches ImageIO")
            let packet = try XCTUnwrap(back.xmpPacket, "XMP box read by ImageIO")
            let text = String(decoding: packet, as: UTF8.self)
            XCTAssertTrue(text.contains("Kodak Gold 200"), "AnalogExif:Film in the packet")
            XCTAssertTrue(text.contains(ExportMetadata.filmPositiveNamespace), "FilmPositive namespace in the packet")
            XCTAssertTrue(text.contains("Leica M6"), "camera in the packet")
        }
        let srgb = try ExportReadback.read(export.out("jxl-sRGB", .jxlSmall)).profileName ?? ""
        let p3 = try ExportReadback.read(export.out("jxl-displayP3", .jxlSmall)).profileName ?? ""
        XCTAssertNotEqual(srgb, p3, "sRGB and P3 files are tagged differently")
    }
}
