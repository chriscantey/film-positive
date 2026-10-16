import Foundation
import FilmSidecar

/// Straighten and crop on the render path.
///
/// The sidecar contract (film-sidecar README): the crop is normalized, y-down, in the
/// ORIGINAL orientation, measured after straighten; apply order is straighten, crop,
/// rotate, flip. Straighten turns the picture clockwise by `degrees` about the frame's
/// center keeping the frame's dimensions (Film Tether's recipe), so a crop rect names the
/// same film whether it was drawn on the proxy or the full decode.
///
/// This is the only resample in develop. A quarter turn and a flip move pixels without
/// touching values, and a zero angle takes that path, so an unstraightened frame is
/// bit-identical to the unrotated render. Any other angle samples the developed positive
/// bilinearly at 16 bits, by inverse mapping every output pixel of the crop box, so the
/// cost is the crop's area, not the frame's.
public enum Straighten {
    /// Below this the angle is treated as zero (Film Tether's `FineRotation.negligibleDegrees`).
    public static let negligibleDegrees = FineRotation.negligibleDegrees

    /// The straightened-and-cropped frame, before quarter rotation and flip.
    public static func apply(_ f: DecodedFrame, degrees: Double, crop: CropRect?) -> DecodedFrame {
        let box = crop.map { Geometry.box($0, width: f.width, height: f.height) }
            ?? DevelopMath.CropBox(x0: 0, y0: 0, x1: f.width, y1: f.height)
        if FineRotation.isNegligible(degrees) {
            return Geometry.cropOnly(f, box: box)
        }
        let w = f.width, h = f.height
        let cw = box.width, ch = box.height
        // Pixel centers sit at i + 0.5 and the frame's center at (w/2, h/2), the same
        // convention as Film Tether's normalized `FineRotation` (0.5, 0.5), so a point
        // mapped there lands on the same film here.
        let cx = Double(w) / 2, cy = Double(h) / 2
        // Output pixel (u, v) of the straightened frame came from the source rotated the
        // other way: positive degrees turn the picture clockwise on screen in y-down
        // coordinates, which is the ordinary rotation matrix; the inverse uses -degrees.
        let t = -degrees * Double.pi / 180
        let c = cos(t), s = sin(t)
        var out = [UInt16](repeating: 0, count: cw * ch * 3)
        f.pixels.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { op in
                @inline(__always) func at(_ x: Int, _ y: Int, _ ch: Int) -> Double {
                    let xx = x < 0 ? 0 : (x >= w ? w - 1 : x)
                    let yy = y < 0 ? 0 : (y >= h ? h - 1 : y)
                    return Double(p[(yy * w + xx) * 3 + ch])
                }
                for v in box.y0..<box.y1 {
                    let dy = Double(v) + 0.5 - cy
                    var o = (v - box.y0) * cw * 3
                    for u in box.x0..<box.x1 {
                        let dx = Double(u) + 0.5 - cx
                        // source position in pixel-center space, then back to index space
                        let sx = dx * c - dy * s + cx - 0.5
                        let sy = dx * s + dy * c + cy - 0.5
                        let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
                        let fx = sx - Double(x0), fy = sy - Double(y0)
                        for ch in 0..<3 {
                            let a = at(x0, y0, ch), b = at(x0 + 1, y0, ch)
                            let cc = at(x0, y0 + 1, ch), d = at(x0 + 1, y0 + 1, ch)
                            let top = a + (b - a) * fx
                            let bot = cc + (d - cc) * fx
                            let val = top + (bot - top) * fy
                            let q = val < 0 ? 0 : (val > 65535 ? 65535 : val)
                            op[o + ch] = UInt16(q.rounded())
                        }
                        o += 3
                    }
                }
            }
        }
        return DecodedFrame(width: cw, height: ch, pixels: out)
    }
}

extension Geometry {
    /// Crop without resampling, no flip, no rotation.
    public static func cropOnly(_ f: DecodedFrame, box: DevelopMath.CropBox) -> DecodedFrame {
        if box.x0 == 0 && box.y0 == 0 && box.x1 == f.width && box.y1 == f.height { return f }
        let cw = box.width, ch = box.height
        var out = [UInt16](repeating: 0, count: cw * ch * 3)
        f.pixels.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { op in
                for y in box.y0..<box.y1 {
                    let s = (y * f.width + box.x0) * 3
                    let d = (y - box.y0) * cw * 3
                    for i in 0..<(cw * 3) { op[d + i] = p[s + i] }
                }
            }
        }
        return DecodedFrame(width: cw, height: ch, pixels: out)
    }

    /// The full develop-side geometry in contract order: straighten, crop, rotate, flip.
    public static func apply(_ f: DecodedFrame, _ g: GeometrySettings) -> DecodedFrame {
        let sc = Straighten.apply(f, degrees: g.straightenDegrees, crop: g.crop)
        return orient(sc, flip: g.flip, rotate: g.rotate)
    }
}
