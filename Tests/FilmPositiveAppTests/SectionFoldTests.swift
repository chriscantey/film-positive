import XCTest
@testable import FilmPositive

/// The inspector's sections and Enhance's groups fold from their title, remembered app-wide.
/// Histogram and Metadata fold the same way. A fresh install opens every section but
/// Enhance, and every group inside Enhance.
final class SectionFoldTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-fold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: the pure rule

    /// With nothing stored: Develop, Frame, Metadata and Histogram open, Enhance closed, and
    /// everything inside Enhance open, so turning Enhance on shows all of it.
    func testTheDefaultClosesEnhanceAlone() {
        let closed: Set<InspectorSection> = [.enhance]
        XCTAssertEqual(SectionFold.defaultClosed, closed)
        for fold in [SectionFold(), SectionFold(stored: nil), SectionFold(stored: [:]), Preferences().sectionFold] {
            for section in InspectorSection.allCases {
                XCTAssertEqual(fold.isOpen(section), !closed.contains(section), "\(section) with nothing stored")
            }
        }
        for open in [InspectorSection.develop, .frame, .metadata, .histogram,
                     .looks, .light, .color, .levels, .curves, .detail, .vignette] {
            XCTAssertTrue(SectionFold().isOpen(open), "\(open) open by default")
        }
        XCTAssertFalse(SectionFold().isOpen(.enhance), "Enhance closed by default")
    }

    /// A toggle flips the one part it names and nothing else, and a second toggle undoes it.
    func testToggleFlipsOnlyThatPart() {
        let start = SectionFold()
        for section in InspectorSection.allCases {
            let once = start.toggled(section)
            for other in InspectorSection.allCases {
                XCTAssertEqual(once.isOpen(other), other == section ? !start.isOpen(other) : start.isOpen(other),
                               "\(section) toggled, \(other)")
            }
            XCTAssertEqual(once.toggled(section), start, "\(section) toggled twice is back where it was")
        }
    }

    func testTheStoredFormRoundTrips() {
        var fold = SectionFold()
        fold.toggle(.detail)
        fold.toggle(.develop)
        fold.toggle(.histogram)
        XCTAssertEqual(SectionFold(stored: fold.stored), fold)
        XCTAssertEqual(Set(fold.stored.keys), Set(InspectorSection.allCases.map(\.rawValue)),
                       "every part this build knows is written down, open or closed")
        XCTAssertEqual(fold.stored["histogram"], false, "open by default, so the toggle closed it")
        XCTAssertEqual(fold.stored["metadata"], true)
        XCTAssertEqual(fold.stored["develop"], false)
        XCTAssertEqual(fold.stored["enhance"], false)
        XCTAssertEqual(SectionFold(stored: SectionFold().stored), SectionFold())
        // Through JSON, the way `Preferences` keeps it.
        var p = Preferences()
        p.sectionFold = fold
        let back = try? JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back?.sectionFold, fold)
    }

    /// An id this build does not know is dropped, and a part the stored form does not name
    /// takes the default: the way a part added in a later build starts open unless the
    /// default names it, for someone who already has folds stored.
    func testUnknownIdsAreDroppedAndUnnamedPartsTakeTheDefault() {
        let fold = SectionFold(stored: ["frame": false, "no-such-part": false, "enhance": true])
        XCTAssertEqual(fold, SectionFold(closed: [.frame]))
        XCTAssertFalse(fold.stored.keys.contains("no-such-part"))
        let onlyDevelop = SectionFold(stored: ["develop": false])
        XCTAssertTrue(onlyDevelop.isOpen(.light), "an unnamed part that the default leaves open is open")
        XCTAssertTrue(onlyDevelop.isOpen(.metadata), "Metadata among them")
        XCTAssertFalse(onlyDevelop.isOpen(.enhance), "an unnamed part that the default closes is closed")
    }

    /// The stored ids are a file format: renaming a case would silently move every part
    /// anyone had folded.
    func testTheStoredIdsAreFixed() {
        XCTAssertEqual(InspectorSection.allCases.map(\.rawValue),
                       ["develop", "frame", "enhance", "looks", "light", "color", "detail", "histogram", "metadata",
                        "vignette",
                        // Appended after vignette.
                        "levels", "curves"])
    }

    /// The Vignette group's fold is not in the default, so it is open once Enhance is, and a
    /// fold stored before it (which names every part but Vignette) leaves it open while keeping
    /// everything it did name.
    func testTheVignetteFoldStartsOpenForEveryone() {
        XCTAssertFalse(SectionFold.defaultClosed.contains(.vignette))
        XCTAssertTrue(SectionFold().isOpen(.vignette))
        var older = SectionFold().toggled(.enhance).toggled(.detail).stored
        older.removeValue(forKey: "vignette")
        let read = SectionFold(stored: older)
        XCTAssertTrue(read.isOpen(.vignette), "a part the stored form does not name takes the default")
        XCTAssertFalse(read.isOpen(.detail), "and the parts it did name keep their state")
        XCTAssertTrue(read.isOpen(.enhance))
        let folded = SectionFold().toggled(.vignette)
        XCTAssertEqual(folded.stored["vignette"], false)
        XCTAssertEqual(SectionFold(stored: folded.stored), folded, "stored under the same key as the others")
    }

    /// Levels and Curves take Vignette's rule. Neither is in the default, so both are
    /// open once Enhance is, a fold stored before them (which names neither) leaves both open
    /// while keeping what it did name, and each is stored under its own id.
    func testTheLevelsAndCurvesFoldsStartOpenForEveryone() {
        for section in [InspectorSection.levels, .curves] {
            XCTAssertFalse(SectionFold.defaultClosed.contains(section))
            XCTAssertTrue(SectionFold().isOpen(section))
            var older = SectionFold().toggled(.enhance).toggled(.light).stored
            older.removeValue(forKey: "levels")
            older.removeValue(forKey: "curves")
            let read = SectionFold(stored: older)
            XCTAssertTrue(read.isOpen(section), "\(section): a part the stored form does not name takes the default")
            XCTAssertFalse(read.isOpen(.light), "and the parts it did name keep their state")
            XCTAssertTrue(read.isOpen(.enhance))
            let folded = SectionFold().toggled(section)
            XCTAssertEqual(folded.stored[section.rawValue], false)
            XCTAssertEqual(SectionFold(stored: folded.stored), folded, "\(section): stored by id like the others")
            XCTAssertTrue(folded.isOpen(section == .levels ? .curves : .levels), "each folds alone")
        }
        XCTAssertEqual(InspectorSection.levels.title, "Levels")
        XCTAssertEqual(InspectorSection.curves.title, "Curves")
    }

    /// Every Enhance group has a fold, each its own, and each is titled with the group's
    /// on-screen name.
    func testEveryEnhanceGroupHasItsOwnFold() {
        let folds = EnhanceControl.Group.allCases.map(InspectorSection.group)
        XCTAssertEqual(Set(folds).count, EnhanceControl.Group.allCases.count)
        for group in EnhanceControl.Group.allCases {
            XCTAssertEqual(InspectorSection.group(group).title, group.rawValue)
        }
        XCTAssertEqual(InspectorSection.develop.title, "Develop")
        XCTAssertEqual(InspectorSection.looks.title, "Looks")
        XCTAssertEqual(InspectorSection.histogram.title, "Histogram")
        XCTAssertEqual(InspectorSection.metadata.title, "Metadata")
        XCTAssertEqual(InspectorSection.vignette.title, "Vignette")
        XCTAssertEqual(InspectorSection.group(.vignette), .vignette)
    }

    /// What the AX check presses, and what a pointer reads.
    func testTheTitleSaysWhatAPressDoes() {
        XCTAssertEqual(SectionFold.accessibilityLabel("Develop", open: true), "Develop, collapse")
        XCTAssertEqual(SectionFold.accessibilityLabel("Develop", open: false), "Develop, expand")
        XCTAssertEqual(SectionFold.help("Light", open: true), "Hide Light")
        XCTAssertEqual(SectionFold.help("Light", open: false), "Show Light")
        XCTAssertEqual(SectionFold.help("Histogram", open: false), "Show Histogram")
        XCTAssertEqual(SectionFold.help("Metadata", open: true), "Hide Metadata")
        XCTAssertEqual(SectionFold.chevron, "chevron.right")
    }

    // MARK: persistence

    /// The first read of the new key gives the default, whatever an older blob stored: the
    /// older fold key (`closedSections`, where an empty list meant all open) and the two
    /// header switches (`histogramShown`, `metadataShown`) are not migrated. Histogram and
    /// Metadata read open because the default opens them, which the blob with both switches
    /// OFF proves: were a switch read, that blob would close its section.
    func testAnOlderBlobStartsAtTheDefault() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as! [String: Any]
        json.removeValue(forKey: "inspectorFold")
        json["closedSections"] = ["develop", "light"]
        json["showHistogram"] = true
        for shown in [true, false] {
            json["histogramShown"] = shown
            json["metadataShown"] = shown
            let blob = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(blob.sectionFold, SectionFold(), "switches \(shown): the default")
            XCTAssertTrue(blob.sectionFold.isOpen(.histogram), "switches \(shown): the old histogram switch is not read")
            XCTAssertTrue(blob.sectionFold.isOpen(.metadata), "switches \(shown): nor the old metadata switch")
            XCTAssertTrue(blob.sectionFold.isOpen(.develop), "switches \(shown): nor the old fold")
            XCTAssertTrue(blob.sectionFold.isOpen(.light), "switches \(shown): nor the old fold's groups")
        }
        json["histogramShown"] = true
        json["metadataShown"] = true
        let old = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: json))

        // An empty old fold (where empty meant all open) reads as the default too.
        json["closedSections"] = [String]()
        let empty = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(empty.sectionFold, SectionFold())

        // And what this build writes carries neither old key.
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        XCTAssertNil(written["closedSections"])
        XCTAssertNil(written["histogramShown"])
        XCTAssertNil(written["metadataShown"])
        XCTAssertNotNil(written["showHistogram"], "the field stays, so an older build still decodes the blob")
    }

    /// A fold survives a relaunch through the real store.
    @MainActor
    func testTheFoldIsRememberedAppWide() throws {
        let (m, _) = try scratchRollModel(frames: 1, in: scratch)
        XCTAssertEqual(m.prefs.sectionFold, SectionFold(), "a fresh model starts at the default")
        XCTAssertTrue(m.prefs.sectionFold.isOpen(.metadata), "with Metadata open")
        XCTAssertTrue(m.prefs.sectionFold.isOpen(.histogram), "and Histogram open")
        XCTAssertFalse(m.prefs.sectionFold.isOpen(.enhance), "and Enhance closed")
        m.toggleSection(.develop)
        m.toggleSection(.metadata)
        XCTAssertFalse(m.prefs.sectionFold.isOpen(.develop))
        XCTAssertFalse(m.prefs.sectionFold.isOpen(.metadata))
        let reloaded = Preferences.load().sectionFold
        XCTAssertEqual(reloaded, SectionFold(closed: [.develop, .metadata, .enhance]), "saved app-wide")
        m.toggleSection(.develop)
        XCTAssertEqual(Preferences.load().sectionFold, SectionFold(closed: [.metadata, .enhance]),
                       "and so is opening it")
    }

    /// The View menu's Show Histogram flips the histogram fold, and only that.
    @MainActor
    func testTheViewMenuFlipsTheHistogramFold() throws {
        let (m, _) = try scratchRollModel(frames: 1, in: scratch)
        XCTAssertTrue(m.histogramOpen, "open by default")
        m.histogramOpen = false
        XCTAssertFalse(m.prefs.sectionFold.isOpen(.histogram))
        XCTAssertEqual(m.prefs.sectionFold, SectionFold().toggled(.histogram), "only the histogram moved")
        XCTAssertFalse(Preferences.load().sectionFold.isOpen(.histogram), "saved")
        m.histogramOpen = false
        XCTAssertFalse(m.histogramOpen, "setting it to what it is changes nothing")
        XCTAssertEqual(m.prefs.sectionFold, SectionFold().toggled(.histogram))
        m.toggleSection(.histogram)
        XCTAssertTrue(m.histogramOpen, "a press on the title is the same fold the menu reads")
        m.histogramOpen = true
        XCTAssertEqual(m.prefs.sectionFold, SectionFold())

        let app = try repoSource("Sources/FilmPositive/App/FilmPositiveApp.swift")
        XCTAssertTrue(app.contains("Toggle(\"Show Histogram\", isOn: Binding(get: { model.histogramOpen }, set: { model.histogramOpen = $0 }))"),
                      "the menu item is bound to the fold")
    }

    /// A fold is a preference: no sidecar changes and no undo step appears.
    @MainActor
    func testFoldingWritesNoSidecarAndNoUndo() throws {
        let (m, ids) = try scratchRollModel(frames: 1, in: scratch)
        m.selection = Set(ids)
        let sidecar = m.frame(ids[0])?.sidecar
        let undoable = m.undoManager.canUndo
        for section in InspectorSection.allCases { m.toggleSection(section) }
        XCTAssertEqual(m.frame(ids[0])?.sidecar, sidecar)
        XCTAssertEqual(m.undoManager.canUndo, undoable, "no undo step was registered")
    }

    // MARK: the view uses the rule

    /// Source scan, canaried: every section title goes through `FoldTitle`, and the chevron is
    /// drawn only when closed.
    func testEveryTitleFolds() throws {
        let s = try repoSource("Sources/FilmPositive/UI/Inspector/InspectorView.swift")
        XCTAssertTrue(s.contains("private func sectionHeader("), "read the right file")
        for call in ["sectionHeader(\"Develop\", resetTitle: \"Reset\",", "fold: .develop",
                     "fold: .frame", "fold: .enhance",
                     "FoldTitle(fold.title, open: isOpen(fold), action: { model.toggleSection(fold) })",
                     "FoldTitle(InspectorSection.looks.title, open: isOpen(.looks),",
                     "Self.foldHeader(.histogram, open: isOpen(.histogram)) { model.toggleSection(.histogram) }",
                     "FoldTitle(section.title, open: open, action: action) {"] {
            XCTAssertTrue(s.contains(call), "missing \(call)")
        }
        let metadata = try repoSource("Sources/FilmPositive/UI/Inspector/MetadataRows.swift")
        XCTAssertTrue(metadata.contains("InspectorView.foldHeader(.metadata, open: open) { model.toggleSection(.metadata) }"))
        let title = try repoSource("Sources/FilmPositive/UI/Inspector/FoldTitle.swift")
        XCTAssertTrue(title.contains("if !open {\n                    Image(systemName: SectionFold.chevron)"),
                      "the chevron is drawn for a closed part only")
        XCTAssertTrue(title.contains(".accessibilityLabel(SectionFold.accessibilityLabel(title, open: open))"))
    }

    /// Closed, the histogram is not built.
    func testAClosedHistogramComputesNothing() throws {
        let s = try repoSource("Sources/FilmPositive/UI/Inspector/InspectorView.swift")
        let absorb = try XCTUnwrap(s.range(of: "private func absorbFreshPixels()"))
        let body = String(s[absorb.upperBound...].prefix(900))
        let guardLine = try XCTUnwrap(body.range(of: "guard isOpen(.histogram) else { return }"))
        let build = try XCTUnwrap(body.range(of: "histogram = FrameHistogram(image: entry.image)"))
        XCTAssertLessThan(guardLine.lowerBound, build.lowerBound)
        XCTAssertTrue(s.contains(".onChange(of: isOpen(.histogram)) { _, _ in absorbFreshPixels() }"),
                      "opening it builds one from the pixels already there")
        XCTAssertFalse(s.contains("showsHistogram"), "the old switch is not read anywhere in the inspector")
    }
}
