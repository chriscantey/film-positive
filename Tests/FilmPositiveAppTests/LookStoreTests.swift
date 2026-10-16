import XCTest
import UniformTypeIdentifiers
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The Looks logic, tested without a window.
///
/// `LookStore` is a plain value type for exactly this reason. The row on top of it is
/// verified on screen in the running app, the only instrument that can prove a layout, and
/// this file is the only instrument that can prove the store.
final class LookStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("LookStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func opened() -> LookStore {
        var store = LookStore(directory: dir)
        XCTAssertEqual(store.load(), [], "a fresh or clean directory must load without problems")
        return store
    }

    // MARK: the set the row shows

    func testShippedSetIsTheRowsStartingPoint() {
        let store = opened()
        // Morning has a NEW id rather than plain's, deliberately, so a frame still tagged
        // plain keeps its own sliders instead of being relabeled as a look whose numbers it
        // does not have. `Looks.swift` carries the reasoning.
        XCTAssertEqual(store.looks.map(\.id),
                       ["pop", "sunroom", "matinee", "hard-candy", "clear", "morning", "overcast-color", "silver", "overcast", "bright-print"],
                       "the row starts as the shipped presets in ShippedLooks order")
        XCTAssertEqual(store.looks.map(\.id), ShippedLooks.all.map(\.id),
                       "and it is exactly what the engine ships, so adding a look is one edit there")
        XCTAssertEqual(Set(store.looks.map(\.id)).count, store.looks.count, "ids must be unique for ForEach")
        XCTAssertTrue(store.userLooks.isEmpty)
        XCTAssertTrue(store.hiddenIDs.isEmpty)
    }

    /// Applying a look: the row's one call sets the sliders and records the id, which is
    /// what the highlight reads.
    func testApplyLookSetsSlidersAndRecordsTheID() throws {
        let silver = try XCTUnwrap(ShippedLooks.look("silver"))
        let before = Sidecar(source: SidecarSource(name: "IMG.CR2", size: 1, mtime: Date(), fingerprint: "x"))
        let after = SidecarEdits.applyLook(before, silver)
        XCTAssertEqual(after.look, "silver")
        XCTAssertEqual(after.enhance, silver.settings)

        // A slider edit drops the id, which is what stops a stale highlight.
        var moved = silver.settings
        moved.contrast += 0.2
        XCTAssertNil(SidecarEdits.setEnhance(after, moved).look)
    }

    /// The black and white looks are ordinary entries in the same list, found by their
    /// settings rather than by an id list, so a new one appears with no edit to the row.
    func testBlackAndWhiteLooksAreOrdinaryRowEntries() throws {
        var store = opened()
        // In the row's order, which is the shipped order, and the same set the engine
        // declares. Both are asserted: the order is what the user sees, the set is what
        // every other black and white rule keys on.
        XCTAssertEqual(store.monochromeLooks.map(\.id), ["silver", "overcast", "bright-print"])
        XCTAssertEqual(Set(store.monochromeLooks.map(\.id)), ShippedLooks.blackAndWhiteLookIDs)

        var mono = EnhanceSettings()
        mono.saturation = -1.0
        mono.contrast = 0.3
        _ = try store.saveLook(named: "Arista", settings: mono)
        XCTAssertEqual(store.monochromeLooks.map(\.id), ["silver", "overcast", "bright-print", "arista"],
                       "a user's black and white look joins the row with no code change")
        XCTAssertTrue(store.looks.contains { $0.id == "arista" }, "and it is a plain button in the same row")
    }

    // MARK: Save Look survives relaunch

    func testSaveLookSurvivesRelaunch() throws {
        var store = opened()
        var settings = EnhanceSettings()
        settings.contrast = 0.42
        settings.vibrance = -0.1
        let saved = try store.saveLook(named: "My Roll", settings: settings)
        XCTAssertEqual(saved.id, "my-roll")
        XCTAssertFalse(saved.shipped)

        // The relaunch: a brand new store over the same directory, nothing carried in memory.
        var reopened = LookStore(directory: dir)
        XCTAssertEqual(reopened.load(), [])
        XCTAssertEqual(reopened.userLooks.map(\.id), ["my-roll"])
        XCTAssertEqual(reopened.userLooks.first?.settings, settings)
        XCTAssertEqual(reopened.looks.count, ShippedLooks.all.count + 1)
        XCTAssertEqual(reopened.looks.last?.id, "my-roll", "user presets come after the shipped ones")

        // And it really is one .fplooks document, not some private format.
        let data = try Data(contentsOf: store.userLooksURL)
        XCTAssertEqual(try LookFile.decode(data).map(\.id), ["my-roll"])
    }

    func testSavingTheSameNameReplacesInPlace() throws {
        var store = opened()
        var a = EnhanceSettings(); a.contrast = 0.2
        var b = EnhanceSettings(); b.contrast = 0.5
        _ = try store.saveLook(named: "My Roll", settings: a)
        _ = try store.saveLook(named: "My Roll", settings: b)
        XCTAssertEqual(store.userLooks.count, 1, "saving over a name must not pile up copies")
        XCTAssertEqual(store.userLooks.first?.settings, b)
    }

    func testASavedNameNeverShadowsAShippedID() throws {
        var store = opened()
        var s = EnhanceSettings(); s.warmth = 0.3
        let saved = try store.saveLook(named: "Pop", settings: s)
        XCTAssertEqual(saved.id, "pop-2", "a user preset cannot take a shipped id")
        XCTAssertEqual(store.looks.filter { $0.id == "pop" }.count, 1)
        XCTAssertEqual(Set(store.looks.map(\.id)).count, store.looks.count)
    }

    func testSavedSlidersAreRoundedLikeTheSidecar() throws {
        var store = opened()
        var s = EnhanceSettings()
        s.exposure = 0.123456789
        let saved = try store.saveLook(named: "Fine", settings: s)
        XCTAssertEqual(saved.settings.exposure, 0.1235, accuracy: 1e-12,
                       "a look and a sidecar have to agree after a round trip through disk")
    }

    func testAnEmptyNameIsRefused() {
        var store = opened()
        XCTAssertThrowsError(try store.saveLook(named: "   ", settings: EnhanceSettings())) { error in
            XCTAssertEqual(error as? LookStore.StoreError, .emptyName)
        }
    }

    // MARK: delete and restore

    func testDeletingAShippedPresetHidesItAndResetBringsItBack() throws {
        var store = opened()
        XCTAssertEqual(try store.delete("silver"), .hidden(try XCTUnwrap(ShippedLooks.look("silver"))))
        XCTAssertFalse(store.looks.contains { $0.id == "silver" })
        XCTAssertEqual(store.hiddenLooks.map(\.id), ["silver"])

        // Hidden across a relaunch, because a preset that comes back at launch was not deleted.
        var reopened = LookStore(directory: dir)
        XCTAssertEqual(reopened.load(), [])
        XCTAssertFalse(reopened.looks.contains { $0.id == "silver" })

        let restored = try reopened.restoreAll()
        XCTAssertEqual(restored.map(\.id), ["silver"])
        XCTAssertEqual(reopened.looks.map(\.id), ShippedLooks.all.map(\.id))

        var again = LookStore(directory: dir)
        XCTAssertEqual(again.load(), [])
        XCTAssertEqual(again.looks.map(\.id), ShippedLooks.all.map(\.id), "the restore is on disk, not just in memory")
        XCTAssertEqual(try again.restoreAll(), [], "Reset Presets is idempotent")
    }

    func testDeletingAUserPresetRemovesItAndResetDoesNotResurrectIt() throws {
        var store = opened()
        var s = EnhanceSettings(); s.contrast = 0.2
        _ = try store.saveLook(named: "Scratch", settings: s)
        XCTAssertEqual(try store.delete("scratch"), .removed(Look(id: "scratch", name: "Scratch",
                                                                 blurb: "Your own look.", settings: s, shipped: false)))
        XCTAssertTrue(store.userLooks.isEmpty)
        _ = try store.restoreAll()
        XCTAssertTrue(store.userLooks.isEmpty, "a reset of the shipped set must not undelete a user preset")

        var reopened = LookStore(directory: dir)
        XCTAssertEqual(reopened.load(), [])
        XCTAssertTrue(reopened.userLooks.isEmpty)
    }

    func testDeletingSomethingThatIsNotThereIsAnError() {
        var store = opened()
        XCTAssertThrowsError(try store.delete("nope")) { error in
            XCTAssertEqual(error as? LookStore.StoreError, .unknownLook("nope"))
        }
    }

    // MARK: export and import

    func testExportThenImportIsARoundTripAndReimportIsANoOp() throws {
        var store = opened()
        var s = EnhanceSettings(); s.saturation = 0.3
        _ = try store.saveLook(named: "Mine", settings: s)
        let data = try store.exportData()

        // It is a real .fplooks document and it carries the whole row.
        XCTAssertEqual(try LookFile.decode(data).map(\.id), store.looks.map(\.id))

        // A different machine: nothing saved, one file dropped in.
        let other = dir.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        var fresh = LookStore(directory: other)
        XCTAssertEqual(fresh.load(), [])
        let first = try fresh.importLooks(from: data)
        XCTAssertEqual(first.added.map(\.id), ["mine"], "the shipped ones are already there, only the user preset is new")
        XCTAssertEqual(first.unchanged.count, ShippedLooks.all.count)
        XCTAssertEqual(fresh.looks.map(\.id), store.looks.map(\.id), "the row now matches the exporting machine")

        let second = try fresh.importLooks(from: data)
        XCTAssertTrue(second.isEmptyChange, "importing the same file twice must not duplicate anything")
        XCTAssertEqual(fresh.looks.map(\.id), store.looks.map(\.id))

        var reopened = LookStore(directory: other)
        XCTAssertEqual(reopened.load(), [])
        XCTAssertEqual(reopened.userLooks.map(\.id), ["mine"], "an import is on disk")
    }

    func testImportingAnEditedShippedLookKeepsBothAndListsIt() throws {
        var store = opened()
        var edited = try XCTUnwrap(ShippedLooks.look("pop"))
        edited.settings.contrast = 0.9
        let data = try LookFile.encode([edited])

        let result = try store.importLooks(from: data)
        XCTAssertEqual(result.added.map(\.id), ["pop-2"], "an edited copy never shadows the shipped Pop")
        XCTAssertEqual(result.listed.map(\.name), ["Pop"], "and it is listed back under the name the file gave it")
        XCTAssertEqual(store.looks.filter { $0.name == "Pop" }.count, 2)
        XCTAssertEqual(try XCTUnwrap(store.look("pop")).settings, try XCTUnwrap(ShippedLooks.look("pop")).settings)
        XCTAssertEqual(try XCTUnwrap(store.look("pop-2")).settings.contrast, 0.9)
    }

    func testImportingOverAUserPresetReplacesIt() throws {
        var store = opened()
        var a = EnhanceSettings(); a.contrast = 0.2
        _ = try store.saveLook(named: "Mine", settings: a)

        var b = a; b.contrast = 0.7
        let incoming = Look(id: "mine", name: "Mine", blurb: "Your own look.", settings: b, shipped: false)
        let result = try store.importLooks(from: try LookFile.encode([incoming]))
        XCTAssertEqual(result.replaced.map(\.id), ["mine"])
        XCTAssertTrue(result.added.isEmpty)
        XCTAssertEqual(store.userLooks.count, 1)
        XCTAssertEqual(store.look("mine")?.settings.contrast, 0.7)
    }

    func testImportingAHiddenShippedLookBringsItBack() throws {
        var store = opened()
        _ = try store.delete("clear")
        XCTAssertFalse(store.looks.contains { $0.id == "clear" })

        let data = try LookFile.encode([try XCTUnwrap(ShippedLooks.look("clear"))])
        let result = try store.importLooks(from: data)
        XCTAssertEqual(result.restored.map(\.id), ["clear"], "a file that carries a hidden preset unhides it")
        XCTAssertTrue(store.looks.contains { $0.id == "clear" })

        var reopened = LookStore(directory: dir)
        XCTAssertEqual(reopened.load(), [])
        XCTAssertTrue(reopened.looks.contains { $0.id == "clear" })
    }

    func testImportingRubbishFailsLoudlyAndChangesNothing() throws {
        var store = opened()
        var s = EnhanceSettings(); s.contrast = 0.2
        _ = try store.saveLook(named: "Mine", settings: s)
        XCTAssertThrowsError(try store.importLooks(from: Data("not a look file".utf8)))
        XCTAssertEqual(store.userLooks.map(\.id), ["mine"])

        // A file from a newer schema is refused by the codec rather than half read.
        let future = Data(#"{"version": 99, "looks": []}"#.utf8)
        XCTAssertThrowsError(try store.importLooks(from: future))
    }

    // MARK: a store file that will not read

    /// The failure direction that matters: a corrupt file must never present as an empty
    /// preset list, because the next save would then write over it. The canary in the same
    /// test is the good file loading, so this cannot pass by loading nothing at all.
    func testACorruptStoreIsMovedAsideAndReported() throws {
        var store = opened()
        var s = EnhanceSettings(); s.contrast = 0.2
        _ = try store.saveLook(named: "Mine", settings: s)

        var canary = LookStore(directory: dir)
        XCTAssertEqual(canary.load(), [])
        XCTAssertEqual(canary.userLooks.map(\.id), ["mine"], "canary: the reader works on a good file")

        try Data("{ broken".utf8).write(to: store.userLooksURL)
        var broken = LookStore(directory: dir)
        let problems = broken.load()
        XCTAssertEqual(problems.count, 1)
        let problem = try XCTUnwrap(problems.first)
        XCTAssertEqual(problem.file, store.userLooksURL)
        let movedTo = try XCTUnwrap(problem.movedTo, "the bad file is kept, never deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedTo.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.userLooksURL.path))
        XCTAssertTrue(broken.userLooks.isEmpty)
    }

    /// The exporter and importer both name `UTType.filmPositiveLooks`, which is derived from
    /// the extension rather than declared in an Info.plist the SwiftPM executable does not
    /// have. If that derivation ever returns nil the fallback is `.json` and the save panel
    /// quietly writes the wrong extension, which nothing else in the app would notice.
    func testTheLookFileTypeResolvesToTheRealExtension() {
        XCTAssertEqual(UTType.filmPositiveLooks.preferredFilenameExtension, LookFile.fileExtension)
        XCTAssertNotEqual(UTType.filmPositiveLooks, .json, "the fallback means the derivation failed")
    }

    func testSlugging() {
        XCTAssertEqual(LookStore.slug("Hard Candy 2"), "hard-candy-2")
        XCTAssertEqual(LookStore.slug("  Sun   room  "), "sun-room")
        XCTAssertEqual(LookStore.slug("!!!"), "look")
    }
}
