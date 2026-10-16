import Foundation

// Channel balance: a per-channel percentile stretch that runs BEFORE the tone step.
//
// WHY IT IS NOT A TONE. The film stock is already stored in every sidecar, so a behavior the
// PROFILE carries reproduces on reopen exactly as well as a stored tone does. A fourth Tone
// button would buy nothing and cost the row its honesty: a Tone row reading None while a
// fourth operator made the picture is a lie, and a fourth tone word in sidecars would have
// to be read forever.
//
// So the profile declares the activity, the activity runs before the tone step, and None,
// Flat and Bold all still mean what they have always meant. A person who does not want it
// picks a different stock.
//
// WHAT IT DOES. The three tone operators all read the GREEN histogram and apply one curve to
// all three channels, so none of them can move a cast. This reads each channel's own 0.1 and
// 99.9 percentiles and sends them to black and to white at full strength.
//
// IN LINEAR LIGHT, and be precise about which linear, because someone will build on it. The
// value the physics remap produces is affine in DENSITY, which is a log encoding, not an
// sRGB one, so decoding it with the sRGB transfer function is a CONVENTION rather than a
// physical decode: it is sRGB-linear, not scene-linear. It is still the right convention
// here. The buffer's stated contract is sRGB, every export tags it sRGB with no conversion,
// and the guidance this follows is guidance for a person moving levels on an encoded file.
// Stretching the encoded value instead would move the midtones by an amount that depends on
// where the endpoints landed, which is a contrast change riding along with the balance
// change nobody asked for.
//
// MEASURED PER FRAME, at full strength. Every other automatic step in this app measures the
// frame in front of it, so a balance that did not would be the one exception. Pooling over a
// roll was measured on 8 frames of an Azure roll and did not tighten the roll's spread of
// mean R/G or B/G below no balance at all, and most of that spread is the SCENE, not the film.

public extension DevelopConstants {
    /// The share of samples clipped off each end of each channel before the stretch:
    /// 0.1 percent, at full strength.
    ///
    /// Deliberately small. The point is to find where a channel actually lives, and a wide
    /// clip finds where its BULK lives instead, throwing away the specular highlight and the
    /// deepest shadow that say the channel reached the end of its range at all.
    static let balanceClip = 0.001

    /// Below this span a channel is left alone rather than stretched.
    ///
    /// Not decoration: a frame that is one flat color, a lens cap, or a blown channel puts
    /// both percentiles on the same value, and the stretch's divisor is their difference.
    ///
    /// Measured on the ENCODED span, not the linear one. A legitimately dark channel has a
    /// tiny linear span and is not degenerate at all, so a linear threshold would refuse to
    /// stretch exactly the underexposed frames that need it most.
    static let balanceMinSpan = 1.0 / 65535
}

/// One channel's reading, kept so the inspector reports what the stretch actually did
/// rather than what it was asked to do.
public struct BalanceChannel: Equatable, Sendable {
    /// This channel's `balanceClip` percentile, as a value in the post-physics domain the
    /// renderer produces, 0...1. Sent to black.
    public let lo: Double
    /// Its `1 - balanceClip` percentile, same domain. Sent to white.
    public let hi: Double
    /// `lo` and `hi` decoded to linear light, where the stretch happens.
    public let linearLo: Double
    public let linearHi: Double
    /// True when the span was under `balanceMinSpan` and the channel was left as identity.
    /// A channel that silently did nothing is indistinguishable from one that had nothing to
    /// do, which is the defect this exists to close.
    public let degenerate: Bool
    /// The share of measured samples the physics remap had ALREADY driven to each end before
    /// the balance saw them.
    ///
    /// These exist because of the one way this does nothing while looking perfectly healthy.
    /// The remap clamps, so a channel with more than `balanceClip` of its samples at an end
    /// reads that end's percentile as exactly 0.000 or 1.000, the span looks maximally wide,
    /// the degenerate guard does not fire, and that end of the stretch is an identity.
    /// Green's ceiling is the STANDING case rather than a rare one: the remap's ceiling IS
    /// green's own P99.5 and this clips at P99.9. Measured on an Azure roll, red and
    /// green were at the rail on 8 frames out of 8, so on that roll the highlight arm does
    /// nothing at all and the whole effect is a per-channel black point and a gain.
    public let loClippedShare: Double
    public let hiClippedShare: Double

    /// Whether this end is an identity because the remap got there first.
    public var loAlreadyClipped: Bool { lo <= 0 }
    public var hiAlreadyClipped: Bool { hi >= 1 }

    public init(lo: Double, hi: Double, linearLo: Double, linearHi: Double, degenerate: Bool,
                loClippedShare: Double = 0, hiClippedShare: Double = 0) {
        self.lo = lo; self.hi = hi
        self.linearLo = linearLo; self.linearHi = linearHi
        self.degenerate = degenerate
        self.loClippedShare = loClippedShare; self.hiClippedShare = hiClippedShare
    }
}

/// The three channels' readings, plus where they were measured.
public struct ChannelBalance: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Measured on the frame being developed.
        case frame

        public var label: String {
            switch self {
            case .frame: return "this frame"
            }
        }
    }

    /// The map is each channel's own black AND white point, so the channel is opened out to
    /// fill the range. A profile carrying an old `"style"` key in an activity entry still
    /// loads: the key is not decoded, so it is ignored and the stretch runs.
    public let channels: [BalanceChannel]
    public let source: Source
    /// How far toward the full map to go, 0 being the identity and 1 the whole thing.
    ///
    /// Blended in LINEAR light, where the operation happens, rather than on the encoded
    /// value. At 0 that is the exact identity by construction, which is asserted rather
    /// than assumed.
    public let strength: Double

    public init(channels: [BalanceChannel], source: Source, strength: Double = 1) {
        self.channels = channels
        self.source = source
        self.strength = strength
    }

    /// The same measurement at a different strength. The endpoints are a property of the
    /// frame; the strength is a choice about what to do with them.
    public func with(strength: Double) -> ChannelBalance {
        ChannelBalance(channels: channels, source: source, strength: strength)
    }

    /// The one line a report shows. Says outright when an end did nothing, because it reads
    /// as a perfectly healthy 0.000 or 1.000 otherwise.
    public var summary: String {
        let names = ["R", "G", "B"]
        let parts = channels.enumerated().map { i, ch -> String in
            if ch.degenerate { return "\(names[i]) flat, left alone" }
            var s = String(format: "%@ %.3f...%.3f", names[i], ch.lo, ch.hi)
            if ch.loAlreadyClipped && ch.hiAlreadyClipped { s += " (both ends at the rail)" }
            else if ch.loAlreadyClipped { s += " (floor at the rail)" }
            else if ch.hiAlreadyClipped { s += " (ceiling at the rail)" }
            return s
        }
        var line = "balance from \(source.label), " + parts.joined(separator: ", ")
            + String(format: ", clipping %.1f%% each end", DevelopConstants.balanceClip * 100)
        if strength != 1 { line += String(format: ", strength %.2f", strength) }
        return line
    }
}

public extension DevelopMath {

    // MARK: the sRGB transfer function
    //
    // IEC 61966-2-1, written out rather than taken from a color library so the kernel keeps
    // depending on nothing and so the encode is exactly the inverse of the decode used here.

    @inline(__always)
    static func srgbToLinear(_ u: Double) -> Double {
        let v = u < 0 ? 0 : (u > 1 ? 1 : u)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    static func srgbFromLinear(_ l: Double) -> Double {
        let v = l < 0 ? 0 : (l > 1 ? 1 : l)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    // MARK: measuring

    /// A channel's histogram moved out of DENSITY bins and into the VALUE bins the renderer
    /// actually produces, by pushing every bin through the same remap `render` applies.
    ///
    /// Nothing here touches the histogram accumulation. Moving a bin, an inset or a sample
    /// count would move `physics` for every stock and every tone.
    static func valueHistogram(_ hist: [UInt32], _ range: ChannelRange) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: 65536)
        let scale = 65535.0 / Double(range.hi - range.lo)
        for b in 0..<65536 where hist[b] != 0 {
            var v = Int(jsRound(Double(b - range.lo) * scale))
            v = v < 0 ? 0 : (v > 65535 ? 65535 : v)
            out[v] &+= hist[b]
        }
        return out
    }

    /// The three value-domain histograms for one frame's analysis inputs.
    static func valueHistograms(hist: [[UInt32]], physics: [ChannelRange]) -> [[UInt32]] {
        (0..<3).map { valueHistogram(hist[$0], physics[$0]) }
    }

    /// The bin at or below which `p` of the samples fall.
    ///
    /// Generalised inverse, first bin whose cumulative count reaches the target. For any
    /// non-decreasing map this carries a percentile to that percentile exactly, which is why
    /// measuring after the remap and measuring before it and then remapping agree.
    static func percentileBin(_ hist: [UInt32], sampleCount: Int, _ p: Double) -> Int {
        guard sampleCount > 0 else { return 0 }
        let target = Double(sampleCount) * p
        var acc = 0.0
        for b in 0..<65536 {
            acc += Double(hist[b])
            if acc >= target { return b }
        }
        return 65535
    }

    /// The balance, from one frame's value-domain histograms.
    static func measureBalance(valueHistograms v: [[UInt32]], sampleCount: Int,
                               source: ChannelBalance.Source) -> ChannelBalance {
        let clip = DevelopConstants.balanceClip
        var channels: [BalanceChannel] = []
        for c in 0..<3 {
            let n = sampleCount > 0 ? sampleCount : Int(v[c].reduce(0) { $0 + UInt64($1) })
            let lo = Double(percentileBin(v[c], sampleCount: n, clip)) / 65535
            let hi = Double(percentileBin(v[c], sampleCount: n, 1 - clip)) / 65535
            let atFloor = n > 0 ? Double(v[c][0]) / Double(n) : 0
            let atCeiling = n > 0 ? Double(v[c][65535]) / Double(n) : 0
            channels.append(BalanceChannel(lo: lo, hi: hi,
                                           linearLo: srgbToLinear(lo), linearHi: srgbToLinear(hi),
                                           degenerate: (hi - lo) < DevelopConstants.balanceMinSpan,
                                           loClippedShare: atFloor, hiClippedShare: atCeiling))
        }
        return ChannelBalance(channels: channels, source: source)
    }

    /// One frame's own balance, which is what a frame developed alone gets.
    static func frameBalance(hist: [[UInt32]], sampleCount: Int, physics: [ChannelRange]) -> ChannelBalance {
        measureBalance(valueHistograms: valueHistograms(hist: hist, physics: physics),
                       sampleCount: sampleCount, source: .frame)
    }

    // MARK: applying

    /// One value through one channel's balance. The scalar form of the table below, and the
    /// thing the tone operators use to measure THROUGH the balance: their two measured
    /// numbers are taken as before and then pushed through this, which is exact because the
    /// map is non-decreasing so it carries a percentile to that percentile.
    @inline(__always)
    static func balanced(_ v: Double, _ ch: BalanceChannel, strength: Double = 1) -> Double {
        guard !ch.degenerate else { return v }
        let linear = srgbToLinear(v)
        var t = (linear - ch.linearLo) / (ch.linearHi - ch.linearLo)
        t = t < 0 ? 0 : (t > 1 ? 1 : t)
        // Blended in linear light, so strength 0 is the exact identity.
        let mixed = linear + strength * (t - linear)
        return srgbFromLinear(mixed)
    }

    /// One channel's table. Identity when the channel is degenerate.
    static func balanceChannelLUT(_ ch: BalanceChannel, strength: Double = 1) -> [UInt16] {
        var lut = [UInt16](repeating: 0, count: 65536)
        if ch.degenerate {
            for i in 0..<65536 { lut[i] = UInt16(i) }
            return lut
        }
        for i in 0..<65536 {
            lut[i] = UInt16(jsRound(balanced(Double(i) / 65535, ch, strength: strength) * 65535))
        }
        return lut
    }

    /// The three balance tables, one per channel, because that is the point.
    static func balanceLUTs(_ balance: ChannelBalance) -> [[UInt16]] {
        balance.channels.map { balanceChannelLUT($0, strength: balance.strength) }
    }
}
