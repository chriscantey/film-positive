import XCTest
import CoreGraphics
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The inspector's plain-type assertions as XCTest.
///
/// The identical assertions also run inside the app through `InspectorChecks`, which
/// the inspector bench invokes.
///
/// `InspectorChecks.runAll` is the single body of assertions, so the two paths cannot
/// drift: this file drives it and then also spells out the cases worth failing
/// individually, which is what a test report should show.
final class InspectorLogicTests: XCTestCase {

    func testEveryInspectorCheckPasses() {
        let result = InspectorChecks.runAll(profiles: try? ProfileLibrary.bundled())
        XCTAssertTrue(result.failed.isEmpty, result.summary)
        XCTAssertGreaterThanOrEqual(result.passed.count, 42, "the suite lost assertions: \(result.summary)")
    }

    // MARK: the slider set

    /// The inspector must cover exactly the sidecar's slider SET, but not in the same ORDER:
    /// `sliderKeys` is the codec's index order and moving it would re-read every existing
    /// sidecar's contrast as its brightness, so the display order is separate from it and
    /// the orderings inside FilmSidecar are guarded in that package by EnhanceOrderingTests.
    func testTwentyControlsCoverTheSliderSet() {
        XCTAssertEqual(EnhanceControl.all.count, 20)
        XCTAssertEqual(Set(EnhanceControl.all.map(\.id)), Set(EnhanceControl.liveSliderKeys))
        XCTAssertEqual(EnhanceControl.retiredSliderKeys, ["richness"])
        XCTAssertTrue(EnhanceControl.coversSliderKeys)
        XCTAssertTrue(EnhanceControl.idsAreUnique)
        XCTAssertTrue(EnhanceControl.pathsAreUnique)
    }

    func testGroupsAreLightColorDetailInOrder() {
        XCTAssertEqual(EnhanceControl.group(.tone).map(\.id),
                       ["radiance", "exposure", "highlights", "shadows", "brightness", "contrast", "blackPoint"])
        XCTAssertEqual(EnhanceControl.group(.colour).map(\.id),
                       ["saturation", "vibrance", "warmth", "tint"])
        XCTAssertEqual(EnhanceControl.group(.detail).map(\.id),
                       ["definition", "sharpness", "noiseReduction", "glow", "halation", "softness"])
        XCTAssertEqual(EnhanceControl.group(.vignette).map(\.id), ["vignette", "vignetteSize", "vignetteFeather"])
    }

    /// The failure the decoupling exists to make impossible: a row moved in the inspector
    /// must not move a sidecar key. Asserted against a literal list, because comparing
    /// `sliderKeys` to anything derived from it would be comparing it to itself.
    func testTheSidecarKeyOrderIsUnchangedByTheDisplayOrder() {
        // The whole wire order, including Richness, which this app retired, and the
        // vignette's Size and Softness appended after it.
        XCTAssertEqual(EnhanceSettings.sliderKeys,
                       ["radiance", "exposure", "highlights", "shadows", "contrast",
                        "brightness", "blackPoint", "vibrance", "saturation", "warmth",
                        "tint", "definition", "sharpness", "noiseReduction", "vignette",
                        "glow", "halation", "softness", "richness", "vignetteSize", "vignetteFeather"],
                       "sliderKeys is the wire order every sidecar ever written indexes by")
        XCTAssertNotEqual(EnhanceControl.all.map(\.id), EnhanceSettings.sliderKeys,
                          "the display order now differs from the wire order, which is the point")
    }

    func testEachControlWritesOnlyItsOwnField() {
        for control in EnhanceControl.all {
            let moved = control.setting(.identity, to: 0.5)
            for (index, key) in EnhanceSettings.sliderKeys.enumerated() {
                XCTAssertEqual(moved.values[index], key == control.id ? 0.5 * control.sign : 0,
                               "\(control.id) also moved \(key)")
            }
        }
    }

    /// A typed number opens the control's range instead of being clipped, and the track
    /// rescales around it, so a value of 4.2 survives.
    ///
    /// A runaway value still has to be kept out of the render graph. The guard band and the
    /// non-finite refusal do that, both asserted here.
    func testSlidersKeepATypedValueAndStillResetToZero() {
        let control = EnhanceControl.all.first { $0.id == "exposure" }!
        XCTAssertEqual(control.setting(.identity, to: 4.2).exposure, 4.2)
        XCTAssertEqual(control.setting(.identity, to: -4.2).exposure, -4.2)
        XCTAssertEqual(control.setting(.identity, to: 1e9).exposure, EnhanceControl.storageLimit.upperBound)
        XCTAssertEqual(control.setting(control.setting(.identity, to: 4.2), to: .infinity).exposure, 4.2,
                       "a value that is not a number never reaches the settings")
        XCTAssertTrue(control.setting(control.setting(.identity, to: 0.8), to: 0).isIdentity)
    }

    // MARK: the stock list

    func testStockListCarriesGenericMonoAndAnUnprofiledCurrentStock() {
        let profiles = try? ProfileLibrary.bundled()
        let list = StockChoices.list(from: profiles, current: "kodak-gold-200")
        XCTAssertTrue(list.contains { $0.id == "generic" && $0.kind == .generic })
        XCTAssertTrue(list.contains { $0.id == ProfileLibrary.monoStockID && $0.kind == .mono })
        XCTAssertEqual(Set(list.map(\.id)).count, list.count, "a stock is listed twice")

        // The trap: an id with no profile file must stay selectable, or the picker
        // rewrites the sidecar the first time it is touched.
        let unknown = StockChoices.list(from: profiles, current: "ektacolor-pro-400")
        XCTAssertTrue(unknown.contains { $0.id == "ektacolor-pro-400" },
                      "an alias with no file of its own still has to be selectable")
        let stranger = StockChoices.list(from: profiles, current: "some-stock-we-never-heard-of")
        XCTAssertTrue(stranger.contains { $0.id == "some-stock-we-never-heard-of" && $0.kind == .unprofiled })
        // Carries the maker, so it sorts with the rest of Kodak rather than under E. The
        // grouping is tested in StockGroupingTests.
        XCTAssertEqual(StockChoices.prettify("ektacolor-pro-400"), "Kodak Ektacolor Pro 400")
    }

    // MARK: the histogram

    func testHistogramCountsSixteenBitSamples() {
        let flat = [UInt16](repeating: 32768, count: 300 * 3)
        let h = FrameHistogram(pixels: flat, width: 300, height: 1)
        XCTAssertEqual(h.red[128], 300)
        XCTAssertEqual(h.red.filter { $0 > 0 }.count, 1)
        XCTAssertEqual(h.sampleCount, 300)
    }

    func testHistogramChannelsAreIndependent() {
        var pixels = [UInt16]()
        for _ in 0..<100 { pixels += [0, 32768, 65535] }
        let h = FrameHistogram(pixels: pixels, width: 100, height: 1)
        XCTAssertEqual(h.red[0], 100)
        XCTAssertEqual(h.green[128], 100)
        XCTAssertEqual(h.blue[255], 100)
    }

    /// Relaxing the 16-bit guard in `FrameHistogram` must fail this and only this.
    func testHistogramRefusesAnEightBitImage() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(ctx.makeImage())
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertNil(FrameHistogram(image: image))
    }

    // MARK: labels

    func testBrillianceIsGoneFromEveryLabel() {
        for control in EnhanceControl.all {
            XCTAssertFalse(control.label.lowercased().contains("brilliance"))
            XCTAssertFalse(control.id.lowercased().contains("brilliance"))
        }
        // Radiance is the first row of Light, with the sparkles symbol.
        let radiance = EnhanceControl.all.first { $0.id == "radiance" }
        XCTAssertEqual(EnhanceControl.all.first?.id, "radiance")
        XCTAssertEqual(radiance?.label, "Radiance")
        XCTAssertEqual(radiance?.symbol, "sparkles")
        XCTAssertEqual(radiance?.group, .tone)
        XCTAssertEqual(radiance?.path, \EnhanceSettings.radiance)
        XCTAssertEqual(radiance?.sign, 1)
    }
}
