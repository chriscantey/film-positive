import XCTest
import SwiftUI
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Holding M shows the original without a beep, because every key repeat the held key sends
/// is handled rather than passed up the responder chain.
final class HoldMKeyTests: XCTestCase {
    func testARepeatIsSwallowedAndChangesNothing() {
        XCTAssertEqual(ViewerView.originalHold(.down), .show)
        XCTAssertEqual(ViewerView.originalHold(.repeat), .swallow, "a held M is handled, so it never beeps")
        XCTAssertEqual(ViewerView.originalHold(.up), .hide)
    }

    /// The listener is a local monitor, which reads repeats as their own phase.
    func testTheHandlerListensForRepeats() throws {
        let s = try repoSource("Sources/FilmPositive/UI/Viewer/ViewerView.swift")
        XCTAssertTrue(s.contains("holdKey.install"))
        XCTAssertEqual(OriginalHoldKey.phase(type: .keyDown, isRepeat: true, characters: "m", modifiers: [],
                                             textFieldHasFocus: false), .repeat)
    }
}

/// A name saves when the field loses focus, to the frames that were selected when the typing
/// began, never to whatever is selected by the time the save lands.
final class MetadataSaveTargetTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    @MainActor
    func testASaveGoesToTheFramesCapturedAtFocus() throws {
        let (model, ids) = try scratchRollModel(frames: 4, in: scratch)
        let typedAbout = [ids[0], ids[1]]
        // The click that ended the typing has already moved the selection.
        model.selection = [ids[3]]
        model.setFilm("Kodak Portra 400", on: typedAbout)

        XCTAssertEqual(model.frame(ids[0])?.sidecar.capture?.film, "Kodak Portra 400")
        XCTAssertEqual(model.frame(ids[1])?.sidecar.capture?.film, "Kodak Portra 400")
        XCTAssertNil(model.frame(ids[2])?.sidecar.capture)
        XCTAssertNil(model.frame(ids[3])?.sidecar.capture, "the newly selected frame is not written")
        for id in ids { XCTAssertNil(model.frame(id)?.sidecar.develop) }
        model.undoManager.undo()
        XCTAssertNil(model.frame(ids[0])?.sidecar.capture, "one undo step")
    }

    func testTheFieldSavesOnFocusLossAndEscapeStillAbandons() throws {
        let s = try repoSource("Sources/FilmPositive/UI/Inspector/MetadataRows.swift")
        XCTAssertTrue(s.contains("session = Session(targets: selection()"), "targets are captured at focus")
        XCTAssertTrue(s.contains(".onExitCommand { dirty = false; release() }"), "Escape clears the typing before letting go")
        XCTAssertTrue(s.contains("onCommit(name.isEmpty ? nil : name, session.targets)"), "a save aims at the captured frames")
    }
}

/// The Histogram and Metadata cards: both open on a fresh install, and both fold from their
/// titles rather than from header switches (`SectionFoldTests`).
final class InspectorCardsTests: XCTestCase {
    func testBothCardsStartOpen() {
        let p = Preferences()
        XCTAssertTrue(p.sectionFold.isOpen(.histogram))
        XCTAssertTrue(p.sectionFold.isOpen(.metadata))
    }

    /// `showHistogram` is in every older blob and is not read as a choice: a blob with no
    /// stored fold opens both cards whichever way that field reads.
    func testAnOlderBlobStartsWithBothOpen() throws {
        for shown in [true, false] {
            var old = Preferences()
            old.showHistogram = shown
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
            json.removeValue(forKey: "inspectorFold")
            let p = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertTrue(p.sectionFold.isOpen(.histogram), "showHistogram \(shown)")
            XCTAssertTrue(p.sectionFold.isOpen(.metadata), "showHistogram \(shown)")
        }
    }

    func testAChoiceSurvivesARelaunch() throws {
        var p = Preferences()
        p.sectionFold.toggle(.histogram)
        p.sectionFold.toggle(.metadata)
        let back = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
        XCTAssertFalse(back.sectionFold.isOpen(.histogram))
        XCTAssertFalse(back.sectionFold.isOpen(.metadata))
    }

    /// No switch in either header, and no info icon beside Metadata.
    func testNeitherHeaderHasASwitch() throws {
        let s = try repoSource("Sources/FilmPositive/UI/Inspector/InspectorView.swift")
        let m = try repoSource("Sources/FilmPositive/UI/Inspector/MetadataRows.swift")
        XCTAssertTrue(m.contains("struct MetadataSection: View"), "canary: read the Metadata file")
        for (name, text) in [("InspectorView", s), ("MetadataRows", m)] {
            XCTAssertFalse(text.contains(".toggleStyle(.switch)"), "\(name) still draws a header switch")
            XCTAssertFalse(text.contains("showsHistogram") || text.contains("showsMetadata"), "\(name) reads an old switch")
        }
        XCTAssertFalse(m.contains("MetadataInfoButton"), "the Metadata info icon is gone")
        XCTAssertFalse(m.contains("\"metadata.info\""))
        XCTAssertTrue(m.contains("identifier: \"metadata.taken.info\""), "the Taken row keeps its icon")
        XCTAssertTrue(m.contains("identifier: \"metadata.scanned.info\""), "the Scanned row keeps its icon")
    }

    func testMetadataSitsAboveHistogramAndBothAboveEnhance() throws {
        let s = try repoSource("Sources/FilmPositive/UI/Inspector/InspectorView.swift")
        let frame = try XCTUnwrap(s.range(of: "frameSection()\n"))
        let histogram = try XCTUnwrap(s.range(of: "if let leadFrame { histogramSection(leadFrame) }"))
        let metadata = try XCTUnwrap(s.range(of: "MetadataSection(summary: summary)"))
        let enhance = try XCTUnwrap(s.range(of: "enhanceTitleSection()\n"))
        XCTAssertLessThan(frame.lowerBound, metadata.lowerBound)
        XCTAssertLessThan(metadata.lowerBound, histogram.lowerBound)
        XCTAssertLessThan(histogram.lowerBound, enhance.lowerBound)
        XCTAssertEqual(s.components(separatedBy: "MetadataSection(summary: summary)").count - 1, 1)
        XCTAssertEqual(s.components(separatedBy: "histogramSection(leadFrame)").count - 1, 1)
    }
}

/// Move to Folder has a button at the foot of the folder list.
final class SidebarMoveButtonTests: XCTestCase {
    func testTheBarCarriesMoveToFolder() throws {
        let s = try repoSource("Sources/FilmPositive/UI/Sidebar/SidebarView.swift")
        let bar = try XCTUnwrap(s.range(of: "private var bottomBar: some View"))
        let tail = String(s[bar.lowerBound...])
        XCTAssertTrue(tail.contains("Button { model.presentMoveSelection() }"))
        XCTAssertTrue(tail.contains(".disabled(model.selectedFrames.isEmpty)"))
        XCTAssertTrue(tail.contains(#".accessibilityLabel("Move to Folder")"#))
    }
}

/// The gallery says where the roll stands, top left, in the sidebar's words.
final class GalleryCountTests: XCTestCase {
    @MainActor
    func testTheCountReadsTheRoll() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-test-count-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (model, ids) = try scratchRollModel(frames: 3, in: scratch)
        let folder = { try XCTUnwrap(model.selectedFolder) }
        XCTAssertEqual(GridView.positiveCount(try folder()), "0 of 3 developed")
        model.selection = [ids[0]]
        model.developSelection()
        XCTAssertEqual(GridView.positiveCount(try folder()), "1 of 3 developed")
        model.selection = Set(ids)
        model.developSelection()
        XCTAssertEqual(GridView.positiveCount(try folder()), "All developed")
    }

    func testTheSizerAndTheCountShareOnePill() throws {
        let s = try repoSource("Sources/FilmPositive/UI/Grid/GridView.swift")
        XCTAssertEqual(s.components(separatedBy: ".modifier(GalleryPill())").count - 1, 2)
    }
}

/// The Metadata fields keep Film Tether's history, most recent first, removable.
final class MetadataHistoryTests: XCTestCase {
    func testTheFoldIsTethersRule() {
        var list: [String] = []
        list = NameHistory.fold("Kodak Gold 200", into: list)
        list = NameHistory.fold("Kodak Portra 400", into: list)
        list = NameHistory.fold("  kodak gold 200 ", into: list)
        XCTAssertEqual(list, ["kodak gold 200", "Kodak Portra 400"], "case-insensitive dedup, moved to front, trimmed")
        XCTAssertEqual(NameHistory.fold("", into: list), list, "an empty name is not a name")
        XCTAssertEqual(NameHistory.remove("KODAK PORTRA 400", from: list), ["kodak gold 200"])
        let many = (0..<80).reduce([String]()) { NameHistory.fold("n\($1)", into: $0) }
        XCTAssertEqual(many.count, NameHistory.cap)
        XCTAssertEqual(many.first, "n79")
    }

    @MainActor
    func testASaveRemembersTheNameAndRemovingItTouchesNoFrame() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-test-hist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (model, ids) = try scratchRollModel(frames: 2, in: scratch)
        let saved = model.prefs
        defer { model.prefs = saved; model.prefs.save() }
        model.prefs.cameraHistory = nil
        model.prefs.filmHistory = nil

        model.setCamera("Canon AE-1", on: ids)
        model.setFilm("Kodak Gold 200", on: ids)
        model.setCamera(nil, on: [ids[1]])
        XCTAssertEqual(model.prefs.cameraHistory, ["Canon AE-1"], "clearing a name leaves the history alone")
        XCTAssertEqual(model.prefs.filmHistory, ["Kodak Gold 200"])

        model.forgetName("Kodak Gold 200", in: .film)
        XCTAssertEqual(model.prefs.filmHistory, [])
        XCTAssertEqual(model.frame(ids[0])?.sidecar.capture?.film, "Kodak Gold 200", "the x touches no frame")
    }
}

/// Drag to reorder the folder list, remembered, one undo step.
final class FolderOrderTests: XCTestCase {
    @MainActor
    func testAMoveReordersPersistsAndUndoes() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-test-order-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (model, _) = try scratchRollModel(frames: 1, in: scratch, name: "a")
        let saved = model.prefs
        defer { model.prefs = saved; model.prefs.save() }
        for name in ["b", "c"] {
            let roll = scratch.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: 64).write(to: roll.appendingPathComponent("IMG_0001.CR2"))
            XCTAssertNotNil(model.addFolder(roll))
        }
        let names = { model.folders.map(\.name).suffix(3) }
        XCTAssertEqual(Array(names()), ["a", "b", "c"])
        let n = model.folders.count
        model.moveFolders(from: IndexSet(integer: n - 1), to: n - 3)
        XCTAssertEqual(Array(names()), ["c", "a", "b"])
        XCTAssertEqual(Array(Preferences.load().folderBookmarks.prefix(n)), model.folders.map(\.bookmark),
                       "the saved list is in the new order")
        model.undoManager.undo()
        XCTAssertEqual(Array(names()), ["a", "b", "c"])
        model.undoManager.redo()
        XCTAssertEqual(Array(names()), ["c", "a", "b"])
    }
}

/// Taken, Film size and Scanned in the Metadata section, and the day shot becoming the
/// exported photo's date.
final class MetadataDayTests: XCTestCase {
    @MainActor
    func testTakenSavesADayRefusesANonDayAndMakesNothingPositive() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-test-taken-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (model, ids) = try scratchRollModel(frames: 2, in: scratch)
        let saved = model.prefs
        defer { model.prefs = saved; model.prefs.save() }
        model.prefs.takenHistory = nil

        model.setTakenOn("2026-06-14", on: ids)
        for id in ids {
            XCTAssertEqual(model.frame(id)?.sidecar.capture?.takenOn, "2026-06-14")
            XCTAssertNil(model.frame(id)?.sidecar.develop, "a day is metadata, never a positive")
        }
        XCTAssertEqual(model.prefs.takenHistory, ["2026-06-14"])

        model.setTakenOn("2026-02-30", on: ids)
        XCTAssertEqual(model.frame(ids[0])?.sidecar.capture?.takenOn, "2026-06-14", "a non-day writes nothing")
        XCTAssertNotNil(model.lastError)

        model.setTakenOn(nil, on: [ids[1]])
        XCTAssertNil(model.frame(ids[1])?.sidecar.capture?.takenOn, "nil clears it")
    }

    func testTheExportedDateIsTheDayShotAtTheScanTimeOfDay() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let scanned = cal.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 15, minute: 15, second: 39))!
        let withScan = try XCTUnwrap(ExportMetadata.takenDate(CaptureInfo(capturedAt: scanned, takenOn: "2026-06-14"), calendar: cal))
        XCTAssertEqual(cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: withScan),
                       DateComponents(year: 2026, month: 6, day: 14, hour: 15, minute: 15, second: 39))
        let noScan = try XCTUnwrap(ExportMetadata.takenDate(CaptureInfo(takenOn: "2026-06-14"), calendar: cal))
        XCTAssertEqual(cal.component(.hour, from: noScan), 12, "noon without a scan time")
        XCTAssertNil(ExportMetadata.takenDate(CaptureInfo(capturedAt: scanned), calendar: cal), "no day, the raw's date stands")

        let meta = ExportMetadata.from(raw: nil, capture: CaptureInfo(capturedAt: scanned, takenOn: "2026-06-14"),
                                       develop: DevelopSettings(stock: "kodak-gold-200", base: BaseSettings(mode: .anchor)), mode: .neutral, lookName: nil, appVersion: "t")
        XCTAssertNotNil(meta.dateTimeOriginal)
        XCTAssertEqual(Calendar.current.component(.month, from: meta.dateTimeOriginal!), 6)
    }

    func testTheReadOnlyRowsReadWell() {
        typealias S = MetadataSection
        func text(_ frames: [(String?, String?)]) -> String {
            S.filmSizeText(SharedValue(frames.map { S.filmSizeLabel(id: $0.0, name: $0.1) }))
        }
        XCTAssertEqual(text([("4", nil)]), "35mm")
        XCTAssertEqual(text([(nil, nil)]), "Not recorded")
        XCTAssertEqual(text([("4", nil), ("2", nil)]), "Multiple")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let a = cal.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 15))!
        let b = cal.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 16))!
        let c = cal.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 9))!
        XCTAssertEqual(S.scannedText([], count: 2), "Not recorded")
        XCTAssertEqual(S.scannedText([a, b], count: 2), a.formatted(date: .abbreviated, time: .omitted), "one day reads as the day")
        XCTAssertTrue(S.scannedText([a, c], count: 2).contains(" to "), "across days reads as a span")
        XCTAssertEqual(S.scannedText([a], count: 1), a.formatted(date: .abbreviated, time: .shortened))
        XCTAssertEqual(MetadataField.day(from: a, calendar: cal), "2026-09-11")
    }
}
