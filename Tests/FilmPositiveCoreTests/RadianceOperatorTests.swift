import XCTest
import CoreImage
import FilmSidecar
@testable import FilmPositiveCore

/// Radiance: a tone table per slider value plus an edge keeping detail term in L*. These are
/// the operator's own properties: the reference values of the fitting record, identity at 0,
/// flat fields, the slider's direction along each half, the slope floor, the kernel path
/// against the pure function, and the base's proxy keeping two render sizes in agreement.
final class RadianceOperatorTests: XCTestCase {
    typealias Op = RadianceOperator

    // MARK: Helpers

    static func decode(_ s: Double) -> Double { s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
    static func encode(_ l: Double) -> Double {
        let l = min(max(l, 0), 1)
        return l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055
    }

    /// CIE L* of a linear RGB triple.
    static func lstar(_ r: Double, _ g: Double, _ b: Double) -> Double {
        Op.lstar(max(Op.wr * r + Op.wg * g + Op.wb * b, 0))
    }

    /// A linear RGBA float frame from a per pixel function.
    static func linearFrame(_ w: Int, _ h: Int, _ f: (Int, Int) -> (Float, Float, Float)) -> [Float] {
        var px = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let (r, g, b) = f(x, y)
            let o = (y * w + x) * 4
            px[o] = r; px[o + 1] = g; px[o + 2] = b
        } }
        return px
    }

    /// The sRGB output, 0 to 1 and clamped, of a flat grey field of input level `n` of 255.
    static func flat(_ n: Int, _ v: Double) -> Double {
        let c = Float(decode(Double(n) / 255))
        let out = Op.apply(linearFrame(4, 4) { _, _ in (c, c, c) }, width: 4, height: 4, amount: v)
        return encode(Double(out[(2 * 4 + 2) * 4 + 1]))
    }

    /// Structure at the scales the operator works at: dark blocks on a gradient (edges and the
    /// base), a texture inside each block (detail), color so the ratio is exercised. A
    /// function of position as a fraction of the frame, so two sizes draw the same picture.
    static func scene(_ w: Int, _ h: Int) -> [Float] {
        linearFrame(w, h) { x, y in
            let u = (Double(x) + 0.5) / Double(w), t = (Double(y) + 0.5) / Double(h)
            var v = 0.02 + 0.6 * (u + t) / 2
            if (Int(u * 9) + Int(t * 6)) % 3 == 0 { v *= 0.2 }
            v *= 1 + 0.25 * sin(u * 180) * sin(t * 120)
            return (Float(v), Float(v * 0.85), Float(v * 0.6))
        }
    }

    static var noise: (w: Int, h: Int, rgba: [Float]) {
        var rng = SplitMix(seed: 7)
        let w = 300, h = 200
        return (w, h, linearFrame(w, h) { _, _ in
            (Float(decode(rng.unit())), Float(decode(rng.unit())), Float(decode(rng.unit())))
        })
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    static let tenths = (-10...10).map { Double($0) / 10 }

    // MARK: The fitting record

    /// The reference operator's selfcheck: the sRGB output of flat grey inputs n/255. Fails
    /// if a table, a gain, the blend between levels or the L* round trip differs from the
    /// record.
    func testSelfcheckMatchesTheFittingRecord() {
        let record: [(v: Double, values: [(n: Int, out: Double)])] = [
            (-1.0, [(8, 0.00627451), (64, 0.10028098), (128, 0.34080342), (200, 0.80565973), (250, 0.98952331)]),
            (-0.5, [(8, 0.02209744), (64, 0.17526322), (128, 0.426513), (200, 0.79735813), (250, 0.98039216)]),
            (0.5, [(8, 0.05960881), (64, 0.31416566), (128, 0.58725399), (200, 0.78431373), (250, 0.96140219)]),
            (1.0, [(8, 0.05960881), (64, 0.37938627), (128, 0.64756489), (200, 0.79190053), (250, 0.96085835)]),
        ]
        var worst = 0.0
        for (v, values) in record { for (n, out) in values {
            let got = Self.flat(n, v)
            worst = max(worst, abs(got - out))
            XCTAssertEqual(got, out, accuracy: 1e-5, "v \(v), flat \(n)")
        } }
        print(String(format: "RADIANCE selfcheck worst %.2e", worst))
    }

    // MARK: Identity

    /// Radiance 0 copies the frame through bit for bit, including values outside 0 to 1 and a
    /// NaN. Fails if the zero case falls into the arithmetic.
    func testZeroIsBitIdentical() {
        var px = Self.scene(64, 48)
        px[0] = 3.5; px[5] = -0.25; px[9] = .nan; px[14] = 1e-9
        let out = Op.apply(px, width: 64, height: 48, amount: 0)
        XCTAssertEqual(out.map(\.bitPattern), px.map(\.bitPattern))
        // The chain skips the stage: Radiance 0 alone is the identity and returns the frame.
        let f = EnhanceScaleTests.structured(64)
        XCTAssertEqual(try CoreImageEnhance().apply(f, settings: .identity).pixels, f.pixels)
    }

    // MARK: Flat fields

    /// sRGB 0 to 255 at every 0.1 of the slider: every step up the input is a step up the
    /// output, black stays black and white stays white. The flat sRGB 8, 16 and 24 renders sit
    /// in the acceptance bands at both ends of the slider. Fails if a table steps backwards, a
    /// blend between levels inverts, or an end moves.
    func testFlatFieldsNeverStepBackwardsAndTheEndsHold() {
        var minStep = Double.infinity, at = (0.0, 0)
        for v in Self.tenths {
            let ys = (0...255).map { Self.flat($0, v) * 255 }
            // Exact to a thousandth of a level, far under the 16-bit output's step: a flat
            // field's Gaussian sums to 1 only to Float precision.
            XCTAssertEqual(ys[0], 0, "v \(v): black")
            XCTAssertEqual(ys[255], 255, accuracy: 1e-3, "v \(v): white")
            for i in 1...255 where ys[i] - ys[i - 1] < minStep { minStep = ys[i] - ys[i - 1]; at = (v, i) }
        }
        print(String(format: "RADIANCE flat fields: min step %.4f levels at v %+.1f, input %d", minStep, at.0, at.1))
        XCTAssertGreaterThan(minStep, 0, "a flat field step that does not rise, at v \(at.0) input \(at.1)")

        let bands: [(v: Double, n: Int, lo: Double, hi: Double)] = [
            (-1, 8, 1.2, 2.0), (-1, 16, 3.0, 3.8), (-1, 24, 5.6, 6.4),
            (1, 8, 14.8, 15.6), (1, 16, 25.8, 26.6), (1, 24, 39.7, 40.5),
        ]
        for b in bands {
            let y = Self.flat(b.n, b.v) * 255
            print(String(format: "RADIANCE flat %d at %+.0f renders %.2f", b.n, b.v, y))
            XCTAssertTrue(y >= b.lo && y <= b.hi, "flat \(b.n) at \(b.v) renders \(y), band \(b.lo) to \(b.hi)")
        }
    }

    // MARK: Direction along the slider

    /// Along each half of the slider, from 0 out to the end, every input L* moves one way: the
    /// tone table's output at each input never steps against that input's net direction by
    /// more than 0.1 L* between neighbouring tenths. Fails if a fitted level crosses its
    /// neighbour.
    func testEachInputMovesOneWayAlongEachHalf() {
        let inputs = stride(from: 0.0, through: 100.0, by: 0.5).map { $0 }
        func out(_ v: Double) -> [Double] {
            let lv = Op.level(v)
            return lv.t.withUnsafeBufferPointer { t in inputs.map { Op.lookup(t.baseAddress!, $0) } }
        }
        for sign in [1.0, -1.0] {
            let seq = (0...10).map { out(sign * Double($0) / 10) }
            var worst = 0.0
            for j in inputs.indices {
                let net = seq[10][j] - seq[0][j]
                let dir: Double = net > 0 ? 1 : net < 0 ? -1 : 0
                for k in 0..<10 { worst = max(worst, -(seq[k + 1][j] - seq[k][j]) * dir) }
            }
            print(String(format: "RADIANCE one direction, half %+.0f: worst step against %.4f L*", sign, worst))
            XCTAssertLessThanOrEqual(worst, 0.1, "half \(sign): an input steps \(worst) L* against its direction")
        }
    }

    // MARK: The slope floor

    /// The local slope the detail term carries, `max(C' + a, lo(v))`, is never under
    /// `lo(v) = 0.625 + 0.125 v` on any pixel of a noise image at any tenth of the slider.
    /// Fails if the floor is dropped or interpolated instead of computed from `v`.
    func testTheLocalSlopeIsNeverUnderTheFloor() {
        let (w, h, px) = Self.noise
        let ls = (0..<(w * h)).map { Self.lstar(Double(px[$0 * 4]), Double(px[$0 * 4 + 1]), Double(px[$0 * 4 + 2])) }
        for v in Self.tenths where v != 0 {
            let lv = Op.level(v)
            XCTAssertEqual(lv.lo, 0.625 + 0.125 * v, accuracy: 1e-12)
            let under = ls.filter { Op.localSlope(lv, lstar: $0) < 0.625 + 0.125 * v }.count
            XCTAssertEqual(under, 0, "v \(v): \(under) pixels under the floor")
        }
    }

    // MARK: The kernel path

    /// The chain with Radiance alone renders what the pure function computes on the same
    /// pixels, within 0.02 L*, on a frame under the proxy size and on one above it. Fails if
    /// the kernel reads the wrong buffer rows, the chain sees another space, or a stage runs
    /// beside Radiance at every other slider 0.
    func testThePureFunctionEqualsTheChain() throws {
        for (w, h) in [(320, 240), (700, 420)] {
            let lin = Self.scene(w, h)
            var px = [UInt16](repeating: 0, count: w * h * 3)
            for i in 0..<(w * h) { for c in 0..<3 {
                px[i * 3 + c] = UInt16((Self.encode(Double(lin[i * 4 + c])) * 65535).rounded())
            } }
            let frame = DecodedFrame(width: w, height: h, pixels: px)
            var decoded = [Float](repeating: 1, count: w * h * 4)
            for i in 0..<(w * h) { for c in 0..<3 { decoded[i * 4 + c] = Float(Self.decode(Double(px[i * 3 + c]) / 65535)) } }
            for v in [-1.0, -0.3, 0.5, 1.0] {
                var s = EnhanceSettings.identity
                s.radiance = v
                let chain = try CoreImageEnhance().apply(frame, settings: s)
                let pure = Op.apply(decoded, width: w, height: h, amount: v)
                var worst = 0.0
                for i in 0..<(w * h) {
                    let a = Self.lstar(Self.decode(Double(chain.pixels[i * 3]) / 65535), Self.decode(Double(chain.pixels[i * 3 + 1]) / 65535),
                                       Self.decode(Double(chain.pixels[i * 3 + 2]) / 65535))
                    let b = Self.lstar(Self.decode(Self.encode(Double(pure[i * 4]))), Self.decode(Self.encode(Double(pure[i * 4 + 1]))),
                                       Self.decode(Self.encode(Double(pure[i * 4 + 2]))))
                    worst = max(worst, abs(a - b))
                }
                print(String(format: "RADIANCE chain against pure, %dx%d v %+.1f: max %.4f L*", w, h, v, worst))
                XCTAssertLessThanOrEqual(worst, 0.02, "\(w)x\(h) at \(v): chain and pure differ by \(worst) L*")
            }
        }
    }

    /// A sub-rect render through the kernel is the same pixels as the matching crop of the full
    /// render. Core Image may ask the processor for a tile of the output while its region of
    /// interest is the whole frame. Fails if the tile's rows are taken from the wrong end.
    func testASubRectRenderIsTheCropOfTheFullRender() {
        let f = EnhanceScaleTests.structured(512)
        let input = CoreImageEnhance.image(f)
        let ext = input.extent
        let ci = CoreImageEnhance.radiance(input, amount: 1.0, ext: ext).cropped(to: ext)
        func readback(_ bounds: CGRect, _ w: Int, _ h: Int) -> [UInt16] {
            var rgba = [UInt16](repeating: 0, count: w * h * 4)
            rgba.withUnsafeMutableBytes { buf in
                CoreImageEnhance.context.render(ci, toBitmap: buf.baseAddress!, rowBytes: w * 8, bounds: bounds,
                                                format: .RGBA16, colorSpace: CoreImageEnhance.srgb)
            }
            return rgba
        }
        let whole = readback(ext, 512, 512)
        let part = readback(CGRect(x: 100, y: 60, width: 200, height: 150), 200, 150)
        // Core Image's y runs up and the bitmap's rows run down.
        let top = 512 - 60 - 150
        var worst = 0
        for y in 0..<150 { for x in 0..<200 { for c in 0..<3 {
            worst = max(worst, abs(Int(part[(y * 200 + x) * 4 + c]) - Int(whole[((top + y) * 512 + 100 + x) * 4 + c])))
        } } }
        XCTAssertLessThanOrEqual(worst, 1, "sub-rect render differs from the full render's crop by \(worst) of 65535")
    }

    // MARK: Size

    /// The base's coefficient planes are computed at a 512 px long edge. A frame at or under it
    /// is its own proxy.
    func testTheProxyIsThe512PixelLongEdge() {
        XCTAssertTrue(Op.proxySize(width: 512, height: 341) == (512, 341))
        XCTAssertTrue(Op.proxySize(width: 300, height: 200) == (300, 200))
        XCTAssertTrue(Op.proxySize(width: 2048, height: 1364) == (512, 341))
        XCTAssertTrue(Op.proxySize(width: 1300, height: 1950) == (341, 512))
        let k = Op.gaussianKernel(sigma: 8)
        XCTAssertEqual(k.count, 65, "sigma 8 truncated at 4 sigma")
        XCTAssertEqual(Double(k.reduce(0, +)), 1, accuracy: 1e-6)
        XCTAssertEqual([-2, -1, 0, 4, 5, 6].map { Op.mirror($0, 5) }, [1, 0, 0, 4, 4, 3])
    }

    /// The same picture at 2048 px and at 512 px: the 2048 render, brought down to 512 by area
    /// average, lands within 1.0 L* rms of the 512 render, at both ends of the slider. Fails if
    /// the base's scale follows the frame's pixels rather than its long edge.
    func testPreviewAndExportSizesAgree() {
        let (W, H, w, h) = (2048, 1364, 512, 341)
        let big = Self.scene(W, H)
        func down(_ px: [Float]) -> [Float] {
            var out = [Float](repeating: 1, count: w * h * 4)
            for y in 0..<h { for x in 0..<w { for c in 0..<3 {
                var s: Float = 0
                for j in 0..<4 { for i in 0..<4 { s += px[((y * 4 + j) * W + x * 4 + i) * 4 + c] } }
                out[(y * w + x) * 4 + c] = s / 16
            } } }
            return out
        }
        let small = down(big)
        for v in [1.0, -1.0] {
            let a = down(Op.apply(big, width: W, height: H, amount: v))
            let b = Op.apply(small, width: w, height: h, amount: v)
            var sum = 0.0
            for i in 0..<(w * h) {
                let d = Self.lstar(Double(a[i * 4]), Double(a[i * 4 + 1]), Double(a[i * 4 + 2]))
                    - Self.lstar(Double(b[i * 4]), Double(b[i * 4 + 1]), Double(b[i * 4 + 2]))
                sum += d * d
            }
            let rms = (sum / Double(w * h)).squareRoot()
            print(String(format: "RADIANCE size 2048 against 512 at %+.0f: rms %.3f L*", v, rms))
            XCTAssertLessThanOrEqual(rms, 1.0, "at \(v) the two sizes differ by \(rms) L* rms")
        }
    }
}
