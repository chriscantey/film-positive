import Foundation
import CoreGraphics
import FilmSidecar
import FilmPositiveCore

/// A small sRGB bitmap, the only thing that crosses back from the decode thread. Keeping
/// the type `Sendable` and tiny is what lets the half size decode and the whole reduction
/// happen off the main actor while the grid stays responsive.
struct ThumbnailBitmap: Sendable, Equatable {
    let width: Int
    let height: Int
    /// `width * height * 3`, 8 bits per channel, sRGB encoded.
    let rgb: [UInt8]

    /// Per channel mean, used by the tests to prove the picture is a negative rather than
    /// a positive (a color negative carries the orange mask, so red sits far above blue).
    var channelMeans: (r: Double, g: Double, b: Double) {
        guard width > 0, height > 0 else { return (0, 0, 0) }
        var sums = (0, 0, 0)
        for i in stride(from: 0, to: rgb.count, by: 3) {
            sums.0 += Int(rgb[i]); sums.1 += Int(rgb[i + 1]); sums.2 += Int(rgb[i + 2])
        }
        let n = Double(width * height)
        return (Double(sums.0) / n, Double(sums.1) / n, Double(sums.2) / n)
    }
}

/// Builds the grid's undeveloped cell picture: a real thumbnail of the negative, not an
/// icon.
///
/// The transform is deliberately the smallest one that makes the negative visible, and it
/// is not a develop. There is no inversion and no white balance, so an orange masked
/// color negative still reads orange and the moment it is developed the cell visibly
/// becomes a different picture. All that happens is a box reduction, a single scalar
/// normalization taken from a high percentile across every channel at once (per channel
/// normalization would white balance the frame and quietly undo the mask), and the sRGB
/// transfer so the linear decode is not a black rectangle on screen.
enum NegativeThumbnail {
    /// Long edge of the produced bitmap. The half size decode of a 20 MP raw is about
    /// 27 MB, so it is reduced immediately and only this survives in the cache.
    static let defaultMaxEdge = 512

    /// The percentile that maps to white. High enough that a few specular samples or hot
    /// pixels cannot darken the whole frame.
    static let whitePercentile = 0.995

    /// Decodes `url` at half size and reduces it. Blocking, CPU bound, never call this on
    /// the main actor.
    static func bitmap(of url: URL, maxEdge: Int = defaultMaxEdge) throws -> ThumbnailBitmap {
        reduce(try RawDecoder(halfSize: true).decode(url), maxEdge: maxEdge)
    }

    /// Box reduce, normalize, sRGB encode. Pure, so the tests can drive it with a
    /// synthetic frame as well as a real raw.
    static func reduce(_ frame: DecodedFrame, maxEdge: Int = defaultMaxEdge) -> ThumbnailBitmap {
        let factor = max(1, Int(ceil(Double(max(frame.width, frame.height)) / Double(max(1, maxEdge)))))
        let outW = max(1, frame.width / factor)
        let outH = max(1, frame.height / factor)
        let blockCount = factor * factor

        var reduced = [UInt16](repeating: 0, count: outW * outH * 3)
        frame.pixels.withUnsafeBufferPointer { src in
            for y in 0..<outH {
                for x in 0..<outW {
                    var acc = (UInt32(0), UInt32(0), UInt32(0))
                    for by in 0..<factor {
                        let row = (y * factor + by) * frame.width
                        for bx in 0..<factor {
                            let p = (row + x * factor + bx) * 3
                            acc.0 += UInt32(src[p]); acc.1 += UInt32(src[p + 1]); acc.2 += UInt32(src[p + 2])
                        }
                    }
                    let o = (y * outW + x) * 3
                    reduced[o] = UInt16(acc.0 / UInt32(blockCount))
                    reduced[o + 1] = UInt16(acc.1 / UInt32(blockCount))
                    reduced[o + 2] = UInt16(acc.2 / UInt32(blockCount))
                }
            }
        }

        let white = percentile(reduced, whitePercentile)
        let table = encodeTable(white: white)
        var rgb = [UInt8](repeating: 0, count: reduced.count)
        for i in 0..<reduced.count { rgb[i] = table[Int(reduced[i])] }
        return ThumbnailBitmap(width: outW, height: outH, rgb: rgb)
    }

    /// The sample value at `p` of the cumulative histogram over every channel together.
    /// One scalar for all three channels on purpose: that is what preserves the mask.
    static func percentile(_ samples: [UInt16], _ p: Double) -> UInt16 {
        guard !samples.isEmpty else { return 1 }
        var histogram = [Int](repeating: 0, count: 65536)
        for v in samples { histogram[Int(v)] += 1 }
        let target = Int((Double(samples.count) * p).rounded())
        var seen = 0
        for v in 0..<65536 {
            seen += histogram[v]
            if seen >= target { return UInt16(max(1, v)) }
        }
        return UInt16.max
    }

    /// A 16 bit input to 8 bit sRGB output lookup, built once per thumbnail.
    private static func encodeTable(white: UInt16) -> [UInt8] {
        let w = Double(max(1, white))
        var table = [UInt8](repeating: 0, count: 65536)
        for v in 0..<65536 {
            let linear = min(1.0, Double(v) / w)
            let encoded = linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1.0 / 2.4) - 0.055
            table[v] = UInt8(max(0, min(255, (encoded * 255).rounded())))
        }
        return table
    }

    /// The geometry contract applied to an already reduced thumbnail, in the same order
    /// the develop path uses: straighten, crop, rotate, flip.
    ///
    /// Why here and not in the engine: a frame with no develop section never reaches the
    /// render service at all (`RenderCoordinator.request(for:)` returns nil without one),
    /// so without this a flip or a rotate on a frame that has not been made positive would
    /// not show: the thumbnail is the only picture the undeveloped states can draw.
    ///
    /// It runs on the reduced bitmap rather than the decode so an edit costs a pass over
    /// at most 512 x 512 x 3 bytes instead of a fresh LibRaw decode. The lift to 16 bits is
    /// exact (values stay 0...255), so a quarter turn and a flip move bytes without
    /// touching them and only a straighten resamples, exactly as on the develop path.
    ///
    /// The normalization is deliberately NOT recomputed after a crop: white is measured
    /// once on the whole negative, so cropping reframes the picture without also changing
    /// its brightness under the user's hand.
    static func geometry(_ bitmap: ThumbnailBitmap, _ g: GeometrySettings) -> ThumbnailBitmap {
        guard !g.isIdentity, bitmap.width > 0, bitmap.height > 0 else { return bitmap }
        let lifted = DecodedFrame(width: bitmap.width, height: bitmap.height,
                                  pixels: bitmap.rgb.map { UInt16($0) })
        let out = Geometry.apply(lifted, g)
        var rgb = [UInt8](repeating: 0, count: out.pixels.count)
        for i in 0..<out.pixels.count { rgb[i] = UInt8(min(255, out.pixels[i])) }
        return ThumbnailBitmap(width: out.width, height: out.height, rgb: rgb)
    }

    /// Wraps the bitmap for SwiftUI. Cheap, and done on the main actor where the cache lives.
    static func image(_ bitmap: ThumbnailBitmap) -> CGImage? {
        guard bitmap.width > 0, bitmap.height > 0 else { return nil }
        let data = bitmap.rgb.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 24,
                       bytesPerRow: bitmap.width * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
