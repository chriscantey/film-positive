import XCTest
import AppKit
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The Tone row's Adjust in the model: what a slider writes, what clears it, what carries
/// it, and that nothing automatic touches it. The kernel half is `ToneAdjustCoreTests`. What
/// this suite cannot prove is that the view draws the rows where it says.
final class ToneAdjustModelTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-tone-adjust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: harness

    @MainActor
    private func freshModel(count: Int = 3) throws -> (AppModel, [Frame.ID]) {
        let roll = scratch.appendingPathComponent("roll-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        for i in 1...count {
            try Data(repeating: 0x42, count: 64)
                .write(to: roll.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        let model = AppModel(service: CPURenderService(profiles: try ProfileLibrary.bundled()))
        model.undoManager.groupsByEvent = false
        XCTAssertNotNil(model.addFolder(roll))
        let ids = (model.selectedFolder?.frames ?? []).map(\.id)
        XCTAssertEqual(ids.count, count)
        return (model, ids)
    }

    @MainActor
    private func seed(_ model: AppModel, _ id: Frame.ID, tone: ToneMode, adjust: ToneAdjust? = nil) {
        model.undoManager.beginUndoGrouping()
        model.apply({ s in
            var develop = DevelopSettings(stock: "kodak-gold-200", tone: tone, autoBalance: true,
                                          base: BaseSettings(mode: .anchor))
            develop.toneAdjust = adjust
            return SidecarEdits.setDevelop(s, develop)
        }, to: id, actionName: "seed")
        model.undoManager.endUndoGrouping()
    }

    /// The edit a row makes, over the selection, exactly as `InspectorView.setToneSlider`
    /// issues it.
    @MainActor
    private func move(_ model: AppModel, _ slider: ToneSlider, to value: Double) {
        model.applyToSelection({ slider.edit($0, to: value) }, actionName: ToneSlider.actionName)
    }

    /// The pick the Tone control makes, as `InspectorView.toneBinding` issues it.
    @MainActor
    private func pick(_ model: AppModel, _ mode: ToneMode) {
        model.applyToSelection({ ToneSlider.pick($0, mode) }, actionName: "Tone")
    }

    @MainActor
    private func develop(_ model: AppModel, _ id: Frame.ID) -> DevelopSettings? {
        model.frame(id)?.sidecar.develop
    }

    private func sidecar(_ adjust: ToneAdjust?, tone: ToneMode = .flat) throws -> Sidecar {
        let image = scratch.appendingPathComponent("t-\(UUID().uuidString.prefix(6)).CR2")
        try Data(repeating: 0x42, count: 2048).write(to: image)
        var s = Sidecar(source: try SidecarStore.source(for: image))
        var d = DevelopSettings(stock: "generic", tone: tone, autoBalance: true, base: BaseSettings(mode: .anchor))
        d.toneAdjust = adjust
        s.develop = d
        return s
    }

    private let moved = ToneAdjust(exposure: -0.12, contrast: 1.4, black: 0.15, white: 0.95)

    // MARK: the readouts

    /// The numbers the rows show at each preset: Bold reads -1.00, 1.00, 20, 100 and Flat
    /// reads 0.00, 0.00, 20, 92.
    func testTheReadoutsAtEachPreset() {
        func read(_ mode: ToneMode) -> [String] {
            ToneSlider.allCases.map { $0.readout($0.value(in: ToneAdjust.preset(for: mode))) }
        }
        XCTAssertEqual(read(.print), ["-1.00", "1.00", "20", "100"])
        XCTAssertEqual(read(.flat), ["0.00", "0.00", "20", "92"])
        XCTAssertEqual(read(.none), ["0.00", "0.00", "0", "100"])
    }

    /// The spans, in the readout's unit, and every preset sits inside them.
    func testTheSpans() {
        XCTAssertEqual(ToneSlider.exposure.range, -2...2)
        XCTAssertEqual(ToneSlider.contrast.range, -1...1.5)
        XCTAssertEqual(ToneSlider.black.range, 0...40)
        XCTAssertEqual(ToneSlider.white.range, 60...100)
        for mode in [ToneMode.none, .flat, .print] {
            for slider in ToneSlider.allCases {
                XCTAssertTrue(slider.range.contains(slider.value(in: ToneAdjust.preset(for: mode))), "\(mode) \(slider)")
            }
        }
    }

    /// Each value written in the readout's unit reads back as itself, and lands where the
    /// stored unit says: Lighter is a NEGATIVE density, Harder a steeper slope.
    func testEachRowWritesItsOwnValueInTheStoredUnit() {
        let p = ToneAdjust.preset(for: .flat)
        XCTAssertEqual(ToneSlider.exposure.setting(p, to: 1).exposure, -0.30, accuracy: 1e-12)
        XCTAssertEqual(ToneSlider.contrast.setting(p, to: 1).contrast, 2.3, accuracy: 1e-12)
        XCTAssertEqual(ToneSlider.black.setting(p, to: 10).black, 0.10, accuracy: 1e-12)
        XCTAssertEqual(ToneSlider.white.setting(p, to: 97).white, 0.97, accuracy: 1e-12)
        for slider in ToneSlider.allCases {
            let v = slider.range.lowerBound + (slider.range.upperBound - slider.range.lowerBound) * 0.3
            XCTAssertEqual(slider.value(in: slider.setting(p, to: v)), v, accuracy: 1e-9, "\(slider)")
            // Past the end clamps to the end, and a NaN is dropped.
            XCTAssertEqual(slider.value(in: slider.setting(p, to: slider.range.upperBound + 50)),
                           slider.range.upperBound, accuracy: 1e-9)
            XCTAssertEqual(slider.setting(p, to: .nan), p)
        }
    }

    // MARK: what a slider writes

    /// A move from each preset writes all four values: the moved one, and the preset's own
    /// for the other three.
    @MainActor
    func testAMoveFromEachPresetWritesFourValues() throws {
        for mode in [ToneMode.none, .flat, .print] {
            let (model, ids) = try freshModel(count: 1)
            seed(model, ids[0], tone: mode)
            model.selection = [ids[0]]
            let p = ToneAdjust.preset(for: mode)
            move(model, .black, to: 10)
            let stored = try XCTUnwrap(develop(model, ids[0])?.toneAdjust, "\(mode): nothing was stored")
            XCTAssertEqual(stored, ToneAdjust(exposure: p.exposure, contrast: p.contrast, black: 0.10, white: p.white),
                           "\(mode)")
            XCTAssertEqual(develop(model, ids[0])?.tone, mode, "the tone itself did not move")
        }
    }

    /// Landing back on the preset stores nil, so no attribute is left behind.
    @MainActor
    func testLandingBackOnThePresetStoresNil() throws {
        let (model, ids) = try freshModel(count: 1)
        seed(model, ids[0], tone: .print)
        model.selection = [ids[0]]
        move(model, .exposure, to: -0.5)
        XCTAssertNotNil(develop(model, ids[0])?.toneAdjust)
        move(model, .exposure, to: -1)
        XCTAssertNil(develop(model, ids[0])?.toneAdjust, "Bold's own exposure is Bold, so nil")
        // And through a run of arrow steps whose sum is not exactly the preset in binary.
        var v = 0.0
        for _ in 0..<7 { v += 0.1 }   // 0.7000000000000001
        move(model, .contrast, to: v)
        for _ in 0..<6 { v += 0.05 }
        move(model, .contrast, to: v)
        XCTAssertNil(develop(model, ids[0])?.toneAdjust, "1.0000000000000002 units is Bold's contrast at the file's grain")
    }

    /// A double-click puts that one value back to the frame's own preset.
    @MainActor
    func testResetOneRowReturnsThatValueOnly() throws {
        let s = try sidecar(moved, tone: .flat)
        let out = ToneSlider.white.reset(s)
        XCTAssertEqual(out.develop?.toneAdjust,
                       ToneAdjust(exposure: moved.exposure, contrast: moved.contrast, black: moved.black, white: 0.92))
    }

    /// The black is kept 20 points under the white by the spans alone: the deepest white
    /// and the most lifted black still leave 20.
    func testBlackAndWhiteStayTwentyPointsApart() throws {
        var a = ToneAdjust.preset(for: .flat)
        a = ToneSlider.black.setting(a, to: 100)
        a = ToneSlider.white.setting(a, to: 0)
        XCTAssertGreaterThanOrEqual(ToneSlider.white.value(in: a) - ToneSlider.black.value(in: a), 20 - 1e-9)
    }

    // MARK: what clears it

    /// Picking a tone clears the values, so the rows jump to that preset. Picking the tone
    /// the frame already has clears them too, which is how a person goes back.
    @MainActor
    func testAPresetPickClears() throws {
        let (model, ids) = try freshModel(count: 2)
        for id in ids { seed(model, id, tone: .flat, adjust: moved) }
        model.selection = Set(ids)
        XCTAssertTrue(model.selectionSummary.toneAdjustInUse)

        pick(model, .flat)
        for id in ids {
            XCTAssertEqual(develop(model, id)?.tone, .flat)
            XCTAssertNil(develop(model, id)?.toneAdjust, "picking Flat again cleared the values")
        }
        XCTAssertFalse(model.selectionSummary.toneAdjustInUse)

        for id in ids { seed(model, id, tone: .flat, adjust: moved) }
        pick(model, .print)
        for id in ids {
            XCTAssertEqual(develop(model, id)?.tone, .print)
            XCTAssertNil(develop(model, id)?.toneAdjust, "a new tone starts at its own values")
        }
        let summary = model.selectionSummary
        XCTAssertEqual(ToneSlider.allCases.map { summary.value(for: $0).value.map($0.readout) },
                       ["-1.00", "1.00", "20", "100"], "the rows jumped to Bold")
    }

    @MainActor
    func testResetDevelopClears() throws {
        let (model, ids) = try freshModel(count: 1)
        seed(model, ids[0], tone: .print, adjust: moved)
        model.selection = [ids[0]]
        model.resetDevelopSelection()
        XCTAssertNil(develop(model, ids[0])?.toneAdjust)
        XCTAssertFalse(model.selectionSummary.toneAdjustInUse)
    }

    // MARK: undo

    /// One drag is one undo step: every tick inside the coalescer's group unwinds together.
    @MainActor
    func testOneDragIsOneUndoStep() throws {
        let (model, ids) = try freshModel(count: 2)
        for id in ids { seed(model, id, tone: .flat) }
        model.selection = Set(ids)
        let coalescer = UndoCoalescer(model.undoManager)
        coalescer.begin(ToneSlider.actionName)
        for v in stride(from: 0.1, through: 0.8, by: 0.1) { move(model, .exposure, to: v) }
        coalescer.end()
        XCTAssertEqual(develop(model, ids[0])?.toneAdjust?.exposure ?? 0, -0.24, accuracy: 1e-9)
        XCTAssertEqual(model.undoManager.undoActionName, ToneSlider.actionName)

        model.undoManager.undo()
        for id in ids { XCTAssertNil(develop(model, id)?.toneAdjust, "one undo took the whole drag back") }
        XCTAssertFalse(model.undoManager.canUndo == true && model.undoManager.undoActionName == ToneSlider.actionName,
                       "a second Tone Adjust step was left on the stack")
    }

    // MARK: the selection

    /// A mixed selection: Multiple on the row that differs only, the track parked on the
    /// preset, and a move writes the absolute value to every frame, each keeping its others.
    @MainActor
    func testAMixedSelectionSaysMultiplePerRowAndWritesAbsolutely() throws {
        let (model, ids) = try freshModel(count: 3)
        let blacks = [0.10, 0.20, 0.30]
        for (id, b) in zip(ids, blacks) {
            seed(model, id, tone: .flat, adjust: ToneAdjust(exposure: 0, contrast: 1, black: b, white: 0.92))
        }
        model.selection = Set(ids)
        let summary = model.selectionSummary
        XCTAssertTrue(summary.value(for: .black).isMultiple)
        XCTAssertFalse(summary.value(for: .white).isMultiple)
        XCTAssertEqual(summary.trackPosition(.black), 20, "parked on Flat's own black")

        move(model, .exposure, to: 0.5)
        for (id, b) in zip(ids, blacks) {
            let a = try XCTUnwrap(develop(model, id)?.toneAdjust)
            XCTAssertEqual(a.exposure, -0.15, accuracy: 1e-12)
            XCTAssertEqual(a.black, b, "each frame kept its own black")
        }
    }

    // MARK: the Tone title, where the Adjust word was

    /// Lit while ANY selected frame carries values; the rows show while open, and only then.
    @MainActor
    func testTheToneTitlesLitRule() throws {
        let (model, ids) = try freshModel(count: 2)
        for id in ids { seed(model, id, tone: .flat) }
        model.selection = Set(ids)
        XCTAssertFalse(model.selectionSummary.toneAdjustInUse, "no frame carries values")
        XCTAssertFalse(DevelopRow.tone.lit(model.selectionSummary))

        model.selection = [ids[0]]
        move(model, .white, to: 97)
        model.selection = Set(ids)
        XCTAssertTrue(model.selectionSummary.toneAdjustInUse, "one frame of two is enough")
        XCTAssertTrue(DevelopRow.tone.lit(model.selectionSummary), "the title reads lit")

        // Every state of open, in use and mono. Only the fold opens the rows; in use lights
        // the title; mono changes neither, since the tone rows act on black and white too.
        var cases: [(open: Bool, inUse: Bool, mono: Bool)] = []
        for open in [false, true] { for inUse in [false, true] { for mono in [false, true] {
            cases.append((open, inUse, mono))
        } } }
        XCTAssertEqual(cases.count, 8)
        for c in cases {
            let name = "open \(c.open), in use \(c.inUse), mono \(c.mono)"
            XCTAssertEqual(ToneAdjustRows.shown(open: c.open), c.open, name)
            var summary = SelectionSummary([])
            summary.toneAdjustInUse = c.inUse
            XCTAssertEqual(DevelopRow.tone.lit(summary), c.inUse, name)
        }
    }

    /// Move one Tone slider, close the row, and the sliders are gone while the title stays
    /// lit. Reopening shows the moved value, and neither press
    /// writes a sidecar or an undo step.
    @MainActor
    func testAClosedToneRowWithEditsHidesItsSliders() throws {
        let (model, ids) = try freshModel(count: 1)
        seed(model, ids[0], tone: .flat)
        model.selection = [ids[0]]
        model.toggleDevelopRow(.tone)
        XCTAssertTrue(ToneAdjustRows.shown(open: model.prefs.showsToneAdjust), "open to drag")
        move(model, .white, to: 97)
        let moved = model.selectionSummary.trackPosition(.white)
        let sidecar = model.frame(ids[0])?.sidecar
        let undoName = model.undoManager.undoActionName
        XCTAssertTrue(DevelopRow.tone.lit(model.selectionSummary))

        model.toggleDevelopRow(.tone)
        XCTAssertFalse(model.prefs.showsToneAdjust)
        XCTAssertFalse(ToneAdjustRows.shown(open: model.prefs.showsToneAdjust), "closed hides the sliders")
        XCTAssertTrue(DevelopRow.tone.lit(model.selectionSummary), "and the title stays lit")

        model.toggleDevelopRow(.tone)
        XCTAssertTrue(ToneAdjustRows.shown(open: model.prefs.showsToneAdjust))
        XCTAssertEqual(model.selectionSummary.trackPosition(.white), moved, "the edit is still there")
        XCTAssertEqual(model.frame(ids[0])?.sidecar, sidecar, "no sidecar changed")
        XCTAssertEqual(model.undoManager.undoActionName, undoName, "no undo step")
    }

    /// The fold is a remembered preference that writes no sidecar and no undo step.
    @MainActor
    func testTheToneTitleTogglesAPreferenceOnly() throws {
        let (model, ids) = try freshModel(count: 1)
        seed(model, ids[0], tone: .flat)
        let before = model.frame(ids[0])?.sidecar
        let undoable = model.undoManager.canUndo
        XCTAssertFalse(model.prefs.showsToneAdjust, "closed until someone opens it")
        model.toggleDevelopRow(.tone)
        XCTAssertTrue(model.prefs.showsToneAdjust)
        XCTAssertTrue(DevelopRow.tone.isOpen(model.prefs))
        XCTAssertEqual(model.frame(ids[0])?.sidecar, before)
        XCTAssertEqual(model.undoManager.canUndo, undoable)
        model.toggleDevelopRow(.tone)
        XCTAssertFalse(model.prefs.showsToneAdjust)
    }

    // MARK: copy and paste

    func testCopyAndPasteDevelopCarriesIt() throws {
        let payload = try XCTUnwrap(FrameSettingsPayload.copying([.positive], from: try sidecar(moved)))
        // Through the pasteboard's own encoding, as a real paste goes.
        let wire = try JSONDecoder().decode(FrameSettingsPayload.self, from: try JSONEncoder().encode(payload))
        XCTAssertEqual(wire.applied(to: try sidecar(nil)).develop?.toneAdjust, moved, "the values did not travel")
        // A source at its preset sets the target back to its preset, deliberately.
        let plain = try XCTUnwrap(FrameSettingsPayload.copying([.positive], from: try sidecar(nil)))
        XCTAssertNil(plain.applied(to: try sidecar(moved)).develop?.toneAdjust)
        // A payload written before the field existed decodes to nil.
        let old = #"{"app":"co.wonders.filmpositive.settings","version":1,"sections":["positive"],"positive":{"stock":"generic","tone":"flat","autoTone":true,"base":{"mode":"anchor"}}}"#
        let decoded = try JSONDecoder().decode(FrameSettingsPayload.self, from: Data(old.utf8))
        XCTAssertNil(decoded.positive?.toneAdjust)
    }

    /// A paste of Enhance alone never reaches the develop layer.
    func testPastingEnhanceOnlyLeavesIt() throws {
        let payload = try XCTUnwrap(FrameSettingsPayload.copying([.enhance, .crop], from: try sidecar(nil)))
        XCTAssertEqual(payload.applied(to: try sidecar(moved)).develop?.toneAdjust, moved)
    }

    // MARK: nothing automatic writes it

    func testNoShippedProfileSetsItOnOpen() throws {
        let profiles = try ProfileLibrary.bundled()
        let stocks = Array(profiles.films.values)
        XCTAssertGreaterThan(stocks.count, 1, "no profiles loaded, so this asserts nothing")
        for film in stocks {
            let d = profiles.initialDevelop(capture: CaptureInfo(film: film.name, filmMaker: nil))
            XCTAssertEqual(d.stock, ProfileLibrary.genericStockName, "\(film.id) picked by name")
            XCTAssertNil(d.toneAdjust, "\(film.id) shipped tone values")
        }
        XCTAssertNil(profiles.initialDevelop(capture: nil).toneAdjust)
    }

    /// Every other verb, including the wands' and the looks', leaves a set value where it is.
    func testNoOtherEditVerbTouchesIt() throws {
        let s = try sidecar(moved)
        var e = EnhanceSettings.identity
        e.contrast = 0.4
        var after: [(String, Sidecar)] = [
            ("setBase", SidecarEdits.setBase(s, BaseSettings(mode: .measured, measured: [1, 2, 3]))),
            ("setColourAxes", SidecarEdits.setColourAxes(s, ColourAxes(warm: 3))),
            ("setEnhance", SidecarEdits.setEnhance(s, e)),
            ("applyAuto", SidecarEdits.applyAuto(s, e)),
            ("applyColorAuto", SidecarEdits.applyColorAuto(s, WarmthTint(warmth: 0.1, tint: 0))),
            ("clearColorAuto", SidecarEdits.clearColorAuto(s)),
            ("setGeometry", SidecarEdits.setGeometry(s, GeometrySettings(rotate: 90, flip: false,
                                                                        straightenDegrees: 0, crop: nil))),
            ("resetEnhance", SidecarEdits.resetEnhance(s)),
        ]
        for look in ShippedLooks.all { after.append(("look \(look.id)", SidecarEdits.applyLook(s, look))) }
        for (name, out) in after {
            XCTAssertEqual(out.develop?.toneAdjust, moved, "\(name) moved the tone values")
        }
    }

    /// The writer does not invent a develop layer, and it stores a preset as nil.
    func testTheWriter() throws {
        var bare = try sidecar(nil)
        bare.develop = nil
        XCTAssertNil(SidecarEdits.setToneAdjust(bare, moved).develop)
        let s = try sidecar(nil, tone: .print)
        XCTAssertNil(SidecarEdits.setToneAdjust(s, ToneAdjust.preset(for: .print)).develop?.toneAdjust)
        XCTAssertEqual(SidecarEdits.setToneAdjust(s, moved).develop?.toneAdjust, moved)
        XCTAssertNil(SidecarEdits.setToneAdjust(s, nil).develop?.toneAdjust)
    }

    /// The sidecar round trip: the attribute is written when set and absent when not.
    func testTheSidecarCarriesTheAttribute() throws {
        let store = SidecarStore()
        for adjust in [Optional(moved), nil] {
            let image = scratch.appendingPathComponent("rt-\(UUID().uuidString.prefix(6)).CR2")
            try Data(repeating: 0x42, count: 2048).write(to: image)
            var s = Sidecar(source: try SidecarStore.source(for: image))
            var d = DevelopSettings(stock: "generic", tone: .flat, autoBalance: true, base: BaseSettings(mode: .anchor))
            d.toneAdjust = adjust
            s.develop = d
            _ = try store.save(s, for: image)
            let xml = try String(contentsOf: SidecarStore.sidecarURL(for: image), encoding: .utf8)
            XCTAssertEqual(xml.contains("ToneAdjust"), adjust != nil, "attribute present exactly when set:\n\(xml)")
            XCTAssertEqual(try store.load(for: image)?.sidecar.develop?.toneAdjust, adjust)
        }
    }

    // MARK: the words

    func testTheWordsAsShipped() {
        XCTAssertEqual(DevelopRow.tone.help(open: false), "Show the Tone sliders")
        XCTAssertEqual(DevelopRow.tone.help(open: true), "Hide the Tone sliders")
        XCTAssertEqual(ToneSlider.allCases.map(\.label),
                       ["Darker \u{2194} Lighter", "Softer \u{2194} Harder",
                        "Deeper \u{2194} Lifted", "Dimmer \u{2194} Brighter"])
        for slider in ToneSlider.allCases {
            XCTAssertTrue(slider.help.hasSuffix("."), "\(slider) help is not one sentence")
            XCTAssertEqual(slider.help.filter { $0 == "." }.count, 1, "\(slider) help is not one sentence")
            XCTAssertFalse(slider.help.contains("\u{2014}"), "no em-dashes")
        }
    }
}
