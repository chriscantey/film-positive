import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The inspector's Metadata section: Camera and Film, the names Tether recorded,
/// read over the selection and written to every selected frame through `applyToSelection`.
final class MetadataRowsTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    @MainActor
    private func model(frames count: Int) throws -> (AppModel, [Frame.ID]) {
        let roll = scratch.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        for i in 1...count {
            try Data(repeating: 0x42, count: 64)
                .write(to: roll.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        let profiles = try ProfileLibrary.bundled()
        let model = AppModel(service: CPURenderService(profiles: profiles))
        model.undoManager.groupsByEvent = false
        XCTAssertNotNil(model.addFolder(roll))
        let ids = (model.selectedFolder?.frames ?? []).map(\.id)
        XCTAssertEqual(ids.count, count)
        return (model, ids)
    }

    /// `groupsByEvent` is off in a test, so a single-frame `apply` needs its own group.
    @MainActor
    private func edit(_ model: AppModel, _ id: Frame.ID, _ change: @escaping (Sidecar) -> Sidecar) {
        model.undoManager.beginUndoGrouping()
        model.apply(change, to: id, actionName: "t")
        model.undoManager.endUndoGrouping()
    }

    @MainActor
    func testAMixedSelectionReadsMultiple() throws {
        let (model, ids) = try model(frames: 2)
        edit(model, ids[0]) { SidecarEdits.setCamera($0, "Leica M6") }
        edit(model, ids[1]) { SidecarEdits.setCamera($0, "Nikon F3") }
        edit(model, ids[0]) { SidecarEdits.setFilm($0, "Kodak Gold 200") }
        edit(model, ids[1]) { SidecarEdits.setFilm($0, "Kodak Gold 200") }
        model.selection = Set(ids)

        let summary = model.selectionSummary
        XCTAssertTrue(summary.camera.isMultiple, "two cameras read Multiple")
        XCTAssertEqual(summary.film.value, .some("Kodak Gold 200"), "one shared film reads as that film")
    }

    @MainActor
    func testACameraCommitOverThreeFramesWritesThreeSidecars() throws {
        let (model, ids) = try model(frames: 3)
        model.selection = Set(ids)
        model.applyToSelection({ SidecarEdits.setCamera($0, "Canon AE-1") }, actionName: "Camera")
        for id in ids { model.flushPendingSave(id) }

        for id in ids {
            let frame = try XCTUnwrap(model.frame(id))
            let onDisk = try XCTUnwrap(SidecarStore().load(for: frame.url), "\(frame.name) has a sidecar on disk")
            XCTAssertEqual(onDisk.sidecar.capture?.camera, "Canon AE-1")
            XCTAssertEqual(onDisk.sidecar.capture?.cameraMake, "Canon")
            XCTAssertNil(onDisk.sidecar.develop, "a metadata edit does not make a positive")
        }
        // One Command Z takes all three back.
        model.undoManager.undo()
        for id in ids { XCTAssertNil(try XCTUnwrap(model.frame(id)).sidecar.capture) }
    }

    @MainActor
    func testFilmMakerIsDerivedTheWayTetherDerivesIt() throws {
        let (model, ids) = try model(frames: 2)
        edit(model, ids[0]) { SidecarEdits.setFilm($0, "Kodak Gold 200") }
        edit(model, ids[1]) { SidecarEdits.setFilm($0, "Reflx Lab 320D") }
        XCTAssertEqual(model.frame(ids[0])?.sidecar.capture?.filmMaker, "Kodak")
        let second = try XCTUnwrap(model.frame(ids[1])?.sidecar.capture)
        XCTAssertEqual(second.film, "Reflx Lab 320D")
        XCTAssertNil(second.filmMaker, "a maker not on the list is left out, never guessed")
    }

    /// The rule the section exists under: Film is metadata, the Stock picker owns the stock.
    @MainActor
    func testEditingFilmOnAPositiveLeavesTheStockAlone() throws {
        let (model, ids) = try model(frames: 1)
        let id = ids[0]
        model.selection = [id]
        model.developSelection()
        let before = try XCTUnwrap(model.frame(id)?.sidecar.develop, "the frame is a positive")

        model.applyToSelection({ SidecarEdits.setFilm($0, "Kodak Portra 400") }, actionName: "Film")
        let after = try XCTUnwrap(model.frame(id))
        XCTAssertEqual(after.sidecar.capture?.film, "Kodak Portra 400")
        XCTAssertEqual(after.sidecar.develop, before, "the develop layer, stock included, did not move")
    }

    /// The export reads the frame's capture block as it is in memory, so an edit made here
    /// is what the exported file carries.
    @MainActor
    func testTheExportCarriesTheEditedNames() throws {
        let (model, ids) = try model(frames: 1)
        model.selection = Set(ids)
        model.developSelection()
        model.applyToSelection({ SidecarEdits.setCamera($0, "Leica M6") }, actionName: "Camera")
        model.applyToSelection({ SidecarEdits.setFilm($0, "Kodak Gold 200") }, actionName: "Film")

        let target = try XCTUnwrap(model.exportTargets.first)
        let meta = ExportMetadata.from(raw: nil, capture: target.capture, develop: target.develop,
                                       mode: .neutral, lookName: nil, appVersion: "test")
        XCTAssertEqual(meta.make, "Leica")
        XCTAssertEqual(meta.model, "Leica M6")
        XCTAssertEqual(meta.film, "Kodak Gold 200")
        XCTAssertEqual(meta.filmMaker, "Kodak")
    }

    /// A name written over a selection where some frames already carry that name is a no-op
    /// on those frames, and a no-op on a negative is what the Positive button looks like to
    /// the defaults funnel. None of those frames may turn positive.
    @MainActor
    func testANameAlreadyOnSomeFramesMakesNoneOfThemPositive() throws {
        let (model, ids) = try model(frames: 4)
        edit(model, ids[0]) { SidecarEdits.setFilm($0, "Kodak Gold 200") }
        edit(model, ids[1]) { SidecarEdits.setFilm($0, "Kodak Gold 200") }
        edit(model, ids[0]) { SidecarEdits.setCamera($0, "Canon AE-1") }
        model.selection = Set(ids)

        model.setFilmOnSelection("Kodak Gold 200")
        model.setCameraOnSelection("Canon AE-1")
        for id in ids {
            let frame = try XCTUnwrap(model.frame(id))
            XCTAssertNil(frame.sidecar.develop, "\(frame.name) stays a negative")
            XCTAssertEqual(frame.sidecar.capture?.film, "Kodak Gold 200")
            XCTAssertEqual(frame.sidecar.capture?.camera, "Canon AE-1")
        }
    }

    func testReturnWritesOnlyWhatWasTyped() {
        typealias F = MetadataField
        XCTAssertNil(F.committedName("Leica M6", dirty: false, isMultiple: false, shown: "Nikon F3"),
                     "Return on an untouched field writes nothing")
        XCTAssertEqual(F.committedName("Leica M6", dirty: true, isMultiple: false, shown: "Nikon F3"), "Leica M6")
        XCTAssertNil(F.committedName("Nikon F3", dirty: true, isMultiple: false, shown: "Nikon F3"),
                     "typing the same name back is not an edit")
        XCTAssertEqual(F.committedName("", dirty: true, isMultiple: false, shown: "Nikon F3"), "",
                       "clearing one shared name is honoured")
        XCTAssertNil(F.committedName("", dirty: true, isMultiple: true, shown: ""),
                     "an empty Multiple row never clears every frame")
        XCTAssertEqual(F.committedName("Leica M6", dirty: true, isMultiple: true, shown: ""), "Leica M6")
    }
}
