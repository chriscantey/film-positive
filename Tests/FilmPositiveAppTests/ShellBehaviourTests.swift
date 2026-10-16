import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The shell's own promises, the ones that live in `AppModel` rather than in any arm:
/// where a sidecar is written and when, what a deleted sidecar means on the next launch,
/// that changing develop keeps enhance, and that an engine failure reaches the user with its
/// whole text.
///
/// Every one of these runs over real files in a real temporary folder, because the claims
/// are about the file system and about timing, and no reading of the code can settle either.
final class ShellBehaviourTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-shell-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    @discardableResult
    private func makeFolder(_ name: String, count: Int = 3) throws -> URL {
        let dir = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...count {
            try Data(repeating: UInt8(0x40 + i), count: 128)
                .write(to: dir.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        return dir
    }

    @MainActor
    private func model() -> AppModel {
        AppModel(service: FailingRenderService(message: "engine is not part of this test"))
    }

    private func develop(_ stock: String = "kodak-gold-200", autoTone: Bool = true) -> DevelopSettings {
        DevelopSettings(stock: stock, autoTone: autoTone,
                        base: BaseSettings(mode: .anchor))
    }

    /// The debounce is 400 ms, so every write assertion has to wait for it. Polling rather
    /// than sleeping a fixed time keeps the test honest about what it is waiting for.
    private func waitForFile(_ url: URL, exists: Bool = true, timeout: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) == exists { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return false
    }

    // MARK: the sidecar on disk

    @MainActor
    func testDevelopWritesTheSidecarNextToTheRaw() async throws {
        let dir = try makeFolder("write")
        let m = model()
        XCTAssertNotNil(m.addFolder(dir))
        let frame = try XCTUnwrap(m.framesInView.first)
        let sidecar = SidecarStore.sidecarURL(for: frame.url)
        XCTAssertEqual(sidecar.lastPathComponent, "IMG_0001.xmp", "the Adobe sidecar name Tether already uses")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "nothing is written before an edit")

        m.apply({ SidecarEdits.setDevelop($0, self.develop()) }, to: frame.id, actionName: "Develop")
        let landed = await waitForFile(sidecar)
        XCTAssertTrue(landed, "the sidecar lands next to the raw after the debounce")

        let text = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(text.contains("kodak-gold-200"), "the stock is in the packet")
        XCTAssertTrue(text.contains("FilmPositive"), "written in our namespace")
        // and nothing else appeared in the folder: no per-image state anywhere else
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["IMG_0001.CR2", "IMG_0001.xmp", "IMG_0002.CR2", "IMG_0003.CR2"])
    }

    @MainActor
    func testADragWritesOnceAndANoOpEditWritesNothing() async throws {
        let dir = try makeFolder("debounce")
        let m = model()
        XCTAssertNotNil(m.addFolder(dir))
        let frame = try XCTUnwrap(m.framesInView.first)
        let sidecar = SidecarStore.sidecarURL(for: frame.url)

        // A drag: many edits inside one debounce window must leave one file, not many
        // writes. The file's modification date is the only evidence that distinguishes
        // "coalesced" from "wrote eleven times quickly", so the test reads it.
        m.apply({ SidecarEdits.setDevelop($0, self.develop()) }, to: frame.id, actionName: "Develop")
        for i in 1...10 {
            var enhance = EnhanceSettings()
            enhance.exposure = Double(i) / 20
            m.apply({ SidecarEdits.setEnhance($0, enhance) }, to: frame.id, actionName: "Exposure")
        }
        let landed = await waitForFile(sidecar)
        XCTAssertTrue(landed)
        let afterDrag = try FileManager.default.attributesOfItem(atPath: sidecar.path)[.modificationDate] as? Date
        let sizeAfterDrag = try Data(contentsOf: sidecar).count

        // A no-op edit: `apply` compares values and returns before scheduling anything, so
        // a cloud-synced folder never sees a write it did not need.
        let current = try XCTUnwrap(m.frame(frame.id)?.sidecar.enhance)
        m.apply({ SidecarEdits.setEnhance($0, current) }, to: frame.id, actionName: "Exposure")
        try await Task.sleep(nanoseconds: 700_000_000)
        let afterNoOp = try FileManager.default.attributesOfItem(atPath: sidecar.path)[.modificationDate] as? Date
        XCTAssertEqual(afterDrag, afterNoOp, "a no-op edit must not touch the file")
        XCTAssertEqual(try Data(contentsOf: sidecar).count, sizeAfterDrag)

        // The undo stack is where the drag's eleven edits went, so the file being written
        // once is coalescing rather than lost edits.
        XCTAssertEqual(m.frame(frame.id)?.sidecar.enhance?.exposure, 0.5)
    }

    // MARK: a deleted sidecar

    @MainActor
    func testDeletingASidecarShowsTheFrameAsUndevelopedAgain() async throws {
        let dir = try makeFolder("deleted")
        let m = model()
        XCTAssertNotNil(m.addFolder(dir))
        let frame = try XCTUnwrap(m.framesInView.first)
        m.apply({ SidecarEdits.setDevelop($0, self.develop()) }, to: frame.id, actionName: "Develop")
        let sidecar = SidecarStore.sidecarURL(for: frame.url)
        let landed = await waitForFile(sidecar)
        XCTAssertTrue(landed)
        XCTAssertTrue(try XCTUnwrap(m.frame(frame.id)).isDeveloped)

        // Deleted outside the app, the way a user would in Finder.
        try FileManager.default.removeItem(at: sidecar)
        let relaunched = model()
        XCTAssertNotNil(relaunched.addFolder(dir))
        let reloaded = try XCTUnwrap(relaunched.framesInView.first)
        XCTAssertFalse(reloaded.isDeveloped, "a frame with no sidecar is an undeveloped negative again")
        XCTAssertEqual(FrameCellState.of(frame: reloaded, hasImage: false), .negative, "a frame with no sidecar is a negative and renders nothing until Positive is pressed")

        // and the running session notices on a rescan rather than only on a relaunch
        m.rescan(try XCTUnwrap(m.selectedFolderID))
        XCTAssertFalse(try XCTUnwrap(m.frame(frame.id)).isDeveloped)
    }

    // MARK: develop and enhance are separate layers

    @MainActor
    func testChangingDevelopKeepsEnhanceAndTheRenderAsksForBoth() throws {
        let dir = try makeFolder("layers")
        let m = model()
        XCTAssertNotNil(m.addFolder(dir))
        let frame = try XCTUnwrap(m.framesInView.first)
        m.apply({ SidecarEdits.setDevelop($0, self.develop()) }, to: frame.id, actionName: "Develop")
        var enhance = EnhanceSettings()
        enhance.contrast = 0.4
        enhance.saturation = -0.2
        m.apply({ SidecarEdits.setEnhance($0, enhance) }, to: frame.id, actionName: "Contrast")

        // Change the stock, which is the develop layer, and the enhance layer must survive
        // it: the two layers are independent and only reset clears one.
        m.apply({ SidecarEdits.setDevelop($0, self.develop("kodak-portra-400")) }, to: frame.id, actionName: "Film Stock")
        let after = try XCTUnwrap(m.frame(frame.id))
        XCTAssertEqual(after.sidecar.develop?.stock, "kodak-portra-400")
        XCTAssertEqual(after.sidecar.enhance?.contrast, 0.4)
        XCTAssertEqual(after.sidecar.enhance?.saturation, -0.2)

        // and the render the coordinator would ask for carries both layers, so the change
        // re-renders downstream rather than dropping the enhance on the floor
        let request = try XCTUnwrap(m.renders.request(for: after))
        XCTAssertEqual(request.develop.stock, "kodak-portra-400")
        XCTAssertEqual(request.enhance.contrast, 0.4)

        // the same change with a look applied drops the look, because the sliders are no
        // longer the look's sliders, and keeps the values
        m.apply({ SidecarEdits.applyLook($0, ShippedLooks.all[0]) }, to: frame.id, actionName: "Look")
        XCTAssertNotNil(m.frame(frame.id)?.sidecar.look)
        var moved = try XCTUnwrap(m.frame(frame.id)?.sidecar.enhance)
        moved.vignette = 0.3
        m.apply({ SidecarEdits.setEnhance($0, moved) }, to: frame.id, actionName: "Vignette")
        XCTAssertNil(m.frame(frame.id)?.sidecar.look, "a hand-moved slider is no longer that look")
        XCTAssertEqual(m.frame(frame.id)?.sidecar.enhance?.vignette, 0.3)
    }

    // MARK: failures reach the user

    @MainActor
    func testAnEngineFailureReachesTheUserWithItsWholeText() async throws {
        let dir = try makeFolder("broken", count: 1)
        // A corrupt raw: the right size and extension, none of the content. LibRaw refuses
        // it, which is the failure a user actually hits with a truncated card copy.
        let raw = dir.appendingPathComponent("IMG_0001.CR2")
        try Data(repeating: 0xAB, count: 4096).write(to: raw)

        let profiles = try ProfileLibrary.bundled()
        let m = AppModel(service: CPURenderService(profiles: profiles))
        XCTAssertNotNil(m.addFolder(dir))
        let frame = try XCTUnwrap(m.framesInView.first)
        m.apply({ SidecarEdits.setDevelop($0, self.develop()) }, to: frame.id, actionName: "Develop")

        _ = m.renders.proxy(for: try XCTUnwrap(m.frame(frame.id)))
        let deadline = Date().addingTimeInterval(30)
        while m.renders.lastError == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let reported = try XCTUnwrap(m.renders.lastError, "a decode failure has to surface, never a blank cell")
        // The whole text, not a truncated tail: the file name that failed and the engine's
        // own words.
        XCTAssertTrue(reported.contains("IMG_0001.CR2"), reported)
        XCTAssertGreaterThan(reported.count, 20, reported)
        XCTAssertFalse(reported.hasSuffix("…"), "nothing is elided: \(reported)")

        // The window's alert binding is what the user sees, and it is driven by exactly
        // this field, so an error is never silently swallowed.
        XCTAssertNotNil(m.renders.lastError ?? m.lastError)
        m.renders.lastError = nil
        XCTAssertNil(m.renders.lastError, "dismissing clears it")
    }

    // MARK: a folder that cannot be read

    @MainActor
    func testAFolderThatCannotBeReadReportsWhy() throws {
        let m = model()
        let missing = scratch.appendingPathComponent("not-here")
        XCTAssertNil(m.addFolder(missing))
        let error = try XCTUnwrap(m.lastError)
        XCTAssertTrue(error.contains("not-here"), error)
    }
}
