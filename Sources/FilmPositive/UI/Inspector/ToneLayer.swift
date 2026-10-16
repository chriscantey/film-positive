import Foundation
import FilmSidecar
import FilmPositiveCore

// Levels and Curves ride through every read and save inside `EnhanceControl.live`, which
// carries them beside the sliders. `ToneModelTests` saves and rescans a frame to hold that.

extension EnhanceSettings {
    /// This layer with Levels and Curves held to the grain the file writes (4 decimals, curves
    /// re-sanitised), so a value set in memory compares equal to the same value read back.
    /// `LookStore` and the inspector's writers use it.
    var toneQuantized: EnhanceSettings {
        var out = self
        out.levels = levels.quantized4
        out.curves = Curves(rgb: curves.rgb.quantized4, red: curves.red.quantized4,
                            green: curves.green.quantized4, blue: curves.blue.quantized4)
        return out
    }
}

extension Levels {
    var quantized4: Levels {
        func q(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
        return Levels(inBlack: q(inBlack), gamma: q(gamma), inWhite: q(inWhite), outBlack: q(outBlack), outWhite: q(outWhite))
    }
}

extension CurvePoints {
    var quantized4: CurvePoints { isIdentity ? self : CurvePoints(sanitising: points) }
}

// MARK: curve channels

/// The Curves picker: all channels together, then red, green and blue alone.
enum CurveChannel: String, CaseIterable, Identifiable, Sendable {
    case all, red, green, blue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        }
    }

    var path: WritableKeyPath<Curves, CurvePoints> {
        switch self {
        case .all: return \.rgb
        case .red: return \.red
        case .green: return \.green
        case .blue: return \.blue
        }
    }

    /// The histogram channel drawn behind this curve, nil for all three.
    var histogramChannel: Int? {
        switch self {
        case .all: return nil
        case .red: return 0
        case .green: return 1
        case .blue: return 2
        }
    }
}

// MARK: Levels handles

/// The five Levels handles, each written like a slider: one field to every selected frame,
/// absolute, the rest of each frame's Levels left as it was.
enum LevelsHandle: String, CaseIterable, Identifiable, Sendable {
    case inBlack, gamma, inWhite, outBlack, outWhite

    /// The accessibility identifier, `levels.inBlack` and so on.
    var id: String { "levels.\(rawValue)" }

    var path: WritableKeyPath<Levels, Double> {
        switch self {
        case .inBlack: return \.inBlack
        case .gamma: return \.gamma
        case .inWhite: return \.inWhite
        case .outBlack: return \.outBlack
        case .outWhite: return \.outWhite
        }
    }

    var identity: Double { Levels.identity[keyPath: path] }

    var label: String {
        switch self {
        case .inBlack: return "Black point"
        case .gamma: return "Midtones"
        case .inWhite: return "White point"
        case .outBlack: return "Output black"
        case .outWhite: return "Output white"
        }
    }

    /// The hover help, one sentence each.
    var help: String {
        switch self {
        case .inBlack: return "Tones at or below this become black."
        case .gamma: return "Drag left to brighten the midtones, right to darken them."
        case .inWhite: return "Tones at or above this become white."
        case .outBlack: return "The darkest tone the picture keeps, raised to fade the blacks."
        case .outWhite: return "The brightest tone the picture keeps, lowered to dim the whites."
        }
    }

    /// One accessibility increment or arrow press.
    var step: Double { self == .gamma ? 0.05 : 0.01 }

    /// The smallest distance two paired handles keep, input black from input white and output
    /// black from output white.
    static let minimumSpan = LevelsMath.minimumInputSpan

    /// `l` with this handle set to `v`, under the handle's rules: 0...1 (gamma 0.1...10),
    /// black never closer than `minimumSpan` to its white, held to the 4 decimal grain.
    /// Applied per frame, so on a selection each frame's own other handle bounds the write.
    func setting(_ l: Levels, to v: Double) -> Levels {
        guard v.isFinite else { return l }
        var out = l
        let gap = Self.minimumSpan
        switch self {
        case .inBlack: out.inBlack = min(max(v, 0), max(0, l.inWhite - gap))
        case .inWhite: out.inWhite = max(min(v, 1), min(1, l.inBlack + gap))
        case .outBlack: out.outBlack = min(max(v, 0), max(0, l.outWhite - gap))
        case .outWhite: out.outWhite = max(min(v, 1), min(1, l.outBlack + gap))
        case .gamma: out.gamma = min(max(v, LevelsMath.gammaRange.lowerBound), LevelsMath.gammaRange.upperBound)
        }
        return out.quantized4
    }

    /// The readout for accessibility.
    func describe(_ v: Double) -> String { String(format: "%.2f", v) }
}

/// Where the midtone handle sits and what gamma a position means. The usual Levels rule: the
/// handle marks the input that comes out at middle grey, so for an input span from b to w it
/// sits at `b + (w - b) * 0.5^gamma`. Gamma 1 is halfway, and LEFT is a gamma above 1, which
/// brightens.
enum LevelsGeometry {
    static func midtonePosition(_ l: Levels) -> Double {
        let g = LevelsMath.guarded(l)
        return g.inBlack + (g.inWhite - g.inBlack) * pow(0.5, g.gamma)
    }

    /// The gamma that puts the midtone handle at track position `x` (0...1), held to the
    /// render's range.
    static func gamma(atPosition x: Double, _ l: Levels) -> Double {
        let g = LevelsMath.guarded(l)
        let lo = pow(0.5, LevelsMath.gammaRange.upperBound), hi = pow(0.5, LevelsMath.gammaRange.lowerBound)
        let f = min(max((x - g.inBlack) / (g.inWhite - g.inBlack), lo), hi)
        let gamma = log(f) / log(0.5)
        return min(max(gamma, LevelsMath.gammaRange.lowerBound), LevelsMath.gammaRange.upperBound)
    }
}
