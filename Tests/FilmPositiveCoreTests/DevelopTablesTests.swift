import XCTest
import FilmSidecar
@testable import FilmPositiveCore

/// The accelerated develop path (per-channel tables) is bit-identical to the CPU
/// reference evaluator, on every fixture frame, color and mono, cropped and whole, under
/// every orientation the geometry contract allows, and over the entire input domain.
///
/// This is a property of two code paths against each other, so it needs no reference
/// render: the tables exist only to make the reference evaluator fast, and the moment they
/// disagree with it one of them is wrong whatever either of them used to produce.
final class DevelopTablesTests: XCTestCase {
    let fixtures = FixtureFrames()

    /// Color on every fixture, and mono once.
    ///
    /// Every fixture rather than a sample because a table is built per analysis, so a
    /// population is the only thing that can catch an entry that is wrong for one frame's
    /// ranges and right for another's. Mono once because the mono path is a different table
    /// and not a different population, and its whole input domain is walked exhaustively
    /// below: running it on all six would double a 230 second test for no new coverage.
    func testTablesMatchTheReferenceEvaluatorOnEveryFixture() throws {
        var checked = 0
        for (index, f) in try FixtureFrames.all().enumerated() {
            for mono in (index == 0 ? [false, true] : [false]) {
                let inp = try fixtures.input(for: f, mono: mono, autoTone: !mono)
                let d = try fixtures.decoded(f)
                let box = fixtures.box(d)
                let (an, dens) = DevelopMath.analyze(d, input: inp)
                let t0 = Date()
                let reference = DevelopMath.render(dens, analysis: an, box: box, flip: true, rotate: 0)
                let t1 = Date()
                let tables = DevelopTables(analysis: an, mono: inp.mono)
                let t2 = Date()
                let fast = tables.apply(d, box: box, flip: true, rotate: 0)
                let t3 = Date()
                let diff = FrameDiff.compare(fast, reference)
                XCTAssertTrue(diff.sameShape, "\(f.name) mono=\(mono)")
                XCTAssertEqual(diff.maxAbs, 0, "\(f.name) mono=\(mono): \(diff)")
                XCTAssertEqual(diff.differing, 0, "\(f.name) mono=\(mono): \(diff)")
                print(String(format: "%@ mono=%@: reference %.2f s, tables build %.3f s, apply %.3f s", f.name,
                             mono ? "yes" : "no", t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), t3.timeIntervalSince(t2)))
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testTablesMatchTheReferenceUnderEveryOrientation() throws {
        let f = try FixtureFrames.first()
        let inp = try fixtures.input(for: f, autoTone: true)
        let d = try fixtures.decoded(f)
        let (an, dens) = DevelopMath.analyze(d, input: inp)
        let tables = DevelopTables(analysis: an, mono: inp.mono)
        let box = DevelopMath.CropBox(x0: 101, y0: 57, x1: 901, y1: 611)
        for rotate in [0, 90, 180, 270] {
            for flip in [false, true] {
                let a = DevelopMath.render(dens, analysis: an, box: box, flip: flip, rotate: rotate)
                let b = tables.apply(d, box: box, flip: flip, rotate: rotate)
                let diff = FrameDiff.compare(b, a)
                XCTAssertTrue(diff.sameShape && diff.differing == 0, "rotate \(rotate) flip \(flip): \(diff)")
            }
        }
    }

    /// Exhaustive domain: every input value maps identically through the tables and the
    /// direct evaluator, for a color analysis and a mono analysis. A sampled frame can
    /// miss a single wrong entry; this cannot.
    func testTablesEqualDirectEvaluatorOverTheWholeDomain() throws {
        let f = try FixtureFrames.first()
        // color: 65536 pixels, every channel carries its own index
        do {
            let inp = try fixtures.input(for: f, autoTone: true)
            let (an, _) = DevelopMath.analyze(try fixtures.decoded(f), input: inp)
            var px = [UInt16](repeating: 0, count: 65536 * 3)
            for v in 0..<65536 { px[v * 3] = UInt16(v); px[v * 3 + 1] = UInt16(v); px[v * 3 + 2] = UInt16(v) }
            let synthetic = DecodedFrame(width: 256, height: 256, pixels: px)
            let (q, _, _) = DevelopMath.density(synthetic, base: an.base, mono: false)
            let direct = DevelopMath.render(DensityFrame(width: 256, height: 256, q: q), analysis: an, flip: false)
            let fast = DevelopTables(analysis: an, mono: false).apply(synthetic, flip: false)
            XCTAssertEqual(FrameDiff.compare(fast, direct).differing, 0, "colour domain")
        }
        do {
            let inp = try fixtures.input(for: f, mono: true)
            let (an, _) = DevelopMath.analyze(try fixtures.decoded(f), input: inp)
            // every sum 0...196605 once: r = min(s, 65535), g = min(s - r, 65535), b = rest
            let n = 196606
            var px = [UInt16](repeating: 0, count: n * 3)
            for s in 0..<n {
                let r = min(s, 65535), g = min(s - r, 65535), b = s - r - g
                px[s * 3] = UInt16(r); px[s * 3 + 1] = UInt16(g); px[s * 3 + 2] = UInt16(b)
            }
            let synthetic = DecodedFrame(width: 2, height: n / 2, pixels: px)
            let (q, _, _) = DevelopMath.density(synthetic, base: an.base, mono: true)
            let direct = DevelopMath.render(DensityFrame(width: 2, height: n / 2, q: q), analysis: an, flip: false)
            let fast = DevelopTables(analysis: an, mono: true).apply(synthetic, flip: false)
            XCTAssertEqual(FrameDiff.compare(fast, direct).differing, 0, "mono domain")
        }
    }

    func testProxyDecodeDevelopsThroughTheSamePath() throws {
        let f = try FixtureFrames.first()
        let inp = try fixtures.input(for: f)
        let half = try RawDecoder(halfSize: true).decode(f.cr2)
        let (an, dens) = DevelopMath.analyze(half, input: inp)
        let a = DevelopMath.render(dens, analysis: an)
        let b = DevelopTables(analysis: an, mono: inp.mono).apply(half)
        XCTAssertEqual(FrameDiff.compare(b, a).differing, 0)
        XCTAssertEqual(half.width * 2, try fixtures.decoded(f).width, accuracy: 2)
    }
}
