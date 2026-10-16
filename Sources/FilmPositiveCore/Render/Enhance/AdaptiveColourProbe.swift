import Foundation

/// The synthetic scenes Adaptive Color's hard tests (`AdaptiveColourTests`) run on, in one
/// place so every test judges a set on the same pixels. No shot grey card or chart frame is
/// used, so every scene here is built, and says so.
///
/// Each scene is drawn in CIELAB D50 (the Lab of `AdaptiveColour`), converted to
/// a 16-bit sRGB frame, with an optional cast applied as linear gains on top.
public enum AdaptiveColourProbe {
    typealias AC = AdaptiveColour

    /// A deterministic hash in 0 to 1, for texture.
    static func noise(_ x: Int, _ y: Int, _ k: Int = 0) -> Double {
        var h = UInt64(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663 ^ k &* 83_492_791)
        h ^= h >> 33; h = h &* 0xff51afd7ed558ccd; h ^= h >> 33; h = h &* 0xc4ceb9fe1a85ec53; h ^= h >> 33
        return Double(h % 10_000) / 10_000
    }

    static func encode(_ v: Double) -> UInt16 {
        let c = min(max(v, 0), 1)
        let e = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        return UInt16((e * 65535).rounded())
    }

    static func decode(_ u: UInt16) -> Double {
        let v = Double(u) / 65535
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// A frame from a per pixel CIELAB D50 function, with a linear light cast on top.
    public static func frame(_ w: Int, _ h: Int, cast: (Double, Double, Double) = (1, 1, 1),
                             _ f: (Int, Int) -> (Double, Double, Double)) -> DecodedFrame {
        var px = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            let (l, a, b) = f(x, y)
            let (r, g, bb) = AC.rgb(l, a, b)
            let o = (y * w + x) * 3
            px[o] = encode(r * cast.0); px[o + 1] = encode(g * cast.1); px[o + 2] = encode(bb * cast.2)
        } }
        return DecodedFrame(width: w, height: h, pixels: px)
    }

    /// Mean CIELAB D50 over a rectangle.
    public static func meanLab(_ f: DecodedFrame, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> (l: Double, a: Double, b: Double) {
        var sl = 0.0, sa = 0.0, sb = 0.0, n = 0.0
        for y in y0..<y1 { for x in x0..<x1 {
            let o = (y * f.width + x) * 3
            let (l, a, b) = AC.lab(decode(f.pixels[o]), decode(f.pixels[o + 1]), decode(f.pixels[o + 2]))
            sl += l; sa += a; sb += b; n += 1
        } }
        return (sl / n, sa / n, sb / n)
    }

    /// The three casts the grey card is tested under: none, the develop's measured direction
    /// (green and blue, what every estimator read on the three fitted frames), and a warm one.
    public static let casts: [(name: String, gains: (Double, Double, Double), mustShrink: Bool)] = [
        ("no cast", (1, 1, 1), false), ("green and blue cast", (0.92, 1.0, 1.12), true), ("warm cast", (1.14, 1.0, 0.84), true),
    ]

    /// A scene of mixed colors around the hue circle, some neutral surfaces, and a mid grey
    /// card (L* 50) at the center, 120 by 80 px of a 600 by 400 frame.
    public static let card = (x0: 240, y0: 160, x1: 360, y1: 240)
    public static func mixedScene(cast: (Double, Double, Double) = (1, 1, 1)) -> DecodedFrame {
        let patches: [(Double, Double, Double)] = [
            (45, -28, 30), (62, -5, -32), (68, 16, 20), (40, 48, 26), (82, -2, 70), (35, 30, -34),
            (55, 0, 0), (28, 0, 0), (74, 0, 0), (50, -18, -8), (58, 22, -12), (46, 8, 38),
        ]
        return frame(600, 400, cast: cast) { x, y in
            if x >= card.x0 && x < card.x1 && y >= card.y0 && y < card.y1 { return (50, 0, 0) }
            let k = (x / 100) + 6 * (y / 200)
            let p = patches[k % patches.count]
            let t = noise(x, y) - 0.5
            return (min(max(p.0 + 8 * t, 3), 97), p.1 * (1 + 0.2 * t), p.2 * (1 + 0.2 * t))
        }
    }

    /// The card's mean Lab, 4 px inside its edge.
    public static func cardLab(_ f: DecodedFrame) -> (l: Double, a: Double, b: Double) {
        meanLab(f, card.x0 + 4, card.y0 + 4, card.x1 - 4, card.y1 - 4)
    }

    /// A warm sunset field, mostly one saturated hue, with or without a few neutral objects.
    public static func sunset(neutrals: Bool) -> DecodedFrame {
        frame(600, 400) { x, y in
            if neutrals && ((x > 60 && x < 90 && y > 250) || (x > 480 && x < 500 && y > 300)) {
                return (35 + 20 * noise(x, y), 0, 0)
            }
            let t = Double(y) / 400, n = noise(x, y) - 0.5
            return (80 - 45 * t + 6 * n, 28 + 14 * t + 4 * n, 52 + 10 * (1 - t) + 4 * n)
        }
    }

    /// The length and angle (degrees) of a frame's mean (a*, b*) vector.
    public static func meanVector(_ f: DecodedFrame) -> (length: Double, angle: Double) {
        let m = meanLab(f, 0, 0, f.width, f.height)
        return ((m.a * m.a + m.b * m.b).squareRoot(), atan2(m.b, m.a) * 180 / .pi)
    }

    /// The color dominant bound, written before the first run: the mean vector shortens by
    /// at most 5 percent and turns by at most 3 degrees.
    public static let sunsetShortening = 0.05, sunsetTurn = 3.0
}
