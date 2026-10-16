import Foundation
import CoreGraphics
import FilmSidecar
import FilmPositiveCore

/// The assertions over the inspector's plain types, written so they can run in two places:
/// inside the app from the inspector bench, and from the `FilmPositiveAppTests` target
/// (`InspectorLogicTests`).
///
/// Two of them are fault injections rather than confirmations: `histogramRefusesEightBit`
/// and `coversSliderKeys` fail if the thing they guard ever regresses, and the first one
/// runs against a real 8-bit image to prove it can fail rather than trusting that it would.
enum InspectorChecks {
    struct Result {
        var passed: [String] = []
        var failed: [String] = []

        mutating func expect(_ name: String, _ condition: Bool) {
            if condition { passed.append(name) } else { failed.append(name) }
        }

        var summary: String {
            let head = failed.isEmpty ? "all \(passed.count) passed" : "\(passed.count) passed, \(failed.count) FAILED"
            return failed.isEmpty ? head : head + ": " + failed.joined(separator: ", ")
        }
    }

    static func runAll(profiles: ProfileLibrary?) -> Result {
        var r = Result()

        // The twenty controls, grouped Light, Color, Detail, Vignette.
        r.expect("twenty controls", EnhanceControl.all.count == 20)
        r.expect("ids cover the sidecar slider set", EnhanceControl.coversSliderKeys)
        r.expect("ids unique", EnhanceControl.idsAreUnique)
        r.expect("key paths unique", EnhanceControl.pathsAreUnique)
        // The display order is not tied to the codec's index order.
        r.expect("light group holds seven in display order", EnhanceControl.group(.tone).map(\.id)
            == ["radiance", "exposure", "highlights", "shadows", "brightness", "contrast", "blackPoint"])
        r.expect("color holds four in display order", EnhanceControl.group(.colour).map(\.id)
            == ["saturation", "vibrance", "warmth", "tint"])
        r.expect("detail holds six", EnhanceControl.group(.detail).map(\.id)
            == ["definition", "sharpness", "noiseReduction", "glow", "halation", "softness"])
        r.expect("vignette holds amount, size, softness", EnhanceControl.group(.vignette).map(\.id)
            == ["vignette", "vignetteSize", "vignetteFeather"])
        r.expect("groups are Light, Color, Detail, Vignette",
                 EnhanceControl.Group.allCases.map(\.rawValue) == ["Light", "Color", "Detail", "Vignette"])
        r.expect("groups partition the set",
                 EnhanceControl.Group.allCases.flatMap { EnhanceControl.group($0) }.count == EnhanceControl.all.count)

        // "Brilliance" is gone from every label and id.
        r.expect("no Brilliance in any label or id",
                 !EnhanceControl.all.contains { $0.label.lowercased().contains("brilliance") || $0.id.lowercased().contains("brilliance") })
        r.expect("radiance is the first row of Light", EnhanceControl.group(.tone).first?.id == "radiance"
            && EnhanceControl.group(.tone).first?.label == "Radiance")

        // Each control writes its own field and nothing else.
        for control in EnhanceControl.all {
            let moved = control.setting(.identity, to: 0.5)
            let onlyThisOne = EnhanceSettings.sliderKeys.enumerated().allSatisfy { index, key in
                let expected = key == control.id ? 0.5 * control.sign : 0.0
                return moved.values[index] == expected
            }
            r.expect("\(control.id) writes only itself", onlyThisOne)
        }

        // Sliders SHOW -1...1 at rest, a typed value beyond it is kept, and a reset is
        // exactly 0. A typed number opens the range rather than being clipped. What still has
        // to hold is that a value which is not a number never gets stored.
        let exposure = EnhanceControl.all.first { $0.id == "exposure" }!
        let overshoot = exposure.setting(.identity, to: 4.2)
        let undershoot = exposure.setting(.identity, to: -4.2)
        r.expect("a typed value beyond the shown span is kept", overshoot.exposure == 4.2)
        r.expect("and in the other direction", undershoot.exposure == -4.2)
        r.expect("the guard band still bounds it",
                 exposure.setting(.identity, to: 1e9).exposure == EnhanceControl.storageLimit.upperBound)
        r.expect("a non-finite value is refused rather than stored",
                 exposure.setting(overshoot, to: .nan).exposure == 4.2)
        r.expect("reset gives identity", exposure.setting(overshoot, to: 0).isIdentity)

        // The stock list.
        let list = StockChoices.list(from: profiles, current: "kodak-gold-200")
        r.expect("color negative choice present", list.contains { $0.id == "generic" && $0.kind == .generic })
        r.expect("mono choice present", list.contains { $0.id == ProfileLibrary.monoStockID && $0.kind == .mono })
        r.expect("no duplicate stock ids", Set(list.map(\.id)).count == list.count)
        if profiles != nil {
            // No shipped stock is fitted. The entries that must be present are the datasheet
            // ones, and at least one of them has to carry dye gammas of its own off its
            // published curve rather than borrowing.
            r.expect("datasheet stocks present", list.contains {
                if case .curve = $0.kind { return true } else { return false }
            })
            r.expect("a stock reads its dye gammas off a published curve",
                     list.contains { $0.kind == .curve(measured: false) })
            r.expect("gold 200 listed once", list.filter { $0.id == "kodak-gold-200" }.count == 1)
        }
        // The trap this exists for: a sidecar naming a stock with no profile file must
        // still be selectable, or the picker rewrites it on first touch.
        // `ektacolor-pro-400` is an alias with no profile file of its own, carried as an
        // alias onto Portra 400. What is asserted is that the id is IN the list, whatever its
        // kind.
        let unknown = StockChoices.list(from: profiles, current: "ektacolor-pro-400")
        r.expect("an alias current stock is carried", unknown.contains { $0.id == "ektacolor-pro-400" })
        // And an id that is neither a profile nor an alias still falls through to unprofiled,
        // which is the branch that keeps a hand-edited sidecar selectable.
        let stranger = StockChoices.list(from: profiles, current: "some-stock-we-never-heard-of")
        r.expect("a stock we have never heard of is carried as unprofiled",
                 stranger.contains { $0.id == "some-stock-we-never-heard-of" && $0.kind == .unprofiled })
        // Kodak market names carry their maker, so they sort into the Kodak run instead of
        // under E.
        r.expect("unprofiled stock reads as a name", StockChoices.prettify("ektacolor-pro-400") == "Kodak Ektacolor Pro 400")
        r.expect("a known stock is not duplicated as unprofiled",
                 !list.contains { $0.id == "kodak-gold-200" && $0.kind == .unprofiled })

        // The histogram over a known 16-bit buffer.
        let flat = [UInt16](repeating: 32768, count: 300 * 3)
        let flatHistogram = FrameHistogram(pixels: flat, width: 300, height: 1)
        r.expect("flat gray lands in one bin", flatHistogram.red[128] == 300 && flatHistogram.red.filter { $0 > 0 }.count == 1)
        r.expect("all three channels counted", flatHistogram.green[128] == 300 && flatHistogram.blue[128] == 300)
        r.expect("sample count is the pixel count", flatHistogram.sampleCount == 300)

        var ramp = [UInt16]()
        for i in 0..<256 { ramp += [UInt16(i * 257), UInt16(i * 257), UInt16(i * 257)] }
        let rampHistogram = FrameHistogram(pixels: ramp, width: 256, height: 1)
        r.expect("a 256-step ramp fills every bin once", rampHistogram.red.allSatisfy { $0 == 1 })
        r.expect("channels are independent", channelsAreIndependent())

        r.expect("histogram refuses an 8-bit image", histogramRefusesEightBit())

        return r
    }

    /// A frame whose three channels differ must produce three different curves. A
    /// histogram that read one channel and copied it would pass every test above.
    private static func channelsAreIndependent() -> Bool {
        var pixels = [UInt16]()
        for _ in 0..<100 { pixels += [0, 32768, 65535] }
        let h = FrameHistogram(pixels: pixels, width: 100, height: 1)
        return h.red[0] == 100 && h.green[128] == 100 && h.blue[255] == 100
    }

    /// Fault injection: the histogram must return nil for an 8-bit image rather than
    /// drawing a plausible curve from the wrong buffer. Built here rather than assumed,
    /// because the whole point is that the failure would otherwise be invisible.
    private static func histogramRefusesEightBit() -> Bool {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8 * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = ctx.makeImage() else { return false }
        return image.bitsPerComponent == 8 && FrameHistogram(image: image) == nil
    }
}
