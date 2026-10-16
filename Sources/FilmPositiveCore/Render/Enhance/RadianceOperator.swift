import Foundation
import CoreImage

/// Radiance: a tone table per slider value plus an edge keeping detail term, in CIE L*.
///
/// **What it does.** For slider value `v` in -1...+1, every pixel's luminance is taken to L*
/// and sent through a tone table `C` (output L* for input L*) with its slope `C'`. A guided
/// filter base `B` splits the picture into the region and the detail on top of it, and the
/// detail `L - B` is carried with a local slope `g = max(C' + a, lo(v))` in place of `C'`:
///
///     Lout = clamp(C(L) + (g - C'(L)) * (L - B), 0, 100)
///
/// The pixel's linear RGB is then scaled by `Y(Lout) / Y`, so hue and relative saturation
/// survive by construction. The tables, the gains `a` and the floors are in `RadianceTables`.
/// Between the fitted levels everything blends linearly in `v`, and `v = 0` is the identity.
///
/// **Past 1.** A person can set -2...2. For 1 < |v| <= 2 the operator runs twice: at full
/// strength on v's side, then at the remainder `v - 1` or `v + 1` on the first pass's output,
/// with a base computed afresh from that output. Each pass is the measured operator, so what
/// holds for one pass (flat fields never step backwards, the slope floor, black and white
/// handling) holds for the pair, and the result is continuous at 1 because a pass at 0 is the
/// identity. Nothing past 1 is measured against the reference. Past 2 the amount holds at 2.
///
/// **The base.** `m = G(L)`, `var = max(G(L * L) - m * m, 0)`, `A = var / (var + 144)`,
/// `b = m - A * m`, `B = G(A) * L + G(b)`, where `G` is a true Gaussian of sigma 1/64 of the
/// long edge, truncated at 4 sigma, mirrored at the frame's border. The tables were measured
/// with the base computed on a 512 px long edge, so a larger frame computes its coefficient
/// planes `G(A)` and `G(b)` on an area averaged 512 px proxy of its L* plane, where sigma is
/// 8 px, and upsamples them bilinearly before forming `B` at full size. Preview and export
/// therefore see the same base, and the cost of the filters does not grow with the frame. A
/// frame at or under 512 px uses no proxy.
///
/// **Values outside 0...1.** The enhance chain carries extended linear values. Luminance is
/// clamped to 0...1 before it becomes L*, so a pixel above white is treated as white and its
/// channels are scaled by the ratio a white pixel at that place receives, which is 1 wherever
/// the detail term does not move white. A pixel at or below black renders 0. Channels are not
/// clamped here.
///
/// **Why CPU code in a processor kernel.** The build host has no Metal toolchain, so the
/// arithmetic runs as plain Swift over the float buffer Core Image hands a
/// `CIImageProcessorKernel`, in the context's linear sRGB working space. The math is a pure
/// function over a float buffer, so the tests call it with no Core Image.
public enum RadianceOperator {
    /// Rec. 709 luminance weights, as the fitting record states them.
    static let wr = 0.2126729, wg = 0.7151522, wb = 0.0721750
    /// The long edge the base was measured at, and the Gaussian's sigma as a fraction of it.
    public static let proxyLongEdge = 512
    static let sigmaFraction = 8.0 / 512.0
    /// The guided filter's regularizer, in L* squared.
    static let eps = 144.0

    // MARK: L*

    static let kappa = 6.0 / 29.0

    /// CIE L* of a relative luminance.
    @inline(__always) static func lstar(_ y: Double) -> Double {
        let f = y > kappa * kappa * kappa ? cbrt(y) : y / (3 * kappa * kappa) + 4.0 / 29.0
        return 116 * f - 16
    }

    /// The relative luminance of a CIE L*.
    @inline(__always) static func luminance(lstar l: Double) -> Double {
        let fy = (l + 16) / 116
        return fy > kappa ? fy * fy * fy : 3 * kappa * kappa * (fy - 4.0 / 29.0)
    }

    // MARK: The level at v

    /// The tone table, slope table and gain at slider value `v`, blended linearly between the
    /// two fitted levels around it, the identity standing at 0.
    struct Level {
        var t: [Double]
        var s: [Double]
        var a: Double
        var lo: Double
    }

    static let identityLevel = RadianceTables.Level(v: 0, t: (0...100).map(Double.init),
                                                    s: Array(repeating: 1, count: 101), a: 0, lo: 0)

    /// The slope floor, computed from `v` directly.
    static func lo(_ v: Double) -> Double { 0.625 + 0.125 * v }

    static func level(_ v: Double) -> Level {
        let v = min(max(v, -1), 1)
        var all = RadianceTables.levels
        all.insert(identityLevel, at: all.firstIndex { $0.v > 0 }!)
        for (p, q) in zip(all, all.dropFirst()) where p.v <= v && v <= q.v {
            let k = (v - p.v) / (q.v - p.v)
            return Level(t: zip(p.t, q.t).map { (1 - k) * $0 + k * $1 },
                         s: zip(p.s, q.s).map { (1 - k) * $0 + k * $1 },
                         a: (1 - k) * p.a + k * q.a, lo: lo(v))
        }
        preconditionFailure("v \(v) outside the fitted range")
    }

    /// Linear interpolation of a 101 node table at input L*, clamped to the end nodes.
    @inline(__always) static func lookup(_ table: UnsafePointer<Double>, _ l: Double) -> Double {
        let x = min(max(l, 0), 100)
        let i = min(Int(x), 99)
        let f = x - Double(i)
        return table[i] + f * (table[i + 1] - table[i])
    }

    /// The local slope the detail term carries at input L* `l`: `max(C'(l) + a, lo(v))`.
    static func localSlope(_ level: Level, lstar l: Double) -> Double {
        level.s.withUnsafeBufferPointer { max(lookup($0.baseAddress!, l) + level.a, level.lo) }
    }

    // MARK: The operator

    /// The largest amount a person can set on either side. The tables reach 1 on each side.
    public static let maxAmount = 2.0

    /// The passes an amount runs as. Inside -1...1 it is one pass at the amount. For
    /// 1 < |v| <= 2 it is a full pass on v's side, then a pass at the remainder on that pass's
    /// output, so every pass is the measured operator. Past 2 the amount holds at 2.
    static func passes(_ amount: Double) -> [Double] {
        let v = min(max(amount, -maxAmount), maxAmount)
        guard abs(v) > 1 else { return [v] }
        let side: Double = v > 0 ? 1 : -1
        return [side, v - side]
    }

    /// Applies Radiance at slider value `amount` to an interleaved RGBA float frame, `output`
    /// receiving the same size. At 0 (or a non-finite value) the input is copied through bit
    /// for bit and nothing else runs. Past 1 on either side the operator runs twice, as
    /// `passes` states, the second pass in place on `output` with its own base. Alpha is
    /// passed through. `input` and `output` may be the same buffer.
    public static func apply(input: UnsafePointer<Float>, inputRowFloats: Int,
                             output: UnsafeMutablePointer<Float>, outputRowFloats: Int,
                             width w: Int, height h: Int, amount: Double) {
        guard w > 0, h > 0 else { return }
        if amount == 0 || !amount.isFinite {
            if UnsafeRawPointer(input) != UnsafeRawPointer(output) || inputRowFloats != outputRowFloats {
                for y in 0..<h {
                    (output + y * outputRowFloats).update(from: input + y * inputRowFloats, count: w * 4)
                }
            }
            return
        }
        let ps = passes(amount)
        pass(input: input, inputRowFloats: inputRowFloats, output: output, outputRowFloats: outputRowFloats,
             width: w, height: h, amount: ps[0])
        for v in ps.dropFirst() {
            pass(input: output, inputRowFloats: outputRowFloats, output: output, outputRowFloats: outputRowFloats,
                 width: w, height: h, amount: v)
        }
    }

    /// One pass of the measured operator at a nonzero `amount` in -1...1. `input` and `output`
    /// may be the same buffer: the L* plane and the base are formed before any pixel is written,
    /// and each pixel is read before it is written.
    static func pass(input: UnsafePointer<Float>, inputRowFloats: Int,
                     output: UnsafeMutablePointer<Float>, outputRowFloats: Int,
                     width w: Int, height h: Int, amount: Double) {
        let lv = level(amount)
        let n = w * h

        // 1. The L* plane, luminance clamped to 0...1.
        let l = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { l.deallocate() }
        rows(h) { y in
            let s = input + y * inputRowFloats
            for x in 0..<w {
                let yy = wr * Double(s[x * 4]) + wg * Double(s[x * 4 + 1]) + wb * Double(s[x * 4 + 2])
                l[y * w + x] = Float(lstar(min(max(yy, 0), 1)))
            }
        }

        // 2. The base's coefficient planes, on the proxy when the frame is larger than it.
        let coef = coefficients(l, width: w, height: h)
        defer { coef.ga.deallocate(); coef.gb.deallocate() }
        let up = Upsampler(from: (coef.width, coef.height), to: (w, h))

        // 3. Per pixel, at full size.
        lv.t.withUnsafeBufferPointer { tp in
            lv.s.withUnsafeBufferPointer { sp in
                let t = tp.baseAddress!, s = sp.baseAddress!
                let a = lv.a, lo = lv.lo
                rows(h) { y in
                    let src = input + y * inputRowFloats, dst = output + y * outputRowFloats
                    for x in 0..<w {
                        let r = src[x * 4], g = src[x * 4 + 1], b = src[x * 4 + 2], alpha = src[x * 4 + 3]
                        let yy = min(wr * Double(r) + wg * Double(g) + wb * Double(b), 1)
                        guard yy > 0 else {
                            dst[x * 4] = 0; dst[x * 4 + 1] = 0; dst[x * 4 + 2] = 0; dst[x * 4 + 3] = alpha
                            continue
                        }
                        let li = lstar(yy)
                        let (ga, gb) = up.sample(coef.ga, coef.gb, x: x, y: y)
                        let base = ga * li + gb
                        let c = lookup(t, li), cp = lookup(s, li)
                        let slope = max(cp + a, lo)
                        let lout = min(max(c + (slope - cp) * (li - base), 0), 100)
                        let ratio = Float(luminance(lstar: lout) / yy)
                        dst[x * 4] = r * ratio; dst[x * 4 + 1] = g * ratio; dst[x * 4 + 2] = b * ratio
                        dst[x * 4 + 3] = alpha
                    }
                }
            }
        }
    }

    /// The same, over an array, for tests and tools.
    public static func apply(_ rgba: [Float], width: Int, height: Int, amount: Double) -> [Float] {
        precondition(rgba.count == width * height * 4)
        var out = [Float](repeating: 0, count: rgba.count)
        rgba.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                apply(input: src.baseAddress!, inputRowFloats: width * 4, output: dst.baseAddress!,
                      outputRowFloats: width * 4, width: width, height: height, amount: amount)
            }
        }
        return out
    }

    // MARK: The base

    /// The size the base's coefficient planes are computed at: the frame itself up to 512 px
    /// on its long edge, a 512 px long edge above that.
    public static func proxySize(width w: Int, height h: Int) -> (width: Int, height: Int) {
        let long = max(w, h)
        guard long > proxyLongEdge else { return (w, h) }
        let short = max(1, Int((Double(min(w, h)) * Double(proxyLongEdge) / Double(long)).rounded()))
        return w >= h ? (proxyLongEdge, short) : (short, proxyLongEdge)
    }

    /// `G(A)` and `G(b)` of the guided filter for the L* plane `l`, at `proxySize`. The caller
    /// deallocates both planes.
    static func coefficients(_ l: UnsafePointer<Float>, width w: Int, height h: Int)
        -> (ga: UnsafeMutablePointer<Float>, gb: UnsafeMutablePointer<Float>, width: Int, height: Int) {
        let (pw, ph) = proxySize(width: w, height: h)
        let n = pw * ph
        let m = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let m2 = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let tmp = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { m.deallocate(); m2.deallocate(); tmp.deallocate() }
        if pw == w && ph == h {
            m.update(from: l, count: n)
        } else {
            areaAverage(l, width: w, height: h, into: m, width: pw, height: ph)
        }
        for i in 0..<n { m2[i] = m[i] * m[i] }
        let kernel = gaussianKernel(sigma: sigmaFraction * Double(max(pw, ph)))
        gaussian(m, width: pw, height: ph, kernel: kernel, scratch: tmp)
        gaussian(m2, width: pw, height: ph, kernel: kernel, scratch: tmp)
        let ga = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let gb = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let e = Float(eps)
        for i in 0..<n {
            let v = max(m2[i] - m[i] * m[i], 0)
            let a = v / (v + e)
            ga[i] = a; gb[i] = m[i] - a * m[i]
        }
        gaussian(ga, width: pw, height: ph, kernel: kernel, scratch: tmp)
        gaussian(gb, width: pw, height: ph, kernel: kernel, scratch: tmp)
        return (ga, gb, pw, ph)
    }

    /// The edge keeping base at full size, for tests and tools.
    static func base(_ l: [Float], width w: Int, height h: Int) -> [Float] {
        l.withUnsafeBufferPointer { lp in
            let c = coefficients(lp.baseAddress!, width: w, height: h)
            defer { c.ga.deallocate(); c.gb.deallocate() }
            let up = Upsampler(from: (c.width, c.height), to: (w, h))
            var out = [Float](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w {
                let (ga, gb) = up.sample(c.ga, c.gb, x: x, y: y)
                out[y * w + x] = Float(ga * Double(lp[y * w + x]) + gb)
            } }
            return out
        }
    }

    /// Normalized Gaussian taps, truncated at 4 sigma (radius `Int(4 sigma + 0.5)`).
    static func gaussianKernel(sigma: Double) -> [Float] {
        let r = Int(4 * sigma + 0.5)
        let raw = (-r...r).map { exp(-0.5 * Double($0 * $0) / (sigma * sigma)) }
        let sum = raw.reduce(0, +)
        return raw.map { Float($0 / sum) }
    }

    /// The source index for `i`, mirrored about the frame's edges (`d c b a | a b c d`).
    @inline(__always) static func mirror(_ i: Int, _ n: Int) -> Int {
        let p = 2 * n
        var m = i % p
        if m < 0 { m += p }
        return m < n ? m : p - 1 - m
    }

    /// A separable Gaussian, in place, over a `w` by `h` plane.
    static func gaussian(_ plane: UnsafeMutablePointer<Float>, width w: Int, height h: Int,
                         kernel: [Float], scratch tmp: UnsafeMutablePointer<Float>) {
        let r = kernel.count / 2
        kernel.withUnsafeBufferPointer { kp in
            let k = kp.baseAddress!
            // Horizontal, plane into tmp, through a mirrored copy of each row.
            let xs = (-r..<(w + r)).map { mirror($0, w) }
            xs.withUnsafeBufferPointer { xp in
                bands(h) { y0, y1 in
                    let pad = UnsafeMutablePointer<Float>.allocate(capacity: w + 2 * r)
                    defer { pad.deallocate() }
                    for y in y0..<y1 {
                        let s = plane + y * w, d = tmp + y * w
                        for i in 0..<(w + 2 * r) { pad[i] = s[xp[i]] }
                        for x in 0..<w {
                            var acc: Float = 0
                            for j in 0...(2 * r) { acc += k[j] * pad[x + j] }
                            d[x] = acc
                        }
                    }
                }
            }
            // Vertical, tmp into plane, a row at a time.
            let ys = (-r..<(h + r)).map { mirror($0, h) }
            ys.withUnsafeBufferPointer { yp in
                rows(h) { y in
                    let d = plane + y * w
                    d.update(repeating: 0, count: w)
                    for j in 0...(2 * r) {
                        let s = tmp + yp[y + j] * w, kj = k[j]
                        for x in 0..<w { d[x] += kj * s[x] }
                    }
                }
            }
        }
    }

    /// The exact area average of a `w` by `h` plane onto `pw` by `ph`, each output pixel the
    /// mean of the source area it covers, partial pixels weighted by their overlap.
    static func areaAverage(_ src: UnsafePointer<Float>, width w: Int, height h: Int,
                            into dst: UnsafeMutablePointer<Float>, width pw: Int, height ph: Int) {
        let cx = areaWeights(w, pw), cy = areaWeights(h, ph)
        let mid = UnsafeMutablePointer<Float>.allocate(capacity: h * pw)
        defer { mid.deallocate() }
        rows(h) { y in
            let s = src + y * w
            for (j, taps) in cx.enumerated() {
                var acc = 0.0
                for (i, wt) in taps { acc += wt * Double(s[i]) }
                mid[y * pw + j] = Float(acc)
            }
        }
        rows(ph) { j in
            let d = dst + j * pw
            for x in 0..<pw {
                var acc = 0.0
                for (i, wt) in cy[j] { acc += wt * Double(mid[i * pw + x]) }
                d[x] = Float(acc)
            }
        }
    }

    /// For each of `m` output cells over `n` source pixels, the sources it covers and their
    /// normalized overlaps.
    static func areaWeights(_ n: Int, _ m: Int) -> [[(Int, Double)]] {
        let scale = Double(n) / Double(m)
        return (0..<m).map { j in
            let a = Double(j) * scale, b = Double(j + 1) * scale
            var taps = [(Int, Double)]()
            var i = Int(a)
            while Double(i) < b && i < n {
                let overlap = min(b, Double(i + 1)) - max(a, Double(i))
                if overlap > 0 { taps.append((i, overlap / scale)) }
                i += 1
            }
            return taps
        }
    }

    /// Bilinear upsampling of the proxy planes, pixel centers aligned, clamped at the edges.
    struct Upsampler {
        let pw: Int
        let x0: [Int], x1: [Int], fx: [Double]
        let y0: [Int], y1: [Int], fy: [Double]
        let identity: Bool

        init(from p: (Int, Int), to f: (Int, Int)) {
            pw = p.0
            identity = p == f
            func axis(_ n: Int, _ m: Int) -> ([Int], [Int], [Double]) {
                var a = [Int](), b = [Int](), t = [Double]()
                for i in 0..<m {
                    let u = min(max((Double(i) + 0.5) * Double(n) / Double(m) - 0.5, 0), Double(n - 1))
                    let i0 = min(Int(u), n - 1)
                    a.append(i0); b.append(min(i0 + 1, n - 1)); t.append(u - Double(i0))
                }
                return (a, b, t)
            }
            (x0, x1, fx) = axis(p.0, f.0)
            (y0, y1, fy) = axis(p.1, f.1)
        }

        @inline(__always) func sample(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, x: Int, y: Int) -> (Double, Double) {
            if identity { let i = y * pw + x; return (Double(a[i]), Double(b[i])) }
            let i00 = y0[y] * pw + x0[x], i01 = y0[y] * pw + x1[x]
            let i10 = y1[y] * pw + x0[x], i11 = y1[y] * pw + x1[x]
            let tx = fx[x], ty = fy[y]
            func lerp(_ p: UnsafePointer<Float>) -> Double {
                let top = Double(p[i00]) + tx * Double(p[i01] - p[i00])
                let bottom = Double(p[i10]) + tx * Double(p[i11] - p[i10])
                return top + ty * (bottom - top)
            }
            return (lerp(a), lerp(b))
        }
    }

    // MARK: Threads

    /// Runs `body` over contiguous bands of `0..<n`, in parallel.
    static func bands(_ n: Int, _ body: (Int, Int) -> Void) {
        let count = min(n, max(1, ProcessInfo.processInfo.activeProcessorCount * 4))
        guard count > 0 else { return }
        DispatchQueue.concurrentPerform(iterations: count) { k in
            body(k * n / count, (k + 1) * n / count)
        }
    }

    /// Runs `body` over every row index, in parallel bands.
    static func rows(_ h: Int, _ body: (Int) -> Void) {
        bands(h) { y0, y1 in for y in y0..<y1 { body(y) } }
    }
}

/// Radiance as a node in the Core Image graph, so it sits straight after Exposure in
/// `CoreImageEnhance.chain` and the chain stays one graph for preview and export.
///
/// The region of interest is the WHOLE input extent whatever tile is asked for, because the
/// base is computed over the whole frame. A region other than the input's (a downstream blur's
/// margin, a sub-rect render) recomputes the frame and copies its own rows out, which is
/// correct and merely slower.
final class RadianceProcessorKernel: CIImageProcessorKernel {
    static let amountKey = "amount"
    static let extentKey = "extent"

    enum Failure: Error { case missingInput, missingArgument(String), unexpectedFormat }

    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        (arguments?[extentKey] as? CIVector)?.cgRectValue ?? outputRect
    }

    static func arguments(amount: Double, extent: CGRect) -> [String: Any] {
        [amountKey: NSNumber(value: amount), extentKey: CIVector(cgRect: extent)]
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first else { throw Failure.missingInput }
        guard input.format == .RGBAf, output.format == .RGBAf else { throw Failure.unexpectedFormat }
        guard let amount = (arguments?[amountKey] as? NSNumber)?.doubleValue else { throw Failure.missingArgument(amountKey) }

        let inR = input.region, outR = output.region
        let w = Int(inR.width), h = Int(inR.height)
        let src = input.baseAddress.assumingMemoryBound(to: Float.self)
        let srcRow = input.bytesPerRow / MemoryLayout<Float>.size
        let dst = output.baseAddress.assumingMemoryBound(to: Float.self)
        let dstRow = output.bytesPerRow / MemoryLayout<Float>.size

        if inR == outR {
            RadianceOperator.apply(input: src, inputRowFloats: srcRow, output: dst, outputRowFloats: dstRow,
                                   width: w, height: h, amount: amount)
            return
        }
        // A different region: run the whole frame, then copy out what was asked for. A
        // downstream blur asks for MORE than the extent, so the output region can reach past
        // the frame, and there the image is empty, as it is outside any finite extent. The
        // buffers' first row is the region's TOP, its maximum Core Image y, for input and
        // output alike, so rows line up from maxY down.
        let full = UnsafeMutablePointer<Float>.allocate(capacity: w * h * 4)
        defer { full.deallocate() }
        RadianceOperator.apply(input: src, inputRowFloats: srcRow, output: full, outputRowFloats: w * 4,
                               width: w, height: h, amount: amount)
        let ow = Int(outR.width), oh = Int(outR.height)
        let ox = Int(outR.minX - inR.minX), oy = Int(inR.maxY - outR.maxY)
        let x0 = max(0, -ox), x1 = min(ow, w - ox)
        for y in 0..<oh {
            let d = dst + y * dstRow
            d.update(repeating: 0, count: ow * 4)
            let sy = oy + y
            guard sy >= 0, sy < h, x1 > x0 else { continue }
            (d + x0 * 4).update(from: full + (sy * w + ox + x0) * 4, count: (x1 - x0) * 4)
        }
    }
}
