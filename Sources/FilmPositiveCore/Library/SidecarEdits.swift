import Foundation
import FilmSidecar

/// The state model's edit vocabulary: the sidecar struct in memory is the single
/// source of truth per image, and every edit is a value-type diff applied to it. These are
/// the diffs the inspector, the looks row and the reset commands make, written once here.
/// Each returns the new value. The undo stack keeps the old one and registers the inverse
/// from the pair.
public enum SidecarEdits {
    /// Reset Positive clears the develop layer and nothing else.
    /// The frame goes back to the negative, and its enhance layer and look name stay in the
    /// sidecar, dormant: nothing renders a frame with no develop layer, so they act on
    /// nothing until the frame is made positive again, and then they apply as they were.
    /// Geometry and the capture block stay too.
    public static func resetDevelop(_ s: Sidecar) -> Sidecar {
        var out = s
        out.develop = nil
        return out
    }

    /// Reset enhance clears only the enhance layer, the look name and the Color Auto record.
    /// Develop stays.
    public static func resetEnhance(_ s: Sidecar) -> Sidecar {
        var out = s
        out.enhance = nil
        out.look = nil
        out.colorAuto = nil
        return out
    }

    /// Changing develop never touches enhance: the graph re-renders with enhance
    /// still applied downstream.
    public static func setDevelop(_ s: Sidecar, _ develop: DevelopSettings) -> Sidecar {
        var out = s
        out.develop = develop
        return out
    }

    /// The eyedropper's write, and the ONE writer of `develop.base` in the app.
    ///
    /// `BaseResolver.resolve` gives a sidecar pair precedence over everything except a
    /// monochrome stock (rung 1 of three), so writing measured ratios here is what makes a
    /// hand-picked base beat the film edge. Clearing the pair hands the frame back to the
    /// edge reader, which is the whole of Clear Base.
    ///
    /// A sidecar with NO develop layer is returned unchanged. In the app that branch is
    /// unreachable through `AppModel.apply`, which seeds the effective defaults before the
    /// edit runs, so `develop` is always there by the time this sees it. The
    /// guard is here for a direct caller and for the shape of the function: inventing a
    /// whole develop layer around one measured pair would be guessing at the stock, which
    /// is the funnel's job and not this one's.
    public static func setBase(_ s: Sidecar, _ base: BaseSettings) -> Sidecar {
        guard var develop = s.develop else { return s }
        develop.base = base
        var out = s
        out.develop = develop
        return out
    }

    /// The two manual color axes, written IN PLACE on an existing develop layer, exactly as
    /// `setBase` is and for the same reason: they are one field of a develop layer, not a
    /// reason to invent one.
    ///
    /// A sidecar with no develop layer comes back unchanged. The axes grade a positive and
    /// there is no positive to grade, so building a develop layer here would be guessing at
    /// the stock, which is the funnel's job (see `DevelopDefaults`).
    ///
    /// This is the ONLY writer of `develop.colourAxes` in the app, and that is the whole
    /// design: it is reachable from the inspector rows and from nowhere else, so no
    /// automatic step can move a grade the person set. `ColourAxisAutoWriteTests` asserts
    /// that rather than trusting this comment.
    public static func setColourAxes(_ s: Sidecar, _ axes: ColourAxes) -> Sidecar {
        guard var develop = s.develop else { return s }
        develop.colourAxes = axes
        var out = s
        out.develop = develop
        return out
    }

    /// The Tone row's Adjust, written in place on an existing develop layer like the
    /// color axes, and for the same reason a sidecar with no develop layer comes back
    /// unchanged.
    ///
    /// The four values are held to the sidecar's grain and to the sliders' spans
    /// (`ToneAdjust.normalised`), and four values that ARE the frame's tone preset are
    /// stored as nil. So a slider dragged back onto the preset leaves no attribute behind,
    /// and nil keeps meaning "the preset's own values" whichever way the frame got there.
    ///
    /// The one writer of `develop.toneAdjust` apart from the Tone picker, which clears it.
    /// Nothing automatic calls either (`ToneAdjustModelTests`).
    public static func setToneAdjust(_ s: Sidecar, _ adjust: ToneAdjust?) -> Sidecar {
        guard var develop = s.develop else { return s }
        let stored = adjust.flatMap { $0.normalised() }
        develop.toneAdjust = stored.flatMap { $0 == ToneAdjust.preset(for: develop.tone).normalised() ? nil : $0 }
        var out = s
        out.develop = develop
        return out
    }

    /// The Tone row's Stretch, written in place on an existing develop layer like the tone
    /// values, and a sidecar with no develop layer comes back unchanged.
    ///
    /// Clamped to 0...1, and a value that rounds to full (1 at the sidecar's 4 decimal grain)
    /// or a non-finite one is stored as nil, so a slider returned to Full leaves no attribute
    /// behind and nil keeps meaning "the frame's own ceiling".
    ///
    /// The one writer of `develop.stretch`. It is reachable from the Stretch row alone, so no
    /// automatic step (the wands, Auto Enhance, Detect Crop, a stock change) can move it
    /// (`StretchAutoWriteTests`).
    public static func setStretch(_ s: Sidecar, _ stretch: Double?) -> Sidecar {
        guard var develop = s.develop else { return s }
        develop.stretch = stretch.flatMap { v -> Double? in
            guard v.isFinite else { return nil }
            let clamped = min(max(v, 0), 1)
            return (clamped * 10_000).rounded() >= 10_000 ? nil : clamped
        }
        var out = s
        out.develop = develop
        return out
    }

    /// A slider edit. The look name is dropped because the sliders no longer match a preset.
    /// The Color Auto record survives only while Warmth and Tint still equal it, so a
    /// Warmth or Tint edit clears it and an edit to any other slider leaves it.
    public static func setEnhance(_ s: Sidecar, _ enhance: EnhanceSettings) -> Sidecar {
        var out = s
        out.enhance = enhance.isIdentity ? nil : enhance
        out.look = nil
        if let record = s.colorAuto, !record.isHeld(by: enhance) { out.colorAuto = nil }
        return out
    }

    /// Levels, written exactly as a slider is: through `setEnhance`, so the look name
    /// goes and the Color Auto record stays (Levels is neither Warmth nor Tint).
    public static func setLevels(_ s: Sidecar, _ levels: Levels) -> Sidecar {
        var e = s.enhance ?? .identity
        e.levels = levels
        return setEnhance(s, e)
    }

    /// The four tone curves, written as Levels is.
    public static func setCurves(_ s: Sidecar, _ curves: Curves) -> Sidecar {
        var e = s.enhance ?? .identity
        e.curves = curves
        return setEnhance(s, e)
    }

    /// Applying a look sets the sliders to the look's values and records its id.
    /// A look is not the Color Auto's write, so its record goes.
    public static func applyLook(_ s: Sidecar, _ look: Look) -> Sidecar {
        var out = s
        out.enhance = look.settings.isIdentity ? nil : look.settings
        out.look = look.id
        out.colorAuto = nil
        return out
    }

    /// The Color Auto's write: Warmth and Tint set to the neutralizer's pair, every
    /// other slider kept, and the pair recorded so the button lights.
    public static func applyColorAuto(_ s: Sidecar, _ pair: WarmthTint) -> Sidecar {
        var e = s.enhance ?? .identity
        e.warmth = pair.warmth
        e.tint = pair.tint
        var out = setEnhance(s, e)
        out.colorAuto = pair
        return out
    }

    /// A click on a lit Color Auto: Warmth and Tint back to 0 and the record gone,
    /// every other slider kept.
    public static func clearColorAuto(_ s: Sidecar) -> Sidecar {
        var e = s.enhance ?? .identity
        e.warmth = 0
        e.tint = 0
        var out = setEnhance(s, e)
        out.colorAuto = nil
        return out
    }


    /// The `look` value the Enhance Auto writes, so Auto lights the same way a Look
    /// chip does: the layer still holds what the wand wrote exactly while this is recorded,
    /// and any slider edit clears it through `setEnhance`. A dot never survives
    /// `LookStore.slug`, so no saved look can take this id.
    public static let autoLookID = "fp.auto"

    /// The Enhance Auto's write: the wand's values over a zeroed layer with the Auto
    /// record beside them.
    /// The wand writes Warmth and Tint of its own, which is not the Color Auto's write, so the
    /// Color Auto record goes whatever pair the wand landed.
    ///
    /// No wand writes Levels or Curves. They are the person's, like the color axes, so
    /// the wand's layer carries the frame's own, whatever `enhance` holds for them.
    public static func applyAuto(_ s: Sidecar, _ enhance: EnhanceSettings) -> Sidecar {
        var e = enhance
        e.levels = (s.enhance ?? .identity).levels
        e.curves = (s.enhance ?? .identity).curves
        var out = setEnhance(s, e)
        out.look = autoLookID
        out.colorAuto = nil
        return out
    }

    /// A click on a lit Enhance Auto: every slider back to 0 and the Auto record gone,
    /// as `resetEnhance` does, except that Levels and Curves stay: the wand never
    /// wrote them, so taking its write back must not take them either.
    public static func clearAuto(_ s: Sidecar) -> Sidecar {
        let held = s.enhance ?? .identity
        var e = EnhanceSettings()
        e.levels = held.levels
        e.curves = held.curves
        var out = s
        out.enhance = e.isIdentity ? nil : e
        out.look = nil
        out.colorAuto = nil
        return out
    }

    public static func setGeometry(_ s: Sidecar, _ geometry: GeometrySettings) -> Sidecar {
        var out = s
        out.geometry = geometry.isIdentity ? nil : geometry
        return out
    }

    /// The camera the frame was shot on, as the inspector's Metadata row edits it. The make
    /// is derived by the same function Tether uses at capture, so a name typed here exports
    /// exactly as the same name typed there.
    public static func setCamera(_ s: Sidecar, _ name: String?) -> Sidecar {
        editCapture(s) { $0.setCamera(name) }
    }

    /// The film name. METADATA ONLY: it never touches the develop layer, so the Stock picker
    /// keeps whatever it holds. A film name is resolved to a stock once, when the defaults
    /// are first committed, and never again.
    public static func setFilm(_ s: Sidecar, _ name: String?) -> Sidecar {
        editCapture(s) { $0.setFilm(name) }
    }

    /// The day the frame was shot, "YYYY-MM-DD". Metadata only, like the names above.
    /// Anything that is not a real day is refused here rather than written.
    public static func setTakenOn(_ s: Sidecar, _ day: String?) -> Sidecar {
        let valid = day.flatMap(CaptureInfo.validDay)
        if day != nil && valid == nil { return s }
        return editCapture(s) { $0.takenOn = valid }
    }

    /// An empty capture block is written as none at all, the same rule Tether follows.
    private static func editCapture(_ s: Sidecar, _ edit: (inout CaptureInfo) -> Void) -> Sidecar {
        var out = s
        var capture = s.capture ?? CaptureInfo()
        edit(&capture)
        out.capture = capture == CaptureInfo() ? nil : capture
        return out
    }
}

extension WarmthTint {
    /// Whether a layer still holds this Color Auto record, compared at the grain the
    /// file stores so a pair read back from disk still matches its sliders. An instance
    /// method on purpose: the vocabulary guards read every `public static func` in
    /// `SidecarEdits` as an edit, and this edits nothing.
    public func isHeld(by enhance: EnhanceSettings?) -> Bool {
        let e = enhance ?? .identity
        return abs(e.warmth - warmth) < 0.00005 && abs(e.tint - tint) < 0.00005
    }
}
