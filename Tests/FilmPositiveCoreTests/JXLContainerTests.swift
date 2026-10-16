import XCTest
@testable import FilmPositiveCore

/// The JXL box walker, tested at offsets that are not multiples of four.
///
/// `JXLContainer.metadata` must not read box sizes with `load(as: UInt32.self)` on a Data
/// slice starting at the box offset. Box offsets are arbitrary, `load` traps on a
/// misaligned address, and whether any given file trips it depends on where Data allocated
/// and on the sizes of the boxes before it. The trap, "load from misaligned raw pointer",
/// is silent until it kills the whole suite mid-run.
///
/// These build containers whose later box headers land on deliberately awkward offsets.
final class JXLContainerTests: XCTestCase {
    /// A minimal ISOBMFF-style box: 4-byte big-endian size, 4-byte type, payload.
    static func box(_ type: String, _ payload: Data) -> Data {
        var d = Data()
        let size = UInt32(8 + payload.count)
        d.append(UInt8(truncatingIfNeeded: size >> 24))
        d.append(UInt8(truncatingIfNeeded: size >> 16))
        d.append(UInt8(truncatingIfNeeded: size >> 8))
        d.append(UInt8(truncatingIfNeeded: size))
        d.append(contentsOf: Array(type.utf8))
        d.append(payload)
        return d
    }

    /// The signature box every JXL container opens with, so `metadata` accepts the file.
    static var signature: Data { box("JXL ", Data([0x0D, 0x0A, 0x87, 0x0A])) }

    func write(_ data: Data) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxl-\(UUID().uuidString).jxl")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Every payload length from 0 to 15 puts the following box header at a different
    /// offset modulo four, so one of these is misaligned for a UInt32 load whatever the
    /// base address happens to be.
    func testBoxHeadersAtEveryAlignmentAreRead() throws {
        for pad in 0..<16 {
            var file = Self.signature
            file += Self.box("padd", Data(repeating: 0x41, count: pad))
            file += Self.box("xml ", Data("<x>hello</x>".utf8))
            let url = try write(file)
            let m = JXLContainer.metadata(of: url)
            XCTAssertNotNil(m, "pad \(pad): container was rejected")
            XCTAssertEqual(m?.xmp, Data("<x>hello</x>".utf8), "pad \(pad): xml box not read")
        }
    }

    /// The 64-bit extended size form, also read at an awkward offset.
    func testExtendedSizeBoxIsRead() throws {
        let payload = Data("<y>big</y>".utf8)
        var extended = Data([0, 0, 0, 1])                 // size 1 means "look at the 64-bit field"
        extended.append(contentsOf: Array("xml ".utf8))
        let total = UInt64(16 + payload.count)
        for shift in stride(from: 56, through: 0, by: -8) {
            extended.append(UInt8(truncatingIfNeeded: total >> UInt64(shift)))
        }
        extended.append(payload)

        var file = Self.signature
        file += Self.box("padd", Data(repeating: 0x42, count: 3))   // pushes the next header off four
        file += extended
        let url = try write(file)
        XCTAssertEqual(JXLContainer.metadata(of: url)?.xmp, payload)
    }

    func testATruncatedBoxStopsRatherThanReadingPastTheEnd() throws {
        var file = Self.signature
        file += Data([0x00, 0x00, 0xFF, 0xFF])            // a size far past the end of the file
        file += Data("xml ".utf8)
        file += Data("short".utf8)
        let url = try write(file)
        // The walker should stop at the bad box and return what it had, not crash or hang.
        XCTAssertNil(JXLContainer.metadata(of: url)?.xmp)
    }

    func testSomethingThatIsNotAJXLFileIsRefused() throws {
        let url = try write(Data(repeating: 0x00, count: 64))
        XCTAssertNil(JXLContainer.metadata(of: url))
    }
}
