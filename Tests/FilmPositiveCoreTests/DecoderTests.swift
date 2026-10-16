import XCTest
@testable import FilmPositiveCore

/// The LibRaw decode, as properties of the decode itself.
///
/// What a decode has to be for everything downstream to mean anything: the same bytes every
/// time, the dimensions the camera actually produced, unity white balance with no color
/// matrix (so the film's own mask is still in the numbers), and a proxy that is the same
/// picture at half the size. None of that needs a file somebody decoded last week; the
/// frame in front of us either has these properties or it does not.
///
/// Skips cleanly when the fixtures are absent, so the pure contract suites still run
/// anywhere.
final class DecoderTests: XCTestCase {
    let fixtures = FixtureFrames()

    /// The Canon EOS 7D's imaging area is 5184 x 3456 (Canon's own specification, 17.9 MP).
    /// LibRaw hands back that area plus a few masked columns and rows, so the assertion is
    /// a band around the published figure rather than a number copied off one decode: what
    /// would break it is a decoder that started cropping, rotating or scaling.
    private let sensorWidth = 5184.0, sensorHeight = 3456.0

    func testTheDecodeHasTheCamerasOwnDimensions() throws {
        let f = try FixtureFrames.first()
        let d = try fixtures.decoded(f)
        print("decode \(f.name): \(d.width)x\(d.height), LibRaw \(RawDecoder.librawVersion)")
        XCTAssertTrue(RawDecoder.librawVersion.hasPrefix("0.21.4"), "pinned LibRaw version, got \(RawDecoder.librawVersion)")
        XCTAssertEqual(Double(d.width), sensorWidth, accuracy: sensorWidth * 0.02, "width against the 7D's imaging area")
        XCTAssertEqual(Double(d.height), sensorHeight, accuracy: sensorHeight * 0.02, "height against the 7D's imaging area")
        XCTAssertGreaterThan(d.width, d.height, "landscape, as the camera wrote it")
        XCTAssertEqual(d.pixels.count, d.width * d.height * 3, "three interleaved channels, one per pixel")
    }

    /// The histogram has to be a photograph: thousands of distinct values, reaching into
    /// both ends, and most of the frame NOT sitting at the sensor ceiling.
    ///
    /// The clipping bound is stated as "most of the frame", not as a measured percentage,
    /// on purpose. A copy-rig frame legitimately clips wherever bare backlight reaches the
    /// sensor around the film, so a tight bound would be a fact about how these six were
    /// framed rather than about the decoder. The exact fraction is printed on every run,
    /// so a decoder change that started saturating is visible in the log as well as in the
    /// assertion.
    func testTheDecodeIsAPictureAndNotClippedAcrossTheFrame() throws {
        for f in try FixtureFrames.all() {
            let d = try fixtures.decoded(f)
            var atCeiling = 0
            var seen = Set<UInt16>()
            var lo = UInt16.max, hi = UInt16.min
            // Every 37th sample: 1.5 million of them, enough to characterise a histogram
            // without walking 54 million.
            for i in stride(from: 0, to: d.pixels.count, by: 37) {
                let v = d.pixels[i]
                if v >= 65_000 { atCeiling += 1 }
                if seen.count < 5_000 { seen.insert(v) }
                lo = min(lo, v); hi = max(hi, v)
            }
            let sampled = d.pixels.count / 37
            let clipped = Double(atCeiling) / Double(sampled)
            print(String(format: "%@: clipped %.2f%%, range %d...%d", f.name, clipped * 100, Int(lo), Int(hi)))
            XCTAssertLessThan(clipped, 0.5, "\(f.name): most of the frame must not be at the sensor ceiling")
            XCTAssertEqual(seen.count, 5_000, "\(f.name): thousands of distinct values, so it is not posterised")
            XCTAssertLessThan(Int(lo), 4_000, "\(f.name): the frame reaches down into the shadows")
            XCTAssertGreaterThan(Int(hi), 40_000, "\(f.name): and up into the highlights")
        }
    }

    /// The same file decodes to the same bytes every time. Determinism is what makes
    /// every other claim in this repo reproducible, and it is a property of the decoder
    /// alone, so it is asserted against a second decode rather than against a stored one.
    func testDecodingTwiceIsByteIdentical() throws {
        let f = try FixtureFrames.first()
        let a = try RawDecoder().decode(f.cr2)
        let b = try RawDecoder().decode(f.cr2)
        XCTAssertEqual(a.width, b.width); XCTAssertEqual(a.height, b.height)
        XCTAssertEqual(a.pixels, b.pixels, "two decodes of one file must be byte-identical")
    }

    /// The proxy is the same picture at half the dimensions, and at the same exposure.
    /// Unity white balance and no color matrix on both, so the mean agrees. A proxy that
    /// silently applied a different pipeline would show up here rather than as a color
    /// shift between the grid and the export.
    func testHalfSizeProxyIsTheSamePictureAtHalfTheDimensions() throws {
        let f = try FixtureFrames.first()
        let full = try fixtures.decoded(f)
        let half = try RawDecoder(halfSize: true).decode(f.cr2)
        XCTAssertEqual(half.width, full.width / 2)
        XCTAssertEqual(half.height, full.height / 2)
        func mean(_ f: DecodedFrame) -> Double { Double(f.pixels.reduce(0) { $0 + UInt64($1) }) / Double(f.pixels.count) }
        XCTAssertEqual(mean(half), mean(full), accuracy: mean(full) * 0.01)
    }

    /// The decode carries no white balance and no color matrix, which is what lets a film
    /// profile mean anything: every shipped coefficient was measured in this space. A
    /// negative's orange mask therefore has to still be in the numbers, with red the lowest
    /// channel by a wide margin on every fixture.
    func testTheDecodeIsCameraSpaceWithTheMaskIntact() throws {
        for f in try FixtureFrames.all() {
            let d = try fixtures.decoded(f)
            var sums = [0.0, 0.0, 0.0]
            var n = 0
            for i in stride(from: 0, to: d.pixels.count - 3, by: 3 * 41) {
                for c in 0..<3 { sums[c] += Double(d.pixels[i + c]) }
                n += 1
            }
            let means = sums.map { $0 / Double(n) }
            print(String(format: "%@: means r %.0f g %.0f b %.0f", f.name, means[0], means[1], means[2]))
            XCTAssertLessThan(means[0], min(means[1], means[2]), "\(f.name): red is the lowest channel, which is the C-41 mask")
            XCTAssertLessThan(means[0] / means[1], 0.9, "\(f.name): and it is attenuated, not merely lowest")
        }
    }
}
