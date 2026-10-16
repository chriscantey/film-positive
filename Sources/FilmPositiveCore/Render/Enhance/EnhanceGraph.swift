import Foundation
import CoreImage
import CoreGraphics
import FilmSidecar

/// The enhance layer: one Core Image filter chain for preview and export.
///
/// It takes the developed 16-bit buffer rather than a CGImage, and it renders 16-bit out,
/// so preview and export share one depth as well as one chain. And it runs in a MANAGED
/// Core Image context with the input tagged sRGB: at this point the frame is
/// display-referred sRGB by construction (that is what develop produces), so tagging it is
/// correct, and the chain is tuned under exactly those semantics. The unmanaged context
/// exists for camera-space decode, which never reaches this stage.
///
/// ORDER IS THE DESIGN: tone before color before detail, because the same values in a
/// different order give a visibly different picture.
public struct CoreImageEnhance: EnhanceStage {
    /// One managed context, sRGB in and out, float working format so 16-bit output does
    /// not pass through 8-bit intermediates.
    static let context: CIContext = CIContext(options: [
        .workingFormat: CIFormat.RGBAf,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .cacheIntermediates: false,
    ])
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static let d65 = CIVector(x: 6500, y: 0)
    /// 2500 rather than something smaller because the warm direction is measurably weaker
    /// than the cool one (+1500K moves R-B by +16/255, -1500K by -28/255).
    static let warmthKelvinSpan: CGFloat = 2500
    /// The coolest source neutral `CITemperatureAndTint` still honors. Below it the whole
    /// call returns its input untouched and takes the user's tint with it. See the floor at
    /// the white-balance step for the measurement and why 2000 rather than the exact cliff.
    static let minSourceNeutralKelvin: CGFloat = 2000

    /// The source neutral the white-balance step asks for, in Kelvin, floored so the filter
    /// can never silently discard the call. Its own function so the floor is provable without
    /// rendering a frame.
    public static func sourceNeutral(warmth: Double) -> CGFloat {
        max(minSourceNeutralKelvin, 6500 + CGFloat(warmth) * warmthKelvinSpan)
    }
    static let tintSpan: CGFloat = 100

    /// The long side of a `.full` render (`RenderScale.full`, `RenderService.swift`).
    /// Every spatial radius in `chain` is quoted at THIS size and multiplied by the
    /// frame's own long side at call time.
    static let referenceLongSide: CGFloat = 5202

    /// Core Image's shadow adjust does nothing while its amount is inside about ±0.05, and
    /// switches on with a step there, so Shadows up to ±0.06 rendered as 0 (probe: a 0.01 step
    /// was bit for bit identity, the first change came at 0.07). Between amounts -0.105 and about
    /// -0.165 it also darkens LESS than at -0.104, so Shadows -0.13 darkened more than -0.14 to
    /// -0.20. Both are measured the same on a ramp and on two Gold frames. So Shadows under
    /// 0.07 either way crossfades from the frame to the filter at ±0.056, its first amount that
    /// acts, and Shadows -0.13 to -0.25 crossfades across the dip, from -0.104 to -0.2. Every
    /// other value is the single amount `0.8 * shadows`.
    static func shadowStops(_ v: Double, amount: Double) -> [(amount: Double, weight: Double)] {
        let a = abs(v), on = 0.07
        if v != 0 && a < on { let t = a / on; return [(0, 1 - t), (v < 0 ? -0.056 : 0.056, t)] }
        if v < -0.13 && v > -0.25 { let t = (a - 0.13) / 0.12; return [(-0.104, 1 - t), (-0.2, t)] }
        return [(amount, 1)]
    }

    /// The highlight amount does nothing above about 0.95, so Highlights -0.07 to 0 rendered
    /// as 0 (the first change came at -0.08). Highlights above -0.08 crossfades from the frame
    /// to the filter at 0.948. Every other value is the single amount passed in.
    static func highlightStops(_ v: Double, amount: Double) -> [(amount: Double, weight: Double)] {
        if v < 0 && v > -0.08 { let t = -v / 0.08; return [(1, 1 - t), (0.948, t)] }
        return [(amount, 1)]
    }

    /// A radius in pixels-at-full-scale, converted to pixels at this frame's scale.
    ///
    /// A constant pixel radius is a different neighborhood at every render scale, and
    /// the app renders at three (`.full` 5202 px, `.proxy` 2601, `.preview` 1300). The
    /// measured cost of leaving it constant: a drag preview crushed 2.6x more black than
    /// the export it was promising, and rendering full then halving diverged from halving
    /// then rendering by 1.167 units of 255 where a radius-free tone curve diverges by
    /// 0.004.
    ///
    /// The floor is half a pixel. Below that a blur radius is under the sampling limit and
    /// Core Image does not document what it does, and a synthetic test frame a few hundred
    /// pixels wide would otherwise ask for one.
    static func radius(_ atFullScale: CGFloat, _ ext: CGRect) -> CGFloat {
        max(0.5, atFullScale * max(ext.width, ext.height) / referenceLongSide)
    }

    public init() {}

    public func apply(_ frame: DecodedFrame, settings s: EnhanceSettings) throws -> DecodedFrame {
        if s.isIdentity { return frame }
        let input = Self.image(frame)
        let (ci, ext) = Self.chain(s, input)
        var rgba = [UInt16](repeating: 0, count: frame.width * frame.height * 4)
        rgba.withUnsafeMutableBytes { buf in
            Self.context.render(ci, toBitmap: buf.baseAddress!, rowBytes: frame.width * 8, bounds: ext,
                                format: .RGBA16, colorSpace: Self.srgb)
        }
        var out = [UInt16](repeating: 0, count: frame.width * frame.height * 3)
        rgba.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var i = 0, o = 0
                while i < src.count { dst[o] = src[i]; dst[o + 1] = src[i + 1]; dst[o + 2] = src[i + 2]; i += 4; o += 3 }
            }
        }
        return DecodedFrame(width: frame.width, height: frame.height, pixels: out)
    }

    static func image(_ f: DecodedFrame) -> CIImage {
        var rgba = [UInt16](repeating: 65535, count: f.width * f.height * 4)
        f.pixels.withUnsafeBufferPointer { src in
            rgba.withUnsafeMutableBufferPointer { dst in
                var s = 0, d = 0
                while s < src.count { dst[d] = src[s]; dst[d + 1] = src[s + 1]; dst[d + 2] = src[s + 2]; s += 3; d += 4 }
            }
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: f.width * 8, size: CGSize(width: f.width, height: f.height),
                       format: .RGBA16, colorSpace: srgb)
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v < lo ? lo : v > hi ? hi : v }

    /// The filter chain, one implementation for preview and export. `stop` ends it just
    /// before a tone step, which is the picture that step's histogram describes.
    static func chain(_ p: EnhanceSettings, _ input: CIImage,
                      stoppingBefore stop: EnhanceToneStage? = nil) -> (CIImage, CGRect) {
        var ci = input
        let ext = ci.extent

        // 1. Exposure first: the closest thing to changing the light. +/-2 EV at full slider.
        if p.exposure != 0 {
            ci = ci.applyingFilter("CIExposureAdjust", parameters: ["inputEV": p.exposure * 2.0])
        }

        // 2. Radiance, on its own local tone pass: a tone table per slider value plus an edge
        // keeping detail term in L*. See `RadianceOperator` for the math.
        //
        // It stays its own pass, separate from Shadows and Highlights in step 2b. Folded into
        // their expressions it would share one clamped budget with them, and moving either
        // slider at full Radiance would stop doing anything.
        //
        // Skipped entirely at 0, so a frame with no Radiance renders bit for bit as without it.
        if p.radiance != 0 {
            ci = Self.radiance(ci, amount: p.radiance, ext: ext)
        }

        // 2b. Shadows and Highlights, each with the whole of its own budget.
        let shadowAmt = clamp(p.shadows * 0.8, -1, 1)
        // inputHighlightAmount is 0...1 with 1.0 untouched; LOWER recovers. Only the
        // negative half of Highlights maps here; positive is a tone-curve job (step 3).
        //
        // The floor is 0.35. At 0.1, below Apple's own recommended slider floor of 0.3, the
        // control did everything useful in the first tenth of the travel: on a real frame
        // the clipped white went from 2.96 percent to zero by Highlights -0.1, and every
        // further step just darkened the whole frame (p90 0.7525 to 0.6598 at -1). A floor
        // of 0.35 keeps the recovery and stops spending the rest of the slider on nothing.
        let highlightAmt = clamp(1.0 + min(p.highlights, 0) * 0.65, 0, 1)
        // The filter has dead zones, so where a slider would land in one the output is a
        // crossfade between the two nearest amounts that act (`shadowStops`, `highlightStops`).
        // Everywhere else it is one filter call, with the amounts above.
        let ss = Self.shadowStops(p.shadows, amount: shadowAmt), hs = Self.highlightStops(p.highlights, amount: highlightAmt)
        if ss.count > 1 || hs.count > 1 || shadowAmt != 0 || highlightAmt != 1.0 {
            let source = ci, r = radius(12.0, ext)
            func adjust(_ s: Double, _ h: Double) -> CIImage {
                s == 0 && h == 1 ? source : source.applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputShadowAmount": s, "inputHighlightAmount": h, "inputRadius": r,
                ])
            }
            func mix(_ stops: [(image: CIImage, weight: Double)]) -> CIImage {
                guard stops.count == 2 else { return stops[0].image }
                return stops[0].image.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: stops[1].image, kCIInputTimeKey: stops[1].weight,
                ])
            }
            ci = mix(hs.map { h in (mix(ss.map { (adjust($0.amount, h.amount), $0.weight) }), h.weight) })
        }

        // 3. Black point, and the positive half of Highlights, as a tone curve: a remap of
        // where the ends of the range sit.
        //
        // Black Point is a LEVELS remap, not a toe. A curve that moves points 0 and 1 and
        // pins points 2, 3 and 4 can never touch anything above mid grey: at +1 it took the
        // 5th percentile to 0 and moved p50 by 0.004, where Apple's own definition is that a
        // black point "can improve the contrast in a washed-out image", which needs the whole
        // range restretched. It also makes the spline overshoot on the way back to the pinned
        // points, brightening the upper midtones and darkening the highlights by up to 0.014
        // with nobody asking for it.
        //
        // All five points sit on one straight line, so there is no overshoot left to
        // have: positive is `out = (in - b) / (1 - b)` with `b = blackPoint * 0.25`, and
        // negative is `out = lift + in * (1 - lift)` with `lift = -blackPoint * 0.20`.
        // Only one of `b` and `lift` is ever nonzero, so one pair of expressions covers
        // both directions.
        if p.blackPoint != 0 || p.highlights > 0 {
            let b = CGFloat(max(p.blackPoint, 0) * 0.25)
            let lift = CGFloat(max(-p.blackPoint, 0) * 0.20)
            // At 0.12 the positive half moves p90 from 0.7525 to 0.8295 at full slider. At
            // 0.25 the same frame reaches 0.9124.
            let hi = CGFloat(max(p.highlights, 0) * 0.25)
            func x(_ i: CGFloat) -> CGFloat { b + (1 - b) * i / 4 }
            func y(_ i: CGFloat) -> CGFloat { lift + (1 - lift) * i / 4 }
            // The Highlights push rides on the two upper points of whatever line Black
            // Point has drawn, which is what keeps the two controls independent.
            ci = ci.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: x(0), y: y(0)),
                "inputPoint1": CIVector(x: x(1), y: y(1)),
                "inputPoint2": CIVector(x: x(2), y: min(1.0, y(2) + hi * 0.25)),
                "inputPoint3": CIVector(x: x(3), y: min(1.0, y(3) + hi * 0.7)),
                "inputPoint4": CIVector(x: x(4), y: y(4)),
            ])
        }

        // 4. Global contrast and brightness, after the local work.
        //
        // Neither is `CIColorControls`, which Apple documents as
        // `(color.rgb - 0.5) * contrast + 0.5` and `color.rgb + brightness`. Core Image's
        // default working space is linear-light extended sRGB and the app never overrides
        // it, so that 0.5 pivot sits at sRGB 0.735 and that brightness is a constant added
        // in linear light. Measured on a real frame: Contrast +1 crushed 19 to 30 percent
        // of the pixels to pure black, Contrast -1 lifted the darkest one percent to 54
        // percent grey and removed 63 percent of the chroma, and Brightness +1 lifted the
        // black floor to 0.59 and stripped 52 percent of the chroma. None of that is what
        // the two controls are called.
        //
        // Contrast is a tone curve, which Apple applies in a perceptual version of the
        // working space, so its pivot is display-referred 0.5 where the name says it is.
        // Brightness is a gamma, so it moves the midtones and leaves both ends pinned
        // instead of sliding the whole range into a rail.
        if p.contrast != 0 {
            let d = CGFloat(p.contrast) * 0.09
            ci = ci.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 - d),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + d),
                "inputPoint4": CIVector(x: 1, y: 1),
            ])
        }
        if p.brightness != 0 {
            // 0.7 at +1 and 1/0.7 at -1, which is the 1.43 the assessment measured, and
            // exactly 1.0 at 0. A power of a power is smooth across the whole travel and
            // symmetric by construction, where a linear interpolation between 0.7 and 1.43
            // would not be.
            ci = ci.applyingFilter("CIGammaAdjust", parameters: ["inputPower": pow(0.7, CGFloat(p.brightness))])
        }

        // 4b. Levels, then Curves: the last of the tone, before any color. Both work in
        // display encoding (see ToneStages.swift) and each is skipped at identity, so a frame
        // with neither renders bit for bit as without them.
        if stop == .levels { return (ci.cropped(to: ext), ext) }
        if !p.levels.isIdentity { ci = Self.levels(ci, p.levels) }
        if stop == .curves { return (ci.cropped(to: ext), ext) }
        if !p.curves.isIdentity { ci = Self.curves(ci, p.curves) }

        // 5. White balance before saturation. Direction verified empirically on a neutral
        // grey: raising the source neutral ABOVE D65 is what warms the result.
        if p.warmth != 0 || p.tint != 0 {
            // The source neutral is floored, and the floor is a DEFECT FIX rather than a
            // taste decision.
            //
            // Below a source neutral somewhere in (1750 K, 2000 K], `CITemperatureAndTint`
            // returns its input bit for bit. Warmth and tint are the x and y of ONE call, so
            // when it no-ops it discards the tint the user set as well: warmth -2 with tint
            // 1.0 measures byte-identical to the untouched control, while warmth 0 with tint
            // 1.0 does not, and warmth -2 with saturation 1.0 still saturates, so it is this
            // call specifically and not a whole-stage bailout. Unfloored, warmth -2.6 asks for
            // 0 K and -3.0 asks for MINUS 1000 K, which is not a color temperature at all.
            //
            // 2000 K rather than the exact cliff: -1.8 is the coolest setting measured to
            // still work, and the cliff sits between there and -1.9. Conservative on purpose.
            //
            // Costs nothing that was ever stored. `EnhanceControl.range` is -1...1, clamped
            // on write, so no sidecar ever written can hold a warmth below -1.0, which is
            // 4000 K. Every existing file renders through this line exactly as before, and
            // the two controls keep their joint behavior because they stay one call: they
            // interact strongly enough that splitting them would change existing pictures.
            let shifted = CIVector(x: Self.sourceNeutral(warmth: p.warmth), y: CGFloat(p.tint) * tintSpan)
            ci = ci.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": shifted, "inputTargetNeutral": d65])
        }

        // 6. Vibrance before saturation, so it judges the film's own color.
        if p.vibrance != 0 {
            ci = ci.applyingFilter("CIVibrance", parameters: ["inputAmount": p.vibrance])
        }
        // Saturation is eased on the way up and not on the way down. Spending the whole of
        // Apple's own recommended slider for this filter (0 to 2) in one travel with no gamut
        // handling makes +1 multiply ColorChecker skin chroma by 2.2x to 2.3x and nearly
        // triple the clipped-white area of a real frame, 2.96 percent to 7.83 on one and 5.98
        // to 16.81 on another, growing at a steady rate the whole way up with no sign of
        // tapering. It does not only add color, it burns out the highlight while it does it.
        //
        // The negative side keeps its full coefficient, so -1 is still true monochrome.
        // The silver and overcast looks depend on that exactly.
        if p.saturation != 0 {
            let amount = p.saturation > 0 ? 1.0 + p.saturation * 0.6 : 1.0 + p.saturation
            ci = ci.applyingFilter("CIColorControls", parameters: ["inputSaturation": amount])
        }

        // 6b. Glow and Halation, light spilling around the highlights. After tone and color,
        // so they spread the picture the person has graded, and BEFORE Definition and
        // Sharpness, because sharpening a halo draws an edge back into it and undoes it. Both
        // are 0...1 nominally. A negative value has no meaning (there is no "anti halo"), so
        // it is clamped to 0 here rather than inverted. A typed value past 1 is honored, as
        // every other field is.
        //
        // Softness goes first of the three: the lens is softer before the light reaches the
        // film, and halation happens in the film. It too sits before Definition and
        // Sharpness on purpose, so a person can soften and then put an edge back.
        let softness = max(p.softness, 0)
        if softness > 0 {
            ci = Self.softened(ci, amount: softness, ext: ext)
        }
        let glow = max(p.glow, 0)
        if glow > 0 {
            ci = Self.glow(ci, amount: glow, ext: ext)
        }
        let halation = max(p.halation, 0)
        if halation > 0 {
            ci = Self.halation(ci, amount: halation, ext: ext)
        }

        // 7. Definition: local contrast at a LARGE radius, midtone structure not edges.
        //
        // Positive only. `CIUnsharpMask` treats a negative intensity as 0: Definition -0.5
        // and -1.0 render byte-identical to 0, mean absolute difference 0.0, so the left half
        // of the field would be a dead zone that looks like a softener and is not one. It is
        // clamped here so the chain says what the filter does. Softening is its own control
        // (Softness, above).
        if p.definition > 0 {
            ci = ci.applyingFilter("CIUnsharpMask", parameters: ["inputRadius": radius(20.0, ext), "inputIntensity": p.definition * 0.6])
        }
        if p.sharpness != 0 {
            ci = ci.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": p.sharpness * 0.8, "inputRadius": radius(2.0, ext)])
        }
        // 8. Noise reduction last among the detail ops.
        if p.noiseReduction > 0 {
            ci = ci.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": p.noiseReduction * 0.04, "inputSharpness": 0.4])
        }
        if p.vignette != 0 {
            // In the stored value positive lightens, so every saved frame keeps its meaning.
            // The slider shows it negated. Size and Softness only shape it, so with Amount at
            // 0 this stage is skipped whatever they hold.
            ci = Self.vignette(ci, amount: -p.vignette, ext: ext,
                               size: p.vignetteSize, softness: p.vignetteFeather)
        }

        // Blur-backed filters return a larger extent; crop back or the frame grows.
        return (ci.cropped(to: ext), ext)
    }

    /// Radiance through `RadianceProcessorKernel`. The kernel only throws when it is built
    /// wrong (a missing argument, a format Core Image did not honor), which is deterministic
    /// and fails every render test that sets Radiance, so it cannot ship unseen. The fallback
    /// is the frame without Radiance and a log line, rather than a crash in the middle of a
    /// drag.
    static func radiance(_ ci: CIImage, amount: Double, ext: CGRect) -> CIImage {
        do {
            return try RadianceProcessorKernel.apply(
                withExtent: ext, inputs: [ci],
                arguments: RadianceProcessorKernel.arguments(amount: amount, extent: ext))
        } catch {
            NSLog("Radiance pass failed, rendering without it: \(error)")
            return ci
        }
    }

    // MARK: Glow and Halation
    //
    // Every number below is the APP'S OPINION of a pleasing effect, chosen by eye on a set
    // of frames, not a fact about any film or lens. Film teaches the method (light above a
    // threshold spreads, and on film the spread is red). It does not hand us these
    // constants. They are quoted at the full-size reference like every radius in the chain.
    //
    // The work runs in Core Image's working space, which is linear light, so a threshold
    // here is a threshold on light, which is what a lens or an emulsion responds to.

    /// Rec. 709 luminance into all three channels.
    static let luminance: [String: Any] = [
        "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
    ]

    /// Glow: where the soft ramp starts (linear luminance, about sRGB 0.6), the blur radius
    /// at full size, and how much light full slider adds back.
    static let glowKnee: CGFloat = 0.35
    static let glowRadius: CGFloat = 30
    static let glowGain: CGFloat = 0.8

    /// Halation: only light above this linear luminance (about sRGB 0.93, the top few
    /// percent of a normal frame) feeds the halo, a WIDE radius, and a red-orange tint
    /// (red strongest, green low, blue almost none), the color of light that went through
    /// the base and came back into the red-sensitive layer.
    static let halationThreshold: CGFloat = 0.85
    static let halationRadius: CGFloat = 45
    static let halationTint = (r: CGFloat(1.0), g: CGFloat(0.28), b: CGFloat(0.04))
    static let halationGain: CGFloat = 2.5

    /// The highlight pass is blurred at this fraction of the frame's size and scaled back.
    /// 1 means full size. See `blurred`.
    static let bloomScale: CGFloat = 1

    /// A soft-edged luminance mask, 0 below `knee` rising to 1 at white.
    static func mask(_ ci: CIImage, from knee: CGFloat) -> CIImage {
        let k = 1 / (1 - knee)
        return ci.applyingFilter("CIColorMatrix", parameters: luminance)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -knee * k, y: -knee * k, z: -knee * k, w: 0),
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
    }

    /// A Gaussian blur at a full-size radius, on a transparent surround so no light enters
    /// from outside the frame.
    static func blurred(_ ci: CIImage, radius r: CGFloat, ext: CGRect) -> CIImage {
        let sigma = radius(r, ext)
        guard bloomScale < 1 else {
            return ci.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": sigma])
        }
        let down = CGAffineTransform(scaleX: bloomScale, y: bloomScale)
        return ci.transformed(by: down)
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": max(0.5, sigma * bloomScale)])
            .transformed(by: down.inverted())
    }

    /// Scale each channel by a gain, as a color matrix.
    static func scaled(_ ci: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
        ci.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// Adds light to the frame.
    ///
    /// NOT `CIAdditionCompositing`: Core Image composites premultiplied, so that adds alpha
    /// too, an opaque halo over an opaque frame comes out at alpha 2, and the output color
    /// conversion divides by it and multiplies back after the curve. That lifted the
    /// untouched dark ground by 4721 of 65535 on the first test run. Zeroing the halo's
    /// alpha does not work either, because the color matrix works on unpremultiplied color
    /// and premultiplies its result, so a zero alpha zeroes the light. The linear dodge
    /// blend adds the colors and composites alpha as source-over, which keeps it at 1.
    static func addingLight(_ light: CIImage, to ci: CIImage) -> CIImage {
        light.applyingFilter("CILinearDodgeBlendMode", parameters: [kCIInputBackgroundImageKey: ci])
    }

    /// Softness: the frame blended with a blurred copy of itself, which lowers fine detail
    /// everywhere, a soft-focus lens rather than a diffusion filter (Glow spreads only the
    /// highlights). Up to 1 the slider is the blend; past 1 the blend stays whole and the
    /// blur widens with the value, so a typed 2 is softer than 1 rather than the same.
    /// The radius is the app's opinion, quoted at full size.
    static let softnessRadius: CGFloat = 8

    static func softened(_ ci: CIImage, amount: Double, ext: CGRect) -> CIImage {
        let sigma = radius(softnessRadius * CGFloat(max(1, amount)), ext)
        // Clamped to the extent first, so the border does not blur toward transparent black.
        let soft = ci.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": sigma])
            .cropped(to: ext)
        return ci.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: soft, kCIInputTimeKey: min(amount, 1),
        ])
    }

    // MARK: Vignette
    //
    // An ellipse fitted to the extent this stage receives, which is the cropped frame, so an
    // elliptical distance of 1 is the middle of every edge whatever the shape. `CIVignette`
    // is a CIRCLE in pixels: on a 3:2 frame the long sides darken twice as far in as the
    // short ones (measured on a 1200 by 600 grey frame at -1: the left edge's midpoint read
    // 12111, the top edge's 27931, and a point 300 px in from the left the same as the top
    // edge).
    //
    // `amount` positive darkens toward the edges, negative lightens, through one mask. The
    // slider's direction is flipped in the SLIDER (`EnhanceControl.sign`), not in the stored
    // value, because flipping the render would reverse every frame already vignetted. The
    // numbers are the app's opinion, set to about the strength `CIVignette` has.

    /// Where the falloff starts and where it reaches full strength, in elliptical distance
    /// from the center (1 is an edge's midpoint, 1.414 a corner).
    static let vignetteInner: CGFloat = 0.25
    static let vignetteOuter: CGFloat = 1.35
    /// How far the corners travel at full strength, toward black or toward white.
    static let vignetteReach: CGFloat = 0.85

    // MARK: Vignette Size and Softness
    //
    // THE APP'S OPINION, the way Glow's constants are. The falloff above is a band from
    // `vignetteInner` to `vignetteOuter` (0.25 to 1.35). Size moves the band, Softness
    // widens or narrows it about its middle, both in the same elliptical distance:
    //
    //     s = clamp(size, -1, 1), f = clamp(softness, -1, 1)   (non-finite reads as 0)
    //     shift = -0.40 * s
    //     grow  =  0.55 * (1.8^f - 1)
    //     inner = max(0, 0.25 + shift - grow)
    //     outer =        1.35 + shift + grow
    //
    // Size right pulls the band in toward the center (at +1 it runs from the center to 0.95,
    // inside an edge's midpoint), Size left pushes it out so only the corners darken (at -1
    // it starts at 0.65, and a corner gets about half the weight). Softness right widens the
    // band to 1.8 times its width (0 to 1.79 at Size 0), left narrows it to 1 / 1.8 of it
    // (0.49 to 1.11, a band 0.61 wide, still about 30 percent of a frame's width, so the edge
    // is harder but never an aliased step).
    //
    // Every radius is legal for `CIRadialGradient` across the whole range, typed values
    // included, because both inputs are clamped first: inner is at least 0, and outer exceeds
    // it by at least 1.1 / 1.8 = 0.61 while inner is unclamped, and is at least 0.8 when the
    // max holds inner at 0 (that needs grow above 0.25 + shift, so outer > 1.6 + 2 * shift).
    // At Size 0 and Softness 0 the shift and the growth are exactly 0, and so the radii are
    // exactly the two constants above.
    static let vignetteSizeShift: CGFloat = 0.40
    static let vignetteSoftnessRatio: CGFloat = 1.8

    /// The band's inner and outer radius, in elliptical distance, for a Size and a Softness.
    static func vignetteRadii(size: Double, softness: Double) -> (inner: CGFloat, outer: CGFloat) {
        func unit(_ v: Double) -> CGFloat { v.isFinite ? CGFloat(min(max(v, -1), 1)) : 0 }
        let s = unit(size), f = unit(softness)
        let shift = -vignetteSizeShift * s
        let grow = (vignetteOuter - vignetteInner) / 2 * (pow(vignetteSoftnessRatio, f) - 1)
        return (max(0, vignetteInner + shift - grow), vignetteOuter + shift + grow)
    }

    /// The weight, 0 at the center and rising toward the corners, as an image over `ext`.
    /// Size and Softness at 0 build exactly the mask of the default band.
    static func vignetteMask(_ ext: CGRect, size: Double = 0, softness: Double = 0) -> CIImage {
        vignetteField(ext, size: size, softness: softness).cropped(to: ext)
    }

    /// The same weight, uncropped: an infinite image, so a test can read the falloff past the
    /// frame's edge, where at Size 0 most of the band lies.
    static func vignetteField(_ ext: CGRect, size: Double = 0, softness: Double = 0) -> CIImage {
        let hw = ext.width / 2, hh = ext.height / 2
        let radii = vignetteRadii(size: size, softness: softness)
        let ring = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputRadius0": radii.inner * hw,
            "inputRadius1": radii.outer * hw,
            "inputColor0": CIColor(red: 0, green: 0, blue: 0),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ])!.outputImage!
        // A circle of the frame's half width, squashed to its half height, is the ellipse
        // through the four edge midpoints. Squared so the onset is soft.
        let oval = ring
            .transformed(by: CGAffineTransform(scaleX: 1, y: hh / hw))
            .transformed(by: CGAffineTransform(translationX: ext.midX, y: ext.midY))
        return oval.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: oval])
    }

    /// `size` and `softness` shape the mask and leave the amount math alone: how far
    /// the corners travel is still `amount` times `vignetteReach`.
    static func vignette(_ ci: CIImage, amount: Double, ext: CGRect,
                         size: Double = 0, softness: Double = 0) -> CIImage {
        let t = CGFloat(min(abs(amount), 1)) * vignetteReach
        // The frame at the corners' full strength: scaled toward black, or toward white.
        let keep = 1 - t, lift = amount > 0 ? 0 : t
        let edge = ci.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: keep, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: keep, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: keep, w: 0),
            "inputBiasVector": CIVector(x: lift, y: lift, z: lift, w: 0),
        ])
        return edge.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: ci, kCIInputMaskImageKey: vignetteMask(ext, size: size, softness: softness),
        ]).cropped(to: ext)
    }

    /// Glow: a diffusion filter on the lens. The highlights, color kept, weighted by a
    /// soft ramp, blurred, and added back.
    static func glow(_ ci: CIImage, amount: Double, ext: CGRect) -> CIImage {
        let lit = ci.applyingFilter("CIMultiplyCompositing",
                                    parameters: [kCIInputBackgroundImageKey: mask(ci, from: glowKnee)])
        let a = CGFloat(amount) * glowGain
        let spread = scaled(blurred(lit, radius: glowRadius, ext: ext), r: a, g: a, b: a)
        return addingLight(spread, to: ci)
    }

    /// Halation: what film does. Only the brightest light, spread wide, tinted red-orange,
    /// added back.
    static func halation(_ ci: CIImage, amount: Double, ext: CGRect) -> CIImage {
        let a = CGFloat(amount) * halationGain
        let t = halationTint
        let halo = scaled(blurred(mask(ci, from: halationThreshold), radius: halationRadius, ext: ext),
                          r: t.r * a, g: t.g * a, b: t.b * a)
        return addingLight(halo, to: ci)
    }
}
