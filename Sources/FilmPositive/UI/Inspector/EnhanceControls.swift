import Foundation
import FilmSidecar

/// The twenty enhance controls as data: identity, label, SF Symbol, group and the writable
/// key path into `EnhanceSettings`. Plain types with no SwiftUI so the ordering, the
/// grouping and the reset behavior can be tested without a view.
///
/// The union of the four groups is exactly the SET of `liveSliderKeys`, which
/// `coversSliderKeys` asserts. It is deliberately not the same ORDER: see the note on
/// `coversSliderKeys`.
/// `@unchecked Sendable` for one reason: `WritableKeyPath` is not `Sendable` even when
/// both its root and its value are, which would otherwise be an error in the Swift 6
/// language mode. A key path into a frozen value type holds no state and crossing an actor
/// with one is safe. Nothing else here is unchecked.
struct EnhanceControl: Identifiable, Hashable, @unchecked Sendable {
    /// The four Enhance groups. The raw value is the DISPLAYED title and the SwiftUI
    /// identity, nothing else: no sidecar key, no preference and no stored state reads it,
    /// so it is free to change. The case stays `tone` because every slider key, every test
    /// and `EnhanceControl.group(.tone)` name it that way, and renaming the case would
    /// touch code for a word on screen.
    ///
    /// The title is "Light" and not "Tone" because the Develop section already has a Tone
    /// row (None, Flat, Bold), which is the paper curve and where Auto Tone lives, and this
    /// group does not connect to it.
    ///
    /// Vignette is last, after Detail, and holds the vignette's three sliders: amount, size
    /// and softness.
    enum Group: String, CaseIterable, Identifiable, Sendable {
        case tone = "Light"
        case colour = "Color"
        case detail = "Detail"
        case vignette = "Vignette"
        var id: String { rawValue }
    }

    /// The sidecar key, which is also the SwiftUI identity.
    let id: String
    let label: String
    let symbol: String
    let group: Group
    let path: WritableKeyPath<EnhanceSettings, Double>
    /// What the slider shows, times the stored value. 1 for every control but the vignette
    /// Amount, whose stored value keeps its meaning (positive lightens the edges) while its
    /// slider reads the other way round (right darkens). Flipping the render instead would
    /// flip every frame already vignetted.
    var sign: Double = 1
    /// What the row says on hover before the click help, one short sentence. Nil
    /// for the rows that carry only the click help, which is every row but Radiance and the
    /// Vignette group.
    var help: String? = nil

    /// The span a row shows AT REST, with 0 as identity. Every slider starts here.
    ///
    /// It is not the limit of what a value may BE. Typing a number outside it is how a person
    /// reaches further, and the track rescales around what was typed. See
    /// `EnhanceSliderRow.effectiveRange`.
    static let range: ClosedRange<Double> = -1...1

    /// What a value may actually hold once someone types one.
    ///
    /// This is not a ceiling, it is a guard against a value that is not a number.
    /// `Double("1e400")` parses to infinity, and infinity or NaN reaching a Core Image filter
    /// is undefined behavior rather than a big adjustment. The bound is far outside anything
    /// a control still responds to, so nobody meets it by typing a number they meant.
    ///
    /// SIDECAR CONTRACT. Widening what may be STORED cannot change what is READ: a value
    /// inside -1...1 reads back bit-identically, because nothing in the codec clamps and
    /// `sliderKeys` is an ORDER rather than a range. The direction that does change is
    /// forward: a sidecar holding 1.8, opened in an older build limited to -1...1, renders it
    /// and then destroys it on the first touch of that control.
    static let storageLimit: ClosedRange<Double> = -1000...1000

    func value(in settings: EnhanceSettings) -> Double { settings[keyPath: path] * sign }

    func setting(_ settings: EnhanceSettings, to value: Double) -> EnhanceSettings {
        var out = settings
        // Non-finite is dropped rather than clamped: a NaN compares false against everything,
        // so `clamped` would pass it straight through into the render graph.
        guard value.isFinite else { return settings }
        out[keyPath: path] = (value * sign).clamped(to: Self.storageLimit)
        return out
    }
}

extension EnhanceControl {
    /// All twenty, with Glow, Halation and Softness at the end of Detail and the Vignette
    /// group last. "Brilliance" is never written anywhere. Radiance is the first row of
    /// Light. Warmth and Tint sit in Color, because there is no separate White Balance
    /// adjustment.
    ///
    /// THIS ORDER IS FREE TO CHANGE. It is not tied to the sidecar's index order. See
    /// `coversSliderKeys`.
    static let all: [EnhanceControl] = [
        // Light
        EnhanceControl(id: "radiance", label: "Radiance", symbol: "sparkles", group: .tone, path: \.radiance,
                       help: "Brightens shadows and holds back highlights, or deepens the picture to the left."),
        EnhanceControl(id: "exposure", label: "Exposure", symbol: "plusminus.circle", group: .tone, path: \.exposure),
        EnhanceControl(id: "highlights", label: "Highlights", symbol: "circle.tophalf.filled", group: .tone, path: \.highlights),
        EnhanceControl(id: "shadows", label: "Shadows", symbol: "circle.bottomhalf.filled", group: .tone, path: \.shadows),
        EnhanceControl(id: "brightness", label: "Brightness", symbol: "sun.max", group: .tone, path: \.brightness),
        EnhanceControl(id: "contrast", label: "Contrast", symbol: "circle.lefthalf.filled", group: .tone, path: \.contrast),
        EnhanceControl(id: "blackPoint", label: "Black Point", symbol: "circle.fill", group: .tone, path: \.blackPoint),
        // Color
        EnhanceControl(id: "saturation", label: "Saturation", symbol: "paintpalette", group: .colour, path: \.saturation),
        EnhanceControl(id: "vibrance", label: "Vibrance", symbol: "drop", group: .colour, path: \.vibrance),
        EnhanceControl(id: "warmth", label: "Warmth", symbol: "thermometer.medium", group: .colour, path: \.warmth),
        EnhanceControl(id: "tint", label: "Tint", symbol: "eyedropper", group: .colour, path: \.tint),
        // Detail
        EnhanceControl(id: "definition", label: "Definition", symbol: "wand.and.rays", group: .detail, path: \.definition),
        EnhanceControl(id: "sharpness", label: "Sharpness", symbol: "triangle", group: .detail, path: \.sharpness),
        EnhanceControl(id: "noiseReduction", label: "Noise Reduction", symbol: "aqi.medium", group: .detail, path: \.noiseReduction),
        EnhanceControl(id: "glow", label: "Glow", symbol: "sun.haze", group: .detail, path: \.glow),
        EnhanceControl(id: "halation", label: "Halation", symbol: "rays", group: .detail, path: \.halation),
        EnhanceControl(id: "softness", label: "Softness", symbol: "drop.halffull", group: .detail, path: \.softness),
        // Vignette. Amount keeps the id `vignette`, its stored meaning and its sign. Size and
        // Softness are centered at 0, the default vignette shape. The Softness here is the
        // vignette's edge and is stored as `vignetteFeather`. The Detail row above is a
        // different control with the same word.
        EnhanceControl(id: "vignette", label: "Amount", symbol: "circle.dashed", group: .vignette, path: \.vignette,
                       sign: -1, help: "Darkens or lightens the edges."),
        EnhanceControl(id: "vignetteSize", label: "Size", symbol: "arrow.up.left.and.arrow.down.right",
                       group: .vignette, path: \.vignetteSize, help: "How far the vignette reaches toward the center."),
        EnhanceControl(id: "vignetteFeather", label: "Softness", symbol: "circle.lefthalf.striped.horizontal",
                       group: .vignette, path: \.vignetteFeather, help: "How gradual the vignette's edge is."),
    ]

    static func group(_ g: Group) -> [EnhanceControl] { all.filter { $0.group == g } }

    /// The union of the groups is exactly the sidecar's slider SET. A slider added to the
    /// contract and forgotten here still fails this.
    ///
    /// It compares sets rather than arrays on purpose. `sliderKeys` is one of three parallel
    /// orderings inside `FilmSidecar` that the XMP codec indexes by position, so an array
    /// comparison would weld the inspector's display order to the codec's index order.
    /// Reordering a row here would force `sliderKeys` to move, and every sidecar ever written
    /// would then read its contrast into its brightness. The orderings inside `FilmSidecar`
    /// are guarded where they live, by `EnhanceOrderingTests` in that package, which also
    /// round trips a written sidecar.
    static var coversSliderKeys: Bool { Set(all.map(\.id)) == Set(liveSliderKeys) }

    /// The shared package's slider keys this app retired, BY NAME. Every other key is live,
    /// so a key the package appends later is live too and `coversSliderKeys` fails until
    /// someone decides whether it gets a row.
    ///
    /// Richness: the slider the app retired while the package kept its key. It is cut
    /// by name, not by wire position, because the vignette's Size and Softness come after it.
    static let retired: Set<String> = ["richness"]

    /// The package's slider keys this app reads and writes, in wire order.
    static var liveSliderKeys: [String] { EnhanceSettings.sliderKeys.filter { !retired.contains($0) } }

    /// Every package key this app does not read or write, in wire order: Richness.
    static var retiredSliderKeys: [String] { EnhanceSettings.sliderKeys.filter { retired.contains($0) } }

    /// `settings` with only this app's sliders kept, every other field at 0. Applied where a
    /// sidecar is read and where one is written, so a retired value an older build left in a
    /// file neither renders nor survives the next save.
    ///
    /// Levels and Curves are not sliders and are carried as they are. Rebuilt from the slider
    /// list alone, the layer would lose both on every folder read and every save.
    static func live(_ settings: EnhanceSettings) -> EnhanceSettings {
        var out = EnhanceSettings()
        for c in all { out[keyPath: c.path] = settings[keyPath: c.path] }
        out.levels = settings.levels
        out.curves = settings.curves
        return out
    }

    /// No control is listed twice.
    static var idsAreUnique: Bool { Set(all.map(\.id)).count == all.count }

    /// No two controls share a key path, which would make one silently write the other.
    static var pathsAreUnique: Bool { Set(all.map(\.path)).count == all.count }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
