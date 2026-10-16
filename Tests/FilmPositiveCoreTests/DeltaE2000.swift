import Foundation
@testable import FilmPositiveCore

/// CIEDE2000 between two display-referred sRGB frames, for any criterion stated in a
/// perceptual metric.
///
/// A max-abs difference in 16-bit code values says how far apart two renders are in the
/// encoding. It says nothing about whether a person could see the difference, which is the
/// claim a display-referred comparison actually wants to make. So the same frames are also
/// compared in a perceptual metric, and the threshold is stated in it: CIEDE2000 at p99 and
/// max.
///
/// The implementation is the CIE's own formula (Sharma, Wu and Dalal's published test data
/// is what `DeltaE2000Tests` checks it against), the sRGB transfer
/// function as IEC 61966-2-1 defines it, and the D65 white point, which is what every frame
/// here is tagged with.
enum DeltaE2000 {

    struct Summary: CustomStringConvertible {
        let sampled: Int
        let p99: Double
        let max: Double
        var description: String { String(format: "ΔE2000 over %d samples: p99 %.4f, max %.4f", sampled, p99, max) }
    }

    /// Every `stride`-th pixel of two frames of the same shape. The stride exists because
    /// CIEDE2000 over 54 million pixels per frame times thirteen frames is minutes of test
    /// time for a number that does not move: at stride 7 each frame still contributes
    /// millions of samples, and the stride is reported with the result.
    static func compare(_ a: DecodedFrame, _ b: DecodedFrame, stride: Int = 7) -> Summary? {
        guard a.width == b.width, a.height == b.height else { return nil }
        var values: [Double] = []
        values.reserveCapacity(a.pixels.count / (3 * stride) + 1)
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                var i = 0
                while i + 2 < pa.count {
                    let la = lab(pa[i], pa[i + 1], pa[i + 2])
                    let lb = lab(pb[i], pb[i + 1], pb[i + 2])
                    values.append(delta(la, lb))
                    i += 3 * stride
                }
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        let index = Int((Double(values.count - 1) * 0.99).rounded())
        return Summary(sampled: values.count, p99: values[index], max: values[values.count - 1])
    }

    // MARK: color

    private static func linear(_ v: UInt16) -> Double {
        let c = Double(v) / 65535
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func f(_ t: Double) -> Double {
        t > 216.0 / 24389.0 ? cbrt(t) : (841.0 / 108.0) * t + 4.0 / 29.0
    }

    /// sRGB (IEC 61966-2-1) to CIELAB under D65, which is what these frames are tagged with.
    static func lab(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> (Double, Double, Double) {
        let r = linear(red), g = linear(green), b = linear(blue)
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = (0.2126729 * r + 0.7151522 * g + 0.0721750 * b) / 1.0
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// CIEDE2000, with the rotation term and both arc corrections.
    static func delta(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let (l1, a1, b1) = a
        let (l2, a2, b2) = b
        let c1 = (a1 * a1 + b1 * b1).squareRoot()
        let c2 = (a2 * a2 + b2 * b2).squareRoot()
        let cBar = (c1 + c2) / 2
        let c7 = pow(cBar, 7)
        let g = 0.5 * (1 - (c7 / (c7 + pow(25, 7))).squareRoot())
        let ap1 = (1 + g) * a1, ap2 = (1 + g) * a2
        let cp1 = (ap1 * ap1 + b1 * b1).squareRoot()
        let cp2 = (ap2 * ap2 + b2 * b2).squareRoot()
        let hp1 = hue(ap1, b1), hp2 = hue(ap2, b2)

        let dL = l2 - l1
        let dC = cp2 - cp1
        var dh: Double = 0
        if cp1 * cp2 != 0 {
            dh = hp2 - hp1
            if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        }
        let dH = 2 * (cp1 * cp2).squareRoot() * sin(radians(dh / 2))

        let lBar = (l1 + l2) / 2
        let cpBar = (cp1 + cp2) / 2
        var hBar = hp1 + hp2
        if cp1 * cp2 != 0 {
            if abs(hp1 - hp2) > 180 { hBar += hp1 + hp2 < 360 ? 360 : -360 }
            hBar /= 2
        } else {
            hBar = hp1 + hp2
        }

        let t = 1 - 0.17 * cos(radians(hBar - 30)) + 0.24 * cos(radians(2 * hBar))
            + 0.32 * cos(radians(3 * hBar + 6)) - 0.20 * cos(radians(4 * hBar - 63))
        let dTheta = 30 * exp(-pow((hBar - 275) / 25, 2))
        let cpBar7 = pow(cpBar, 7)
        let rc = 2 * (cpBar7 / (cpBar7 + pow(25, 7))).squareRoot()
        let lMinus50 = (lBar - 50) * (lBar - 50)
        let sl = 1 + (0.015 * lMinus50) / (20 + lMinus50).squareRoot()
        let sc = 1 + 0.045 * cpBar
        let sh = 1 + 0.015 * cpBar * t
        let rt = -sin(radians(2 * dTheta)) * rc

        let termL = dL / sl, termC = dC / sc, termH = dH / sh
        return (termL * termL + termC * termC + termH * termH + rt * termC * termH).squareRoot()
    }

    private static func hue(_ a: Double, _ b: Double) -> Double {
        if a == 0 && b == 0 { return 0 }
        var h = atan2(b, a) * 180 / .pi
        if h < 0 { h += 360 }
        return h
    }

    private static func radians(_ d: Double) -> Double { d * .pi / 180 }
}
