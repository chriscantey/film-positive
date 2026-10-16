import Foundation
import FilmSidecar

/// A look is a named slider set over the enhance layer, nothing more. Nothing in a look
/// changes how the negative was inverted.
public struct Look: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var blurb: String
    public var settings: EnhanceSettings
    /// True for the bundled set; user looks are false and live in Application Support.
    public var shipped: Bool

    public init(id: String, name: String, blurb: String, settings: EnhanceSettings, shipped: Bool = false) {
        self.id = id; self.name = name; self.blurb = blurb; self.settings = settings; self.shipped = shipped
    }
}

public enum ShippedLooks {
    // Radiance is not on the panel and the app reads it as 0, so no Look carries it. The
    // Looks that carried it are fitted without it: the tone sliders set by a least-squares fit
    // to minimize mean delta E against their earlier render on four sweep frames, color and
    // detail sliders untouched. Mean delta E after the fit is 0.14 (Canvas) to 0.47 (Pop).
    // Ink (id `overcast`) is fitted to its own curve instead.
    //
    // Looks are slider presets that set the layer from 0, each with a distinct recipe and one
    // signature move across the whole panel (Pop saturation and vibrance, Arcade hard color
    // with halation, Sunroom warmth and glow, Matinee softness and muted low contrast, Canvas
    // light), chosen from renders on Gold 200 and Arista EDU 400 frames so no two look alike.
    // Ids never change: sidecars record them.
    public static let all: [Look] = [
        // Color leads: vibrance and saturation well up, shadows opened, highlights held.
        Look(id: "pop", name: "Pop",
             blurb: "Bright, punchy color for everyday frames.",
             settings: EnhanceSettings(highlights: -0.10, shadows: 0.22, vibrance: 0.55, saturation: 0.25, warmth: 0.06), shipped: true),
        // Warmth and glow. Warmth 0.30 barely showed on a Gold frame, so it is most of
        // the way up, and the glow is the light coming through the window.
        Look(id: "sunroom", name: "Sunroom",
             blurb: "Warm late-afternoon light with a soft glow.",
             settings: EnhanceSettings(highlights: -0.25, shadows: 0.25, brightness: 0.08, vibrance: 0.10, warmth: 0.95, glow: 0.60), shipped: true),
        // Softness, low contrast, muted. The soft focus is what sets it apart from the
        // color Overcast, which is flat too but keeps its color.
        Look(id: "matinee", name: "Matinee",
             blurb: "Soft, faded and cool, like an old projected print.",
             settings: EnhanceSettings(shadows: 0.10, contrast: -0.20, blackPoint: -0.20, saturation: -0.40, warmth: -0.25, softness: 0.50), shipped: true),
        // The ID stays `hard-candy` on purpose, because it is what every sidecar written
        // before the rename to Arcade records, and changing it would silently orphan them.
        // Saturated and hard, with definition and halation. Pop is the open colorful
        // one, Arcade the crushed one: contrast and black point are what keep them apart.
        // Contrast came down from 0.75 to 0.35, with the black point and halation kept so it
        // still reads hard.
        Look(id: "hard-candy", name: "Arcade",
             blurb: "Loud: hard contrast, bold color, glowing lights.",
             settings: EnhanceSettings(highlights: -0.05, shadows: -0.10, contrast: 0.35, blackPoint: 0.30, saturation: 0.55,
                                       definition: 0.55, halation: 0.60), shipped: true),
        // Canvas says what the look is FOR, which is being painted on somewhere else. Its id
        // stays `clear`, an earlier name, so frames tagged with it still highlight. Its
        // signature move is being light, every slider at or under 0.15 (`lightLookIDs`), and it
        // is the one Look meant to be finished somewhere else.
        Look(id: "clear", name: "Canvas",
             blurb: "A light touch, ready to finish in another editor.",
             settings: EnhanceSettings(highlights: -0.09, shadows: 0.13, vibrance: 0.05), shipped: true),
        // A real look rather than an absence of one, sitting in the family of places and
        // times the set already uses (Sunroom, Matinee, Overcast). Its move is the light
        // itself: a brighter frame (exposure and brightness), shadows off the floor, the
        // highlights held against it, a little warmth.
        //
        // It replaces the `plain` look under a NEW id, so a frame still tagged `plain` keeps
        // the sliders it already had and simply stops highlighting, rather than silently being
        // re-labeled as a look whose numbers it does not have.
        Look(id: "morning", name: "Morning",
             blurb: "Bright and airy with a little warmth.",
             settings: EnhanceSettings(exposure: 0.12, highlights: -0.25, shadows: 0.25, brightness: 0.45, blackPoint: -0.05,
                                       vibrance: 0.20, warmth: 0.22, tint: 0.03), shipped: true),
        // The id `overcast` belongs to the black and white Look below, because every sidecar
        // that recorded it means that Look's numbers, so this Look has its own id. Very flat (the
        // lowest contrast in the set, blacks lifted, highlights pulled down) with the color
        // kept vivid and a hint of rose. Matinee is flat too, but soft focus and muted.
        Look(id: "overcast-color", name: "Overcast",
             blurb: "Soft and hazy, still colorful.",
             settings: EnhanceSettings(highlights: -0.45, shadows: 0.40, contrast: -0.90, blackPoint: -0.45, vibrance: 0.45,
                                       saturation: -0.10, warmth: 0.05, tint: 0.12), shipped: true),
        // The black and white looks sit together at the end, so they are not in the middle
        // of the color ones.
        // The most contrast of the three and the blacks set rather than lifted, so it is the
        // hard one. Its id stays `silver`, an earlier name.
        Look(id: "silver", name: "Chalk",
             blurb: "Black and white, bright and punchy.",
             settings: EnhanceSettings(highlights: -0.08, shadows: 0.08, contrast: 0.45, blackPoint: 0.08, saturation: -1.0,
                                       definition: 0.35), shipped: true),
        // The id stays `overcast`, an earlier name, for the sidecars that recorded it.
        Look(id: "overcast", name: "Ink",
             blurb: "Black and white, dark and moody.",
             // Fitted against the bw-park-classic curve, and fitted again
             // whenever the tone chain changes, so the sliders move and the RENDERED curve does
             // not. With Radiance out of the fitter's knobs: rmse 0.01753 (identity 0.09466,
             // worst point 0.064).
             //
             // Then a step less contrast, by hand. Lowering Contrast alone does nothing visible
             // once the mids are held:
             // at Contrast 0.25 to 0.35 with Brightness and Black Point re-balanced, the ramp's
             // quarter-to-three-quarter spread stayed 0.71 to 0.74 against 0.725. The contrast
             // lives in the toe, Shadows -1 crushing everything below a quarter. So Contrast
             // 0.30 and Shadows -0.80, with Brightness and Black Point grid-searched to hold the
             // middle: mid grey 0.447 as before, pure black and pure white where they were, the
             // spread 0.682, the quarter lifted from 0.067 to 0.094. It tracks the old curve
             // with its toe relaxed a quarter of the way toward a straight line
             // (`BlackAndWhiteLookTests.softened`). A free refit against that curve was tried
             // and rejected: it reached Contrast 1.0 and Highlights -0.94, and Highlights is a
             // local operator, so on a real frame it flattens every highlight the ramp cannot show.
             //
             // And a second step the same way. It stays the dark print. Contrast 0.30 to 0.15
             // and Shadows -0.80 to -0.60, with Brightness and Black Point grid-searched on
             // the same ramp. Brightness lands at 0 (0.025 renders the same, to the level,
             // on the ramp and on frames) and Black Point at 0.27: mid grey 0.448 as before,
             // black and white where they were, an eighth of the way up still black, the spread
             // 0.682 to 0.63, the quarter 0.094 to 0.12. It tracks the old curve relaxed halfway
             // toward straight. It stays the dark print: pixels under level 8 are 24% on four
             // color frames and 22% on four Arista frames, where Chalk renders 12% and 2%,
             // Cloud 4% and 0%.
             settings: EnhanceSettings(highlights: 0.03, shadows: -0.60, contrast: 0.15, blackPoint: 0.27, saturation: -1.0), shipped: true),
        // The third black and white Look. Chalk is the hard print and Ink the dark soft
        // one, so this is the BRIGHT one: midtones opened wide, blacks set just off the floor,
        // a glow in the highlights.
        //
        // The tone comes from hand edits of all 36 frames of an Arista EDU 400 roll, which
        // are nearly one move repeated: Brightness median 0.878, Black Point median 0.177,
        // Highlights median 0.004, Contrast and Shadows 0 on most frames. So Brightness 0.88
        // and Black Point 0.18, a small highlight hold for the Glow to sit on, and nothing
        // else. On those frames it lands in the range of the hand edits.
        //
        // What it cannot be is a color filter conversion. Warmth and Tint run before
        // saturation, but the white balance is luminance preserving: measured with Warmth 0.8
        // and Tint 0.5 on a Gold frame, the grey of the red brick and of the blue sky did not
        // move by one level. So it differs from the other two by tone and light, not by channel.
        Look(id: "bright-print", name: "Cloud",
             blurb: "Black and white, bright and soft.",
             settings: EnhanceSettings(highlights: -0.10, brightness: 0.88, blackPoint: 0.18, saturation: -1.0, glow: 0.30), shipped: true),
    ]

    /// The light looks: every slider at or under 0.15 in magnitude. Morning is deliberately
    /// NOT one, because it is meant to have more to it, and a look that qualifies as light by
    /// this rule is a look that barely does anything.
    public static let lightLookIDs: Set<String> = ["clear"]

    /// The black and white looks, one tap each and nothing more. Chalk (id `silver`)
    /// is the hard print. Ink (id `overcast`) comes from a tone curve that hand black and
    /// white edits produced, turned into sliders by a fit to that curve, then taken softer by
    /// hand. Cloud (id `bright-print`) is the bright one, its tone taken from hand edits of an
    /// Arista roll.
    public static let blackAndWhiteLookIDs: Set<String> = ["silver", "overcast", "bright-print"]

    public static func look(_ id: String) -> Look? { all.first { $0.id == id } }
}

/// The `.fplooks` file: a JSON document of looks, exported and imported whole.
/// Sliders are stored under their sidecar names, so a look file and a sidecar agree.
public enum LookFile {
    public static let fileExtension = "fplooks"
    public static let currentVersion = 1

    struct Document: Codable {
        var version: Int
        var looks: [Look]
    }

    public static func encode(_ looks: [Look]) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(Document(version: currentVersion, looks: looks))
    }

    public static func decode(_ data: Data) throws -> [Look] {
        let doc = try JSONDecoder().decode(Document.self, from: data)
        guard doc.version <= currentVersion else { throw LookFileError.newerVersion(doc.version) }
        return doc.looks
    }

    public enum LookFileError: Error, CustomStringConvertible {
        case newerVersion(Int)
        public var description: String {
            switch self { case .newerVersion(let v): return "look file written by a newer version (\(v))" }
        }
    }
}
