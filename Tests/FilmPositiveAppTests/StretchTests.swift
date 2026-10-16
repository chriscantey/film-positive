import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The Stretch control: the reference white density per stock, the kernel's blend and its
/// guards, the thin rule, the sidecar path into the kernel, the Tone row's Stretch, the
/// thin warning on the Tone icon, and that nothing automatic writes it.
///
/// What this suite cannot prove is that the view draws the row where it says.
final class StretchTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-stretch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: harness

    private func sidecar(_ stretch: Double?, stock: String = "kodak-ultramax-400") throws -> Sidecar {
        let image = scratch.appendingPathComponent("s-\(UUID().uuidString.prefix(6)).CR2")
        try Data(repeating: 0x42, count: 2048).write(to: image)
        var s = Sidecar(source: try SidecarStore.source(for: image))
        var d = DevelopSettings(stock: stock, tone: .none, autoBalance: true, base: BaseSettings(mode: .anchor))
        d.stretch = stretch
        s.develop = d
        return s
    }

    @MainActor
    private func freshModel(count: Int = 2) throws -> (AppModel, [Frame.ID]) {
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
    private func seed(_ model: AppModel, _ id: Frame.ID, tone: ToneMode = .none, stretch: Double? = nil) {
        model.undoManager.beginUndoGrouping()
        model.apply({ s in
            var develop = DevelopSettings(stock: "kodak-ultramax-400", tone: tone, autoBalance: true,
                                          base: BaseSettings(mode: .anchor))
            develop.stretch = stretch
            return SidecarEdits.setDevelop(s, develop)
        }, to: id, actionName: "seed")
        model.undoManager.endUndoGrouping()
    }

    /// The edit the row makes, over the selection, exactly as `InspectorView.setStretch`.
    @MainActor
    private func move(_ model: AppModel, to percent: Double) {
        model.applyToSelection({ StretchControl.edit($0, to: percent) }, actionName: StretchControl.actionName)
    }

    // MARK: 1. the reference per stock

    /// The installer's reading of the three Kodak curves, as shipped, to 0.001.
    func testTheShippedWhiteDensitiesReproduceTheCurveReadings() throws {
        let profiles = try ProfileLibrary.bundled()
        let expected = ["kodak-ultramax-400": 1.080, "kodak-vision3-250d": 1.243, "kodak-vision3-500t": 1.043]
        for (id, value) in expected {
            let shipped = try XCTUnwrap(profiles.films[id]?.whiteDensity, "\(id) ships no whiteDensity")
            XCTAssertEqual(shipped, value, accuracy: 0.0005, id)
        }
    }

    /// The lookup: a stock's own value, the generic constant for a stock with none, an
    /// unknown id, the generic literal and mono.
    func testTheWhiteDensityLookupFallsBackToGeneric() throws {
        let profiles = try ProfileLibrary.bundled()
        XCTAssertEqual(ProfileLibrary.genericWhiteDensity, 1.14)
        XCTAssertEqual(profiles.whiteDensity(for: "kodak-ultramax-400"), 1.08, accuracy: 1e-12)
        for id in ["generic", "unknown-color-negative", "bw-generic", "harman-switch-azure",
                   "no-such-stock-anywhere"] {
            XCTAssertNil(id == "no-such-stock-anywhere" ? nil : profiles.films[id]?.whiteDensity,
                         "\(id) carries a curve value, so this case tests nothing")
            XCTAssertEqual(profiles.whiteDensity(for: id), ProfileLibrary.genericWhiteDensity, id)
        }
    }

    /// A cross-processed alias takes the generic value although its target has a curve,
    /// and a plain alias takes its target's.
    func testACrossProcessedAliasTakesTheGenericWhiteDensity() throws {
        let profiles = try ProfileLibrary.bundled()
        XCTAssertEqual(profiles.whiteDensity(for: "kodak-vision3-500t"), 1.043, accuracy: 1e-12)
        XCTAssertFalse(profiles.crossProcessedAliases.isEmpty, "no cross-processed alias, so this asserts nothing")
        for alias in profiles.crossProcessedAliases where profiles.films[alias] == nil {
            XCTAssertEqual(profiles.whiteDensity(for: alias), ProfileLibrary.genericWhiteDensity, alias)
        }
        XCTAssertTrue(profiles.crossProcessedAliases.contains("reflx-lab-640t-ahu"))
        XCTAssertEqual(profiles.whiteDensity(for: "reflx-lab-640t-ahu"), ProfileLibrary.genericWhiteDensity)
        // A plain alias resolves to its target and takes its curve.
        if let (alias, target) = profiles.aliases.first(where: {
            !profiles.crossProcessedAliases.contains($0.key) && profiles.films[$0.key] == nil
                && profiles.films[$0.value]?.whiteDensity != nil
        }) {
            XCTAssertEqual(profiles.whiteDensity(for: alias), profiles.films[target]?.whiteDensity, alias)
        }
    }

    // MARK: 2. the blend

    /// Stretch 1 returns the measured code value itself over the whole code range.
    func testStretchOneIsTheIdentityBitForBit() {
        for q in stride(from: 0, through: 65535, by: 97) {
            XCTAssertEqual(DevelopMath.stretchedGreenCeiling(q, whiteDensity: 1.08, stretch: 1), q)
        }
    }

    /// A frame whose own range reaches the reference is untouched at every stretch.
    func testAFrameAtOrAboveTheReferenceIsUntouchedAtEveryStretch() {
        let white = 1.08
        let atRef = qOfD(white)
        let qs = [atRef, atRef + 1, qOfD(1.632), qOfD(2.5)]
        for q in qs {
            for s in stride(from: 0.0, through: 1.0, by: 0.05) {
                XCTAssertEqual(DevelopMath.stretchedGreenCeiling(q, whiteDensity: white, stretch: s), q,
                               "q \(q), s \(s)")
            }
        }
        XCTAssertEqual(DevelopMath.stretchedRange(own: 1.2, reference: 1.13, stretch: 0), 1.2)
    }

    /// The study's frame 0103: own range 0.165, reference range 1.130. Stretch 0.5 gives a
    /// ceiling of 0.382, and 0.75 leaves 0.618 of today's stretch.
    func testTheStudyNumbersForAThinFrame() {
        let o = 0.165, r = 1.130
        XCTAssertEqual(DevelopMath.stretchedRange(own: o, reference: r, stretch: 0.5) - 0.05, 0.382, accuracy: 0.0005)
        XCTAssertEqual(o / DevelopMath.stretchedRange(own: o, reference: r, stretch: 0.75), 0.618, accuracy: 0.0005)
        XCTAssertEqual(DevelopMath.stretchedRange(own: o, reference: r, stretch: 0), r, accuracy: 1e-12)
        // The code value path agrees with the range path.
        let ownQ = qOfD(0.115)
        let q = DevelopMath.stretchedGreenCeiling(ownQ, whiteDensity: 1.08, stretch: 0.5)
        XCTAssertEqual(dOfQ(q), 0.382, accuracy: 0.001)
    }

    /// Outside 0...1 the stretch is clamped, and a NaN reads as 1.
    func testTheStretchIsClampedOutsideZeroToOne() {
        let ownQ = qOfD(0.115)
        let zero = DevelopMath.stretchedGreenCeiling(ownQ, whiteDensity: 1.08, stretch: 0)
        XCTAssertNotEqual(zero, ownQ)
        XCTAssertEqual(DevelopMath.stretchedGreenCeiling(ownQ, whiteDensity: 1.08, stretch: -3), zero)
        XCTAssertEqual(DevelopMath.stretchedGreenCeiling(ownQ, whiteDensity: 1.08, stretch: 7), ownQ)
        XCTAssertEqual(DevelopMath.stretchedGreenCeiling(ownQ, whiteDensity: 1.08, stretch: .nan), ownQ)
        XCTAssertEqual(DevelopMath.stretchedGreenCeiling(ownQ, whiteDensity: 1.08, stretch: .infinity), ownQ)
        XCTAssertEqual(DevelopMath.clampedStretch(-0.5), 0)
        XCTAssertEqual(DevelopMath.clampedStretch(1.5), 1)
    }

    /// The kernel passes the stretched ceiling to the physics ranges, records the frame's own
    /// ceiling for the icon, and at stretch 1 is the render without the control.
    func testTheKernelUsesTheStretchedCeiling() {
        let frame = SceneFixtures.neutralScene(castRG: 1.0, castBG: 1.0)
        let plain = DevelopInput(ratios: BaseRatios(rg: 1, bg: 1), dyeGamma: .neutral, mono: false, autoTone: false)
        let rest = DevelopMath.analyze(frame, input: plain).0
        let ownQ = rest.percentile[1].hi
        // A reference far above this frame's own ceiling, so the frame is thin against it.
        var stretched = plain
        stretched.whiteDensity = dOfQ(ownQ) * 8 + 0.4
        stretched.stretch = 0.5
        let an = DevelopMath.analyze(frame, input: stretched).0
        XCTAssertEqual(an.physics[1].hi,
                       DevelopMath.stretchedGreenCeiling(ownQ, whiteDensity: stretched.whiteDensity, stretch: 0.5))
        XCTAssertGreaterThan(an.physics[1].hi, rest.physics[1].hi, "a higher ceiling, a darker frame")
        XCTAssertEqual(an.physics[1].lo, rest.physics[1].lo, "the floor never moves")
        XCTAssertEqual(an.stretch?.ownCeiling ?? .nan, dOfQ(ownQ), accuracy: 0, "the icon reads the own ceiling")
        XCTAssertEqual(an.stretch?.isThin, true)

        var full = stretched
        full.stretch = 1
        XCTAssertEqual(DevelopMath.analyze(frame, input: full).0.physics, rest.physics, "stretch 1 is today")
    }

    // MARK: 3. thin

    /// Thin is `o < r / 4`, tested at the edge.
    func testThinIsUnderAQuarterOfTheReference() {
        XCTAssertFalse(DevelopMath.isThin(ownRange: 0.25, referenceRange: 1.0), "exactly a quarter is not thin")
        XCTAssertTrue(DevelopMath.isThin(ownRange: 0.25.nextDown, referenceRange: 1.0))
        XCTAssertTrue(StretchReading(ownCeiling: 0.115, whiteDensity: 1.08).isThin, "0103")
        XCTAssertFalse(StretchReading(ownCeiling: 0.418, whiteDensity: 1.08).isThin, "0102, thin but fine")
        XCTAssertFalse(StretchReading(ownCeiling: 1.632, whiteDensity: 1.08).isThin, "0087")
    }

    // MARK: 4. persistence

    /// The sidecar value reaches the kernel through `developInput`, nil reading as 1, with
    /// the stock's own reference.
    func testTheSidecarStretchReachesTheKernel() throws {
        let svc = CPURenderService(profiles: try ProfileLibrary.bundled())
        var d = DevelopSettings(stock: "kodak-ultramax-400", tone: .none, autoBalance: false,
                                base: BaseSettings(mode: .anchor))
        XCTAssertEqual(svc.developInput(for: d).stretch, 1)
        XCTAssertEqual(svc.developInput(for: d).whiteDensity, 1.08, accuracy: 1e-12)
        d.stretch = 0.5
        XCTAssertEqual(svc.developInput(for: d).stretch, 0.5)
        d.stock = "reflx-lab-640t-ahu"
        XCTAssertEqual(svc.developInput(for: d).whiteDensity, ProfileLibrary.genericWhiteDensity)
    }

    /// The render cache key is the request, which holds `DevelopSettings` whole: two requests
    /// differing only in the stretch are different renders.
    func testTwoRequestsDifferingOnlyInStretchAreNotEqual() {
        let url = URL(fileURLWithPath: "/tmp/frame.CR2")
        var d = DevelopSettings(stock: "kodak-ultramax-400", tone: .none, autoBalance: true,
                                base: BaseSettings(mode: .anchor))
        let full = RenderRequest(imageURL: url, develop: d)
        d.stretch = 0.5
        let half = RenderRequest(imageURL: url, develop: d)
        XCTAssertNotEqual(full, half)
        XCTAssertEqual(half, RenderRequest(imageURL: url, develop: d))
    }

    /// The one writer: Full and non-finite store nil, the value is clamped, and it does not
    /// invent a develop layer.
    func testTheWriter() throws {
        let s = try sidecar(nil)
        XCTAssertEqual(SidecarEdits.setStretch(s, 0.5).develop?.stretch, 0.5)
        XCTAssertNil(SidecarEdits.setStretch(s, 1).develop?.stretch)
        XCTAssertNil(SidecarEdits.setStretch(s, 0.99999).develop?.stretch, "rounds to full at the file's grain")
        XCTAssertNil(SidecarEdits.setStretch(s, .nan).develop?.stretch)
        XCTAssertEqual(SidecarEdits.setStretch(s, -2).develop?.stretch, 0)
        XCTAssertNil(SidecarEdits.setStretch(s, 4).develop?.stretch)
        var bare = s
        bare.develop = nil
        XCTAssertNil(SidecarEdits.setStretch(bare, 0.5).develop)
    }

    /// The file: the attribute is written at 0.5 and absent at Full.
    func testTheSidecarCarriesTheAttributeOnlyWhenSet() throws {
        let store = SidecarStore()
        for stretch in [Optional(0.5), nil] {
            let image = scratch.appendingPathComponent("rt-\(UUID().uuidString.prefix(6)).CR2")
            try Data(repeating: 0x42, count: 2048).write(to: image)
            var s = Sidecar(source: try SidecarStore.source(for: image))
            s.develop = DevelopSettings(stock: "generic", tone: .none, autoBalance: true,
                                        base: BaseSettings(mode: .anchor))
            s = StretchControl.edit(s, to: (stretch ?? 1) * 100)
            _ = try store.save(s, for: image)
            let xml = try String(contentsOf: SidecarStore.sidecarURL(for: image), encoding: .utf8)
            XCTAssertEqual(xml.contains("FilmPositive:Stretch"), stretch != nil, "attribute exactly when set:\n\(xml)")
            XCTAssertEqual(try store.load(for: image)?.sidecar.develop?.stretch, stretch)
        }
    }

    // MARK: 5. the row

    /// The words: the display name, the poles, the undo name and the help. Every string that
    /// names the control is built from `ToneNames.stretch`, so a rename is one edit there.
    func testTheRowsWords() {
        let name = ToneNames.stretch
        XCTAssertFalse(name.isEmpty)
        XCTAssertFalse(name.contains("\u{2014}"), "no em-dash in app copy")
        XCTAssertEqual(StretchControl.lowLabel, "Off")
        XCTAssertEqual(StretchControl.highLabel, "Full")
        XCTAssertEqual(StretchControl.actionName, name)
        XCTAssertEqual(StretchControl.label, "\(name) Off \u{2194} Full")
        XCTAssertEqual(StretchControl.accessibilityLabel, "\(name), Off to Full")
        XCTAssertTrue(StretchControl.help.contains("thin"))
        XCTAssertTrue(StretchControl.help.contains("normal one alone"))
        XCTAssertFalse(StretchControl.help.contains("\u{2014}"), "no em-dash in app copy")
    }

    /// The drawn fill grows from Off at the left end, as on every other slider, so the bar is
    /// full at Full and empty at Off. The rest and the double-click reset stay Full.
    func testTheFillGrowsFromOff() throws {
        XCTAssertEqual(StretchControl.fillOrigin, StretchControl.off)
        XCTAssertEqual(StretchControl.fillOrigin, StretchControl.range.lowerBound, "the left end")
        XCTAssertNotEqual(StretchControl.fillOrigin, StretchControl.full)
        XCTAssertEqual(StretchControl.full, StretchControl.range.upperBound, "the rest is the right end")
        XCTAssertNil(StretchControl.reset(StretchControl.edit(try sidecar(nil), to: 50)).develop?.stretch,
                     "reset still returns Full")
    }

    /// The readout: Full at rest, else a whole percent.
    func testTheReadoutStrings() {
        XCTAssertEqual(StretchControl.readout(100), "Full")
        XCTAssertEqual(StretchControl.readout(99.6), "Full")
        XCTAssertEqual(StretchControl.readout(99.4), "99%")
        XCTAssertEqual(StretchControl.readout(60), "60%")
        XCTAssertEqual(StretchControl.readout(50), "50%")
        XCTAssertEqual(StretchControl.readout(0), "0%")
        XCTAssertEqual(StretchControl.readout(-0.2), "0%", "no negative zero")
        XCTAssertEqual(StretchControl.parse("50"), 50)
        XCTAssertEqual(StretchControl.parse(" 50 %"), 50)
        XCTAssertEqual(StretchControl.parse("full"), 100)
        XCTAssertEqual(StretchControl.parse("250"), 100, "clamped to the track")
        XCTAssertNil(StretchControl.parse("half"))
    }

    /// Nothing is written at Full, a move writes the fraction, double-click reset goes back
    /// to nil, and a frame already at the value comes back as the same sidecar.
    func testTheRowWritesNothingAtFull() throws {
        let s = try sidecar(nil)
        XCTAssertEqual(StretchControl.edit(s, to: 100), s, "nothing written at Full")
        let half = StretchControl.edit(s, to: 50)
        XCTAssertEqual(half.develop?.stretch, 0.5)
        XCTAssertEqual(StretchControl.edit(half, to: 50), half)
        XCTAssertNil(StretchControl.reset(half).develop?.stretch, "reset removes the value")
        XCTAssertNil(StretchControl.edit(half, to: 99.7).develop?.stretch, "what reads Full is stored as Full")
        XCTAssertEqual(StretchControl.value(half.develop!), 50, accuracy: 1e-12)
        XCTAssertEqual(StretchControl.value(s.develop!), 100)
    }

    /// The row sits under every tone: its value and its write do not depend on the tone, and
    /// a tone pick leaves it alone.
    @MainActor
    func testTheRowIsPresentUnderEveryTone() throws {
        let (model, ids) = try freshModel(count: 1)
        for mode in ToneNames.all {
            seed(model, ids[0], tone: mode)
            model.selection = [ids[0]]
            XCTAssertEqual(model.selectionSummary.stretch.value, 100, "\(mode): the row reads Full")
            move(model, to: 40)
            XCTAssertEqual(model.frame(ids[0])?.sidecar.develop?.stretch, 0.4, "\(mode): the row writes")
            model.applyToSelection({ ToneSlider.pick($0, mode == .flat ? .print : .flat) }, actionName: "Tone")
            XCTAssertEqual(model.frame(ids[0])?.sidecar.develop?.stretch, 0.4, "\(mode): a tone pick leaves it")
        }
        for open in [false, true] { XCTAssertEqual(ToneAdjustRows.shown(open: open), open) }
    }

    /// One drag is one undo step named Stretch, and Undo returns Full with no attribute.
    @MainActor
    func testOneDragIsOneUndoStepNamedStretch() throws {
        let (model, ids) = try freshModel(count: 2)
        for id in ids { seed(model, id) }
        model.selection = Set(ids)
        let coalescer = UndoCoalescer(model.undoManager)
        coalescer.begin(StretchControl.actionName)
        for v in stride(from: 90.0, through: 50.0, by: -10) { move(model, to: v) }
        coalescer.end()
        for id in ids { XCTAssertEqual(model.frame(id)?.sidecar.develop?.stretch, 0.5, "every selected frame") }
        XCTAssertEqual(model.undoManager.undoActionName, ToneNames.stretch)
        model.undoManager.undo()
        for id in ids { XCTAssertNil(model.frame(id)?.sidecar.develop?.stretch, "one undo took the drag back") }
    }

    /// A mixed selection says Multiple, and the Tone title is lit while any frame carries a
    /// value, the tone rows' rule.
    @MainActor
    func testMultipleAndTheLitRule() throws {
        let (model, ids) = try freshModel(count: 2)
        seed(model, ids[0])
        seed(model, ids[1])
        model.selection = Set(ids)
        XCTAssertFalse(model.selectionSummary.stretchInUse)
        XCTAssertFalse(DevelopRow.tone.lit(model.selectionSummary))
        model.selection = [ids[0]]
        move(model, to: 30)
        model.selection = Set(ids)
        XCTAssertTrue(model.selectionSummary.stretch.isMultiple)
        XCTAssertTrue(model.selectionSummary.stretchInUse)
        XCTAssertTrue(DevelopRow.tone.lit(model.selectionSummary), "one frame of two lights the title")
        var summary = SelectionSummary([])
        summary.stretchInUse = true
        XCTAssertTrue(DevelopRow.tone.lit(summary))
    }

    // MARK: 6. the icon

    /// A thin frame's words: how much it holds in stops (o x 3.32) and how many times it is
    /// stretched (r / o, rounded); a normal frame keeps today's icon and words.
    func testTheIconOnAThinAndANormalFrame() {
        let thin = StretchReading(ownCeiling: 0.115, whiteDensity: 1.08)
        let words = ToneThin.status(thin)
        XCTAssertTrue(words.contains("about 0.5 stops"), words)
        XCTAssertTrue(words.contains("about 7 times"), words)
        XCTAssertTrue(words.contains("\(ToneNames.stretch) slider under Tone"), words)
        XCTAssertFalse(words.contains("\u{2014}"))
        XCTAssertEqual(ToneThin.status([thin]), words)
        XCTAssertEqual(ToneThin.symbol(thin: true), "exclamationmark.triangle")

        let normal = StretchReading(ownCeiling: 1.632, whiteDensity: 1.08)
        XCTAssertNil(ToneThin.status([normal]), "a normal frame shows today's icon")
        XCTAssertNil(ToneThin.status([nil]), "no render yet, no warning")
        XCTAssertEqual(ToneThin.symbol(thin: false), "info.circle")
    }

    /// A warning that belongs to another selected frame says so; a thin lead gets its own.
    func testTheIconForAMultipleSelection() {
        let thin = StretchReading(ownCeiling: 0.115, whiteDensity: 1.08)
        let normal = StretchReading(ownCeiling: 1.632, whiteDensity: 1.08)
        let other = ToneThin.status([normal, thin, nil])
        XCTAssertEqual(other?.hasPrefix("1 of 3 frames hold very little"), true, other ?? "nil")
        XCTAssertEqual(ToneThin.status([thin, normal]), ToneThin.status(thin), "a thin lead speaks for itself")
        XCTAssertTrue(other?.contains("\(ToneNames.stretch) slider under Tone") == true, other ?? "nil")
    }

    /// The control's name lives in `ToneNames.stretch` alone: no other app source file
    /// carries it as a string literal, so a rename is a one-line edit. Comments are stripped,
    /// the scan `PositiveRowsTests` uses for retired names.
    func testTheNameAppearsInNoOtherSourceFileAsAString() throws {
        let name = ToneNames.stretch
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let target = root.appendingPathComponent("Sources/FilmPositive")
        let literal = try NSRegularExpression(
            pattern: "\"[^\"\\n]*\\b\(NSRegularExpression.escapedPattern(for: name))\\b[^\"\\n]*\"")
        var scanned = 0
        var sawConstant = false
        let walker = FileManager.default.enumerator(at: target, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            let code = ToneNamesTests.strippingComments(try String(contentsOf: url, encoding: .utf8))
            for (n, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let s = String(line)
                guard literal.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil else { continue }
                if url.lastPathComponent == "ToneNames.swift" { sawConstant = true; continue }
                XCTFail("\(url.lastPathComponent):\(n + 1) names the control as a literal: \(s)")
            }
        }
        XCTAssertGreaterThan(scanned, 10, "the source scan found almost nothing: wrong path?")
        XCTAssertTrue(sawConstant, "the scan must find the constant itself, or it proves nothing")
    }

    // MARK: nothing automatic writes it

    func testNoShippedProfileSetsItOnOpen() throws {
        let profiles = try ProfileLibrary.bundled()
        for film in profiles.films.values {
            let d = profiles.initialDevelop(capture: CaptureInfo(film: film.name, filmMaker: nil))
            XCTAssertEqual(d.stock, ProfileLibrary.genericStockName, "\(film.id) picked by name")
            XCTAssertNil(d.stretch, film.id)
        }
        XCTAssertNil(profiles.initialDevelop(capture: nil).stretch)
    }

    /// Every other verb, the wands' and the looks' included, leaves a set value where it is,
    /// and the stock change mutates the layer rather than rebuilding it.
    func testNoOtherEditVerbTouchesIt() throws {
        let s = try sidecar(0.4)
        var e = EnhanceSettings.identity
        e.contrast = 0.4
        var after: [(String, Sidecar)] = [
            ("setBase", SidecarEdits.setBase(s, BaseSettings(mode: .measured, measured: [1, 2, 3]))),
            ("setColourAxes", SidecarEdits.setColourAxes(s, ColourAxes(warm: 3))),
            ("setToneAdjust", SidecarEdits.setToneAdjust(s, ToneAdjust(exposure: 0.1, contrast: 1, black: 0, white: 1))),
            ("setEnhance", SidecarEdits.setEnhance(s, e)),
            ("applyAuto", SidecarEdits.applyAuto(s, e)),
            ("applyColorAuto", SidecarEdits.applyColorAuto(s, WarmthTint(warmth: 0.1, tint: 0))),
            ("setGeometry", SidecarEdits.setGeometry(s, GeometrySettings(rotate: 90, flip: false,
                                                                        straightenDegrees: 0, crop: nil))),
            ("resetEnhance", SidecarEdits.resetEnhance(s)),
            ("tone pick", ToneSlider.pick(s, .print)),
        ]
        for look in ShippedLooks.all { after.append(("look \(look.id)", SidecarEdits.applyLook(s, look))) }
        for (name, out) in after {
            XCTAssertEqual(out.develop?.stretch, 0.4, "\(name) moved the stretch")
        }
    }

    /// The model's wand and Detect Crop write paths, end to end on real sidecars: the
    /// Enhance wand, the Color Auto and a Detect Crop run each leave the field exactly as it
    /// was, set or unset.
    @MainActor
    func testTheWandAndDetectCropLeaveTheSidecarsStretchAlone() async throws {
        let (model, ids) = try freshModel(count: 2)
        seed(model, ids[0], stretch: 0.4)
        seed(model, ids[1])
        model.selection = Set(ids)
        let proposal = AutoEnhance.Proposal(blackPoint: 0.02, brightness: 0.1, highlights: -0.1,
                                            saturation: 0.05, vibrance: 0.05, warmth: 0.03, tint: -0.01)
        model.applyAutoEnhance(ids.map { ($0, proposal) })
        model.applyColorAuto(ids.map { ($0, WarmthTint(warmth: 0.05, tint: 0.02)) })
        let frames = try ids.map { try XCTUnwrap(model.frame($0)) }
        await model.runCrop(frames) { _ in
            GeometrySettings(rotate: 0, flip: false, straightenDegrees: 0.3, crop: nil)
        }
        XCTAssertNotNil(model.frame(ids[0])?.sidecar.enhance, "the wand wrote, so this asserts something")
        XCTAssertEqual(model.frame(ids[0])?.sidecar.geometry?.straightenDegrees ?? 0, 0.3, accuracy: 1e-9,
                       "the crop run wrote, so this asserts something")
        XCTAssertEqual(model.frame(ids[0])?.sidecar.develop?.stretch, 0.4, "a set value stays")
        XCTAssertNil(model.frame(ids[1])?.sidecar.develop?.stretch, "an unset one stays unset")
    }

    /// Copy and paste of the positive carries it, for the tone values' two reasons, and an
    /// older payload decodes to Full.
    func testCopyAndPasteOfThePositiveCarriesIt() throws {
        let payload = try XCTUnwrap(FrameSettingsPayload.copying([.positive], from: try sidecar(0.4)))
        let wire = try JSONDecoder().decode(FrameSettingsPayload.self, from: try JSONEncoder().encode(payload))
        XCTAssertEqual(wire.applied(to: try sidecar(nil)).develop?.stretch, 0.4)
        let plain = try XCTUnwrap(FrameSettingsPayload.copying([.positive], from: try sidecar(nil)))
        XCTAssertNil(plain.applied(to: try sidecar(0.4)).develop?.stretch)
        let enhanceOnly = try XCTUnwrap(FrameSettingsPayload.copying([.enhance], from: try sidecar(nil)))
        XCTAssertEqual(enhanceOnly.applied(to: try sidecar(0.4)).develop?.stretch, 0.4)
        let old = #"{"app":"co.wonders.filmpositive.settings","version":1,"sections":["positive"],"positive":{"stock":"generic","tone":"flat","autoTone":true,"base":{"mode":"anchor"}}}"#
        let decoded = try JSONDecoder().decode(FrameSettingsPayload.self, from: Data(old.utf8))
        XCTAssertNil(decoded.positive?.settings.stretch)
    }
}
