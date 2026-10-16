import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Tone: None, Flat, Print.
///
/// None is the raw inversion through the preset with no tone step. Flat is the anchored
/// operator, the scene-referred base to edit from. Print is Flat's placement followed by a
/// color paper's contrast (`PrintToneTests` carries the operator's own tests). All three are
/// live in both pickers.
final class ToneModeTests: XCTestCase {

    private func service() throws -> CPURenderService {
        CPURenderService(profiles: try ProfileLibrary.bundled())
    }

    private func develop(_ tone: ToneMode) -> DevelopSettings {
        DevelopSettings(stock: "kodak-gold-200",
                        tone: tone, autoBalance: true, base: BaseSettings(mode: .anchor))
    }

    /// The mapping into the kernel: whether a tone step runs at all, and which operator it
    /// is. Three modes, three distinct answers.
    func testToneDrivesTheDevelopInput() throws {
        let svc = try service()
        XCTAssertFalse(svc.developInput(for: develop(.none)).autoTone, "None runs no tone step")
        XCTAssertTrue(svc.developInput(for: develop(.flat)).autoTone)
        XCTAssertEqual(svc.developInput(for: develop(.flat)).autoToneOperator, .anchored)
        XCTAssertTrue(svc.developInput(for: develop(.print)).autoTone)
        XCTAssertEqual(svc.developInput(for: develop(.print)).autoToneOperator, .print)
    }

    /// The service-wide override still beats the sidecar. A run that has to reproduce one
    /// fixed operator across a whole set of frames cannot have individual sidecars voting,
    /// and the seam is only worth having if it actually wins. Exercised with `print` as
    /// the override rather than by naming a particular legacy operator, so this test does
    /// not have to be rewritten when one is retired.
    func testTheServiceOverrideBeatsTheSidecar() throws {
        let svc = try service()
        svc.autoToneOperator = .print
        for mode in [ToneMode.flat, .print] {
            XCTAssertEqual(svc.developInput(for: develop(mode)).autoToneOperator, .print)
        }
        svc.autoToneOperator = .anchored
        XCTAssertEqual(svc.developInput(for: develop(.print)).autoToneOperator, .print,
                       "with the override at its default the sidecar chooses again")
    }

    /// `autoTone` and `appliesTone` differ in exactly one case, and the difference is
    /// deliberate: the first is the legacy two-state accessor, the second is what the
    /// render and the legacy XMP attribute both read.
    func testTheTwoLegacyAccessorsDifferOnlyOnPrint() {
        XCTAssertEqual(develop(.none).autoTone, false)
        XCTAssertEqual(develop(.none).appliesTone, false)
        XCTAssertEqual(develop(.flat).autoTone, true)
        XCTAssertEqual(develop(.flat).appliesTone, true)
        XCTAssertEqual(develop(.print).autoTone, false)
        XCTAssertEqual(develop(.print).appliesTone, true)
    }

    /// None and Flat must render differently, or the control does nothing. Asserted on the
    /// analysis rather than on pixels because the tone step IS the analysis: a frame with
    /// no tone step carries none.
    func testNoneAndFlatProduceDifferentAnalyses() throws {
        let svc = try service()
        let frame = Self.gradient()
        let none = svc.developInput(for: develop(.none))
        let flat = svc.developInput(for: develop(.flat))
        let (analysisNone, _) = DevelopMath.analyze(frame, input: none)
        let (analysisFlat, _) = DevelopMath.analyze(frame, input: flat)
        XCTAssertNil(analysisNone.tone, "None must carry no tone step")
        XCTAssertNotNil(analysisFlat.tone, "Flat must carry one")
    }

    /// Print must differ from BOTH of the others in the rendered pixels, not just in the
    /// analysis. A control that produces the same picture as its neighbour is a control
    /// that does nothing, and Print sharing Flat's placement makes that the easy mistake
    /// to make here.
    func testPrintRendersDifferentlyFromFlatAndFromNone() throws {
        let svc = try service()
        let frame = Self.gradient()
        func render(_ mode: ToneMode) -> DecodedFrame {
            let input = svc.developInput(for: develop(mode))
            let (an, dens) = DevelopMath.analyze(frame, input: input)
            return DevelopMath.render(dens, analysis: an, flip: false, rotate: 0)
        }
        let none = render(.none), flat = render(.flat), printed = render(.print)
        XCTAssertNotEqual(printed.pixels, flat.pixels, "Print and Flat rendered the same picture")
        XCTAssertNotEqual(printed.pixels, none.pixels, "Print and None rendered the same picture")
        // and it differs in the right DIRECTION: Print is the one that adds contrast
        func spread(_ f: DecodedFrame) -> Int {
            let greens = stride(from: 1, to: f.pixels.count, by: 3).map { Int(f.pixels[$0]) }.sorted()
            return greens[Int(Double(greens.count - 1) * 0.9)] - greens[Int(Double(greens.count - 1) * 0.1)]
        }
        XCTAssertGreaterThan(spread(printed), spread(flat), "Print did not add contrast over Flat")
    }

    /// The app-side round trip. `SidecarTests` asserts the same thing inside the sidecar
    /// package; this one is here because the mode reaching the file is what makes Print
    /// survive a relaunch, and a new attribute that silently reads back as a default is
    /// the failure direction that hides.
    func testPrintSurvivesASidecarRoundTrip() throws {
        var settings = develop(.print)
        settings.autoBalance = false
        let source = SidecarSource(name: "IMG_0001.CR2", size: 1234, mtime: Date(timeIntervalSince1970: 0),
                                   fingerprint: "sha256:" + String(repeating: "0", count: 64))
        var sc = Sidecar(source: source)
        sc.develop = settings
        let back = try Sidecar.decode(try sc.encoded(), liveSource: source, strict: true)
        XCTAssertEqual(back.develop?.tone, .print)
        XCTAssertEqual(back.develop?.autoBalance, false)
        XCTAssertEqual(back.develop?.appliesTone, true)
        XCTAssertEqual(back.develop?.autoTone, false,
                       "the two-state accessor still cannot say print")
    }

    /// The exported metadata names the tone, and the two names that predate ToneMode keep
    /// their spellings so old exports and new ones stay comparable.
    func testExportMetadataNamesTheTone() throws {
        func render(_ tone: ToneMode) -> String {
            ExportMetadata.from(raw: nil, capture: nil, develop: develop(tone),
                                mode: .neutral, lookName: nil, appVersion: "0.1.0-test").render
        }
        XCTAssertEqual(render(.flat), "auto-tone")
        XCTAssertEqual(render(.none), "flat")
        XCTAssertEqual(render(.print), "print")
    }

    /// A sidecar written before ToneMode existed carries only AutoTone, and both of its
    /// states have to land on the right mode or every frame in the library re-renders.
    func testAnOldSidecarKeepsItsRender() {
        XCTAssertEqual(DevelopSettings(stock: "s", autoTone: true,
                                       base: BaseSettings(mode: .anchor)).tone, .flat)
        XCTAssertEqual(DevelopSettings(stock: "s", autoTone: false,
                                       base: BaseSettings(mode: .anchor)).tone, ToneMode.none)
    }

    /// Auto color (the `autoBalance` key) defaults to ON for a sidecar that has never
    /// heard of it, because every frame written before the field existed rendered with the
    /// base measured from the film edge when one was readable.
    func testAutoBalanceDefaultsOn() {
        XCTAssertTrue(DevelopSettings(stock: "s", base: BaseSettings(mode: .anchor)).autoBalance)
        XCTAssertTrue(DevelopSettings(stock: "s", autoTone: true,
                                      base: BaseSettings(mode: .anchor)).autoBalance)
    }

    static func gradient(width: Int = 96, height: Int = 64) -> DecodedFrame {
        var px = [UInt16](repeating: 0, count: width * height * 3)
        let full = Double(UInt16.max)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 3
                let v = 0.12 + 0.7 * Double(x) / Double(width - 1)
                px[i] = UInt16(v * 0.45 * full)
                px[i + 1] = UInt16(v * full)
                px[i + 2] = UInt16(v * 0.78 * full)
            }
        }
        return DecodedFrame(width: width, height: height, pixels: px)
    }

    // MARK: the mixed selection shows no segment selected

    /// The rule the segmented row is built on: a selection whose frames disagree selects
    /// NOTHING, and every other state selects the tone they share. There is no fourth
    /// segment, so there is no tag for one either.
    ///
    /// Why it has to be Optional rather than the mixed tag: handing a segmented picker a
    /// tag it is not rendering makes SwiftUI log an invalid selection and draw whatever it
    /// likes. nil is the one legal way to say none of these.
    func testTheTonePickerSelectsNothingOnAMixedSelection() {
        XCTAssertNil(InspectorView.tonePickerTag(for: .flat, isMultiple: true),
                     "a mixed selection selects no segment")
        XCTAssertNil(InspectorView.tonePickerTag(for: nil, isMultiple: true))
        for mode in ToneNames.all {
            XCTAssertEqual(InspectorView.tonePickerTag(for: mode, isMultiple: false), mode.rawValue)
        }
        // A selection with nothing recorded is not the same question as a disagreeing one,
        // and it also selects nothing rather than inventing a default segment here.
        XCTAssertNil(InspectorView.tonePickerTag(for: nil, isMultiple: false))
        // The mixed tag never reaches this picker again: it is not a segment.
        XCTAssertNotEqual(InspectorView.tonePickerTag(for: .flat, isMultiple: true),
                          SelectionSummary.mixedTag)
        XCTAssertTrue(InspectorView.toneMixedHelp.contains("different tones"))
    }
}
