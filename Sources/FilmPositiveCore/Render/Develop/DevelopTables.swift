import Foundation

/// The accelerated develop path.
///
/// Pass 2 of develop is per-channel and one-dimensional: for a channel `c`, the output
/// code value is `tone(normalize_c(quantize(log10(base_c) - log10(max(v, 1)))))`, where
/// `base_c`, the physics range and the tone gamma are per-frame scalars from the
/// analysis. So the whole transform is one 65536-entry table per channel, built in
/// Double with exactly the CPU reference's operations in the same order, and applied
/// with a lookup. Bit-identical to `DevelopMath.render` by construction, no
/// Core Image involved, deterministic on every architecture.
///
/// The mono path averages RGB first (`(r + g + b) / 3`, not rounded) and then applies
/// the same 1D map, so its table is indexed by the channel sum, 0 to 196605.
public struct DevelopTables: Sendable {
    /// Three 65536-entry tables (color) or one 196606-entry table (mono).
    public let tables: [[UInt16]]
    public let mono: Bool

    /// `axisOffsets` are the manual color axes as per-channel density offsets
    /// (`DevelopInput.axisOffsets`), added to the rendered value exactly where
    /// `DevelopMath.density` adds them, so the tables stay bit-identical to
    /// `DevelopMath.render` with the axes moved. Mono ignores them, as `density` does.
    ///
    /// The app's renderer (`CPURenderService`) goes through here rather than through
    /// `density`, so without the offsets here the Warm and Green sliders would change the
    /// sidecar and nothing on screen. The default of zero keeps every zero-slider render
    /// byte-identical to one with no offsets.
    public init(analysis: FrameAnalysis, mono: Bool, axisOffsets: [Double] = [0, 0, 0]) {
        let dMin = DevelopConstants.dMin, dRange = DevelopConstants.dRange
        // Three tables, because a stock's channel balance is per channel. With no balance
        // these are three references to one buffer, so the bytes and the cost are those of
        // one table.
        let tone: [[UInt16]]? = DevelopMath.renderLUTs(analysis)
        @inline(__always) func quantize(_ logBase: Double, _ v: Double, _ offset: Double = 0) -> Int {
            let d = logBase - log10(v > 0 ? v : 1)
            // Same expression as `DevelopMath.density`: the offset joins d in the continuous
            // domain before quantising. `d + 0.0` is exactly `d`, so zero axes change nothing.
            var qi = Int(jsRound(((d + offset - dMin) / dRange) * 65535))
            qi = qi < 0 ? 0 : (qi > 65535 ? 65535 : qi)
            return qi
        }
        @inline(__always) func finish(_ q: Int, _ c: Int) -> UInt16 {
            let lo = analysis.physics[c].lo, hi = analysis.physics[c].hi
            let scale = 65535.0 / Double(hi - lo)
            var v = Int(jsRound(Double(q - lo) * scale))
            v = v < 0 ? 0 : (v > 65535 ? 65535 : v)
            if let tone { v = Int(tone[c][v]) }
            return UInt16(v)
        }
        if mono {
            let logBaseMono = log10((analysis.base[0] + analysis.base[1] + analysis.base[2]) / 3)
            var t = [UInt16](repeating: 0, count: 196606)
            for s in 0..<196606 { t[s] = finish(quantize(logBaseMono, Double(s) / 3), 0) }
            tables = [t]
        } else {
            let logBase = analysis.base.map { log10($0) }
            var ts: [[UInt16]] = []
            for c in 0..<3 {
                var t = [UInt16](repeating: 0, count: 65536)
                for v in 0..<65536 { t[v] = finish(quantize(logBase[c], Double(v), axisOffsets[c]), c) }
                ts.append(t)
            }
            tables = ts
        }
        self.mono = mono
    }

    /// Apply to the linear decode: crop to `box`, flip horizontally, rotate clockwise,
    /// the same geometry as `DevelopMath.render`.
    public func apply(_ f: DecodedFrame, box: DevelopMath.CropBox? = nil, flip: Bool = true, rotate: Int = 0) -> DecodedFrame {
        let bx = box ?? DevelopMath.CropBox(x0: 0, y0: 0, x1: f.width, y1: f.height)
        let cw = bx.width, ch = bx.height
        let outW = (rotate == 90 || rotate == 270) ? ch : cw
        let outH = (rotate == 90 || rotate == 270) ? cw : ch
        var out = [UInt16](repeating: 0, count: cw * ch * 3)
        let w = f.width
        f.pixels.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { op in
                if mono {
                    tables[0].withUnsafeBufferPointer { t in
                        for y in bx.y0..<bx.y1 {
                            let cy = y - bx.y0
                            for x in bx.x0..<bx.x1 {
                                let i = (y * w + x) * 3
                                let s = Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2])
                                let v = t[s]
                                let d = Self.dstIndex(x - bx.x0, cy, cw: cw, ch: ch, flip: flip, rotate: rotate) * 3
                                op[d] = v; op[d + 1] = v; op[d + 2] = v
                            }
                        }
                    }
                } else {
                    tables[0].withUnsafeBufferPointer { t0 in
                    tables[1].withUnsafeBufferPointer { t1 in
                    tables[2].withUnsafeBufferPointer { t2 in
                        if !flip && rotate == 0 {
                            // the common case: straight rows, no index math per pixel
                            for y in bx.y0..<bx.y1 {
                                var i = (y * w + bx.x0) * 3
                                var d = (y - bx.y0) * cw * 3
                                for _ in bx.x0..<bx.x1 {
                                    op[d] = t0[Int(p[i])]; op[d + 1] = t1[Int(p[i + 1])]; op[d + 2] = t2[Int(p[i + 2])]
                                    i += 3; d += 3
                                }
                            }
                        } else {
                            for y in bx.y0..<bx.y1 {
                                let cy = y - bx.y0
                                for x in bx.x0..<bx.x1 {
                                    let i = (y * w + x) * 3
                                    let d = Self.dstIndex(x - bx.x0, cy, cw: cw, ch: ch, flip: flip, rotate: rotate) * 3
                                    op[d] = t0[Int(p[i])]; op[d + 1] = t1[Int(p[i + 1])]; op[d + 2] = t2[Int(p[i + 2])]
                                }
                            }
                        }
                    }}}
                }
            }
        }
        return DecodedFrame(width: outW, height: outH, pixels: out)
    }

    @inline(__always) static func dstIndex(_ cxIn: Int, _ cy: Int, cw: Int, ch: Int, flip: Bool, rotate: Int) -> Int {
        var cx = cxIn
        if flip { cx = cw - 1 - cx }
        switch rotate {
        case 90: return cx * ch + (ch - 1 - cy)
        case 180: return (ch - 1 - cy) * cw + (cw - 1 - cx)
        case 270: return (cw - 1 - cx) * ch + cy
        default: return cy * cw + cx
        }
    }
}
