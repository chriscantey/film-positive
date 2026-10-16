import Foundation
import AppKit
import FilmSidecar
import FilmPositiveCore

/// Copy and paste of a frame's settings, as the general pasteboard sees them.
///
/// The three sections are the three layers the app already resets independently, under the
/// words the UI uses for them:
///
/// - **Develop** (`positive` on the wire) is the develop layer: stock, auto tone and the base.
/// - **Enhance** is the slider set and the name of the look they came from.
/// - **Crop** is the geometry layer: crop, straighten, rotate and flip.
///
/// The payload names WHICH sections were copied as well as their values, and the two are
/// not the same thing. A frame with no crop still has a crop section worth copying: pasting
/// it means "have no crop", and a paste that silently skipped it could never be used to
/// clear one. Sections absent from `sections` are left alone on the target, always.
enum FrameSettingsSection: String, Codable, CaseIterable, Sendable {
    case positive, enhance, crop

    /// The menu wording, which names the inspector section each case copies. The case stays
    /// `positive` because it is the payload's wire value, and only the word is Develop.
    var title: String {
        switch self {
        case .positive: return "Develop"
        case .enhance: return "Enhance"
        case .crop: return "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .positive: return "circle.lefthalf.striped.horizontal"
        case .enhance: return "slider.horizontal.3"
        case .crop: return "crop"
        }
    }

    static let all: Set<FrameSettingsSection> = Set(allCases)
}

/// What sits on the pasteboard. Codable on its own terms rather than over the sidecar
/// types, because `DevelopSettings` and `GeometrySettings` are not `Codable` and making
/// them so would put a wire format on the shared sidecar schema, which is a bigger promise
/// than this feature needs.
struct FrameSettingsPayload: Codable, Equatable {
    /// Stamped so a blob from some other app that happens to claim our UTI is rejected
    /// rather than half-decoded.
    static let tag = "co.wonders.filmpositive.settings"
    static let currentVersion = 1

    var app: String = FrameSettingsPayload.tag
    var version: Int = FrameSettingsPayload.currentVersion
    var sections: [FrameSettingsSection]
    /// Whether the frame this was copied FROM had a positive at all. Absent in an older
    /// payload.
    ///
    /// It is not the same question as "does `sections` contain `.positive`", and the
    /// difference is the whole reason it is recorded. Copy All from an undeveloped frame
    /// asks for the positive and gets nothing, because there is nothing to copy, so the
    /// payload carries enhance and crop and looks exactly like a deliberate two-section
    /// copy. A later Paste All then leaves the target's whole Positive block alone, the Find
    /// film edge toggle included. This field is what lets the paste tell the truth.
    var sourceWasPositive: Bool? = nil
    var positive: Develop? = nil
    var enhance: Enhance? = nil
    var crop: Geometry? = nil

    /// An older payload also carries `light`, the retired scanner id. The decoder ignores
    /// the key, so it still pastes.
    struct Develop: Codable, Equatable {
        var stock: String
        /// Absent in an older payload, where `autoTone` carried the same information in two
        /// states.
        var tone: String?
        var autoTone: Bool
        var autoBalance: Bool?
        var base: Base
        /// The two manual color axes, in printer points. Absent in a payload from before
        /// they existed, which decodes to the identity.
        ///
        /// It has to travel, and it has to travel for BOTH reasons. A paste reproduces a
        /// state, and a graded positive whose grade did not come with it is not that state.
        /// And `applied(to:)` replaces the target's whole develop layer through
        /// `setDevelop`, so a payload that simply omitted the axes would not leave the
        /// target's own grade alone: it would silently reset it to neutral, which is an
        /// automatic write of exactly the field nothing automatic may write.
        var colourAxes: ColourAxes?

        init(_ d: DevelopSettings) {
            stock = d.stock; tone = d.tone.rawValue
            autoTone = d.appliesTone; autoBalance = d.autoBalance; base = Base(d.base)
            colourAxes = d.colourAxes.isIdentity ? nil : d.colourAxes
            toneAdjust = d.toneAdjust.map(ToneValues.init)
            stretch = d.stretch
        }
        var settings: DevelopSettings {
            var out = DevelopSettings(stock: stock,
                                      tone: tone.flatMap(ToneMode.init(rawValue:)) ?? (autoTone ? .flat : .none),
                                      autoBalance: autoBalance ?? true, base: base.settings)
            out.colourAxes = colourAxes ?? .identity
            out.toneAdjust = toneAdjust?.adjust
            out.stretch = stretch.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
            return out
        }

        /// The Tone row's Adjust, for the axes' two reasons: a paste reproduces a
        /// state, and since the paste replaces the whole develop layer, leaving it out would
        /// silently put the target back on its preset. Absent in an older payload, which
        /// decodes to nil, the preset's own values.
        var toneAdjust: ToneValues?
        /// The Tone row's Stretch, for the same two reasons. Absent in an older payload,
        /// which decodes to nil, Full.
        var stretch: Double?
    }

    /// `ToneAdjust` on the wire. The sidecar type is not `Codable`, for the reason this
    /// payload has its own types at all.
    struct ToneValues: Codable, Equatable {
        var exposure: Double, contrast: Double, black: Double, white: Double
        init(_ t: ToneAdjust) { exposure = t.exposure; contrast = t.contrast; black = t.black; white = t.white }
        var adjust: ToneAdjust { ToneAdjust(exposure: exposure, contrast: contrast, black: black, white: white) }
    }

    struct Base: Codable, Equatable {
        var mode: String
        var anchor: Int?
        var ratios: BaseRatios?
        var measured: [Int]?

        init(_ b: BaseSettings) {
            mode = b.mode.rawValue; anchor = b.anchor; ratios = b.ratios; measured = b.measured
        }
        var settings: BaseSettings {
            BaseSettings(mode: BaseSettings.Mode(rawValue: mode) ?? .anchor,
                         anchor: anchor, ratios: ratios, measured: measured)
        }
    }

    /// The sliders and the look name travel together. That pairing is the one case neither
    /// `SidecarEdits.setEnhance` (a slider drag, which drops the look because the numbers no
    /// longer match it) nor `SidecarEdits.applyLook` (a preset, which overwrites the
    /// numbers) covers: a paste reproduces a state, so it carries both halves of it.
    struct Enhance: Codable, Equatable {
        var sliders: EnhanceSettings
        var look: String?
    }

    struct Geometry: Codable, Equatable {
        var rotate: Int
        var flip: Bool
        var straightenDegrees: Double
        var crop: Rect?

        init(_ g: GeometrySettings) {
            rotate = g.rotate; flip = g.flip; straightenDegrees = g.straightenDegrees
            crop = g.crop.map(Rect.init)
        }
        var settings: GeometrySettings {
            GeometrySettings(rotate: rotate, flip: flip, straightenDegrees: straightenDegrees,
                             crop: crop?.rect)
        }
    }

    struct Rect: Codable, Equatable {
        var x: Double, y: Double, w: Double, h: Double
        init(_ r: CropRect) { x = r.x; y = r.y; w = r.w; h = r.h }
        var rect: CropRect { CropRect(x: x, y: y, w: w, h: h) }
    }

    /// Reads the asked-for sections off a sidecar. Nil when none of them carries anything,
    /// which is how Copy Positive on a frame that has no positive turns into no copy at all
    /// rather than into a payload that would clear the target's positive.
    ///
    /// Note the asymmetry, and it is deliberate. Enhance and crop are copyable at their
    /// identity value (the paste then reads as "no enhance" / "no crop", which is a state a
    /// user can genuinely want to spread over a roll). The positive is not, because
    /// a null positive section would turn every target back into a negative, which is
    /// Reset Positive arriving through a paste rather than a copy of anything.
    /// `effective` is the develop layer the frame is being RENDERED through, which is the
    /// defaults when the sidecar carries none. Copy Positive copies what the user can see,
    /// so a copy from a frame nobody has edited yet carries the defaults rather than nothing.
    ///
    /// It stays a parameter rather than being resolved here because this type is pure: the
    /// defaults need the model's per-session snapshot and the profile library, and neither
    /// belongs in a pasteboard payload. `nil` means there is no answer at all (no library
    /// loaded), and then the positive section does not travel, which is the case
    /// `sourceWasPositive` and the partial-paste note still describe.
    static func copying(_ want: Set<FrameSettingsSection>, from s: Sidecar,
                        effective: DevelopSettings? = nil) -> FrameSettingsPayload? {
        var sections: [FrameSettingsSection] = []
        var payload = FrameSettingsPayload(sections: [])
        if want.contains(.positive), let d = s.develop ?? effective {
            sections.append(.positive)
            payload.positive = Develop(d)
        }
        if want.contains(.enhance) {
            sections.append(.enhance)
            payload.enhance = Enhance(sliders: s.enhance ?? .identity, look: s.look)
        }
        if want.contains(.crop) {
            sections.append(.crop)
            payload.crop = Geometry(s.geometry ?? GeometrySettings())
        }
        guard !sections.isEmpty else { return nil }
        payload.sections = sections
        // Still the source sidecar's own develop layer, deliberately, because the note this
        // feeds means "you asked for the positive and it could not travel". When `effective`
        // is supplied it always can, so `partialPasteNote`'s other condition (the positive
        // section absent from a payload that wanted it) is unreachable from the app's own
        // Copy. The note covers a payload written by an older build, and a deliberate Copy
        // Enhance still never shows it.
        payload.sourceWasPositive = s.develop != nil
        return payload
    }

    /// Applies the carried sections to one sidecar. Everything else is left exactly as it
    /// was, which is the whole contract of a partial paste.
    func applied(to s: Sidecar) -> Sidecar {
        var out = s
        if sections.contains(.positive), let p = positive {
            out = SidecarEdits.setDevelop(out, p.settings)
        }
        if sections.contains(.enhance) {
            let e = enhance?.sliders ?? .identity
            // The same normalization `SidecarEdits.setEnhance` applies (identity is stored
            // as no enhance layer at all), with the look kept rather than dropped.
            out.enhance = e.isIdentity ? nil : e
            // Except the Auto record: it says the wand read THIS frame, and pasted
            // values were read from another one, so Auto stays dim on the target.
            out.look = enhance?.look == SidecarEdits.autoLookID ? nil : enhance?.look
            // The Color Auto record goes for the same reason, whatever the target had.
            out.colorAuto = nil
        }
        if sections.contains(.crop) {
            out = SidecarEdits.setGeometry(out, crop?.settings ?? GeometrySettings())
        }
        return out
    }

    /// True when this blob is one of ours and a version we understand.
    var isUsable: Bool { app == Self.tag && version <= Self.currentVersion && !sections.isEmpty }

    // MARK: saying what a paste will and will not do

    /// The Paste item's wording, qualified when the payload carries no positive section so
    /// the menu says what it is about to do before it does it.
    ///
    /// Copy All is deliberately NOT disabled on an undeveloped frame: enhance and crop are
    /// worth copying off a negative and blocking that to protect the positive would cost
    /// more than it saves. The honesty is moved to the paste end instead.
    ///
    /// The title names the sections the payload HOLDS, so a Copy Enhance pastes as
    /// "Paste Settings (Enhance)". Plain when all three are there.
    var pasteMenuTitle: String {
        let held = FrameSettingsSection.allCases.filter { sections.contains($0) }
        guard held.count < FrameSettingsSection.allCases.count, !held.isEmpty else { return Self.plainPasteTitle }
        let names = held.map(\.title)
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "\(Self.plainPasteTitle) (\(list))"
    }

    static let plainPasteTitle = "Paste Settings"

    /// One line for the inspector after a paste that could not carry a positive, or nil
    /// when the paste carried everything it was asked for.
    ///
    /// Nil when `sourceWasPositive` is absent (an older payload) rather than guessing:
    /// a two-section payload written by a build that did not record the field is
    /// indistinguishable from a deliberate Copy Enhance plus Copy Crop, and a note that
    /// might be wrong is worse than no note.
    var partialPasteNote: String? {
        guard sourceWasPositive == false, !sections.contains(.positive) else { return nil }
        return Self.partialPasteNoteText
    }

    static let partialPasteNoteText =
        "Copied from a frame that was not developed, so only Enhance and Crop were pasted."

}

/// The general pasteboard, under a UTI of our own, so a copy survives across windows and
/// across a relaunch of the app, and so a second copy replaces the first.
enum FrameSettingsPasteboard {
    static let type = NSPasteboard.PasteboardType(FrameSettingsPayload.tag)

    static func write(_ payload: FrameSettingsPayload, to pasteboard: NSPasteboard = .general) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: type)
    }

    static func read(from pasteboard: NSPasteboard = .general) -> FrameSettingsPayload? {
        guard let data = pasteboard.data(forType: type),
              let payload = try? JSONDecoder().decode(FrameSettingsPayload.self, from: data),
              payload.isUsable else { return nil }
        return payload
    }

    /// Whether Paste Settings has anything to do. Read live, at the moment a menu is built.
    static func hasPayload(in pasteboard: NSPasteboard = .general) -> Bool {
        read(from: pasteboard) != nil
    }

    /// The wording for a Paste item, read live at the moment a menu is built. Falls back to
    /// the plain title with an empty pasteboard, where the item is disabled anyway.
    static func pasteMenuTitle(in pasteboard: NSPasteboard = .general) -> String {
        read(from: pasteboard)?.pasteMenuTitle ?? FrameSettingsPayload.plainPasteTitle
    }
}
