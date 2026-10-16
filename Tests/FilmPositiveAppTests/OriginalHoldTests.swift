import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Hold to see the original, and the one shared context menu behind it.
///
/// The render half is asserted through `RenderCoordinator.request(for:)`, which is the one
/// place a request is built, so what the engine is asked for is a fact here rather than a
/// reading of the view.
final class OriginalHoldTests: XCTestCase {

    private var scratch: URL!

    private static func source(_ url: URL) -> SidecarSource {
        SidecarSource(name: url.lastPathComponent, size: 1, mtime: Date(), fingerprint: "x")
    }

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-original-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A developed frame carrying a visible Enhance block, which is the only interesting
    /// case: with nothing in Enhance the original and the picture are the same request.
    private func developedFrame() -> Frame {
        let url = scratch.appendingPathComponent("IMG_0001.CR2")
        FileManager.default.createFile(atPath: url.path, contents: Data([0]))
        var sidecar = Sidecar(source: Self.source(url))
        sidecar.develop = DevelopSettings(stock: "kodak-gold-200",
                                          tone: .print, autoBalance: true,
                                          base: BaseSettings(mode: .anchor))
        var enhance = EnhanceSettings()
        enhance.exposure = 0.45
        enhance.saturation = 0.3
        sidecar.enhance = enhance
        sidecar.look = "bw-classic"
        return Frame(url: url, sidecar: sidecar)
    }

    @MainActor
    func testTheFlagIsOffUntilItIsHeldAndClearsOnRelease() {
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        XCTAssertFalse(model.showsOriginal)
        XCTAssertFalse(model.renders.showsOriginal)

        model.showsOriginal = true
        XCTAssertTrue(model.renders.showsOriginal)

        model.showsOriginal = false
        XCTAssertFalse(model.renders.showsOriginal)
    }

    @MainActor
    func testTheRequestWhileHeldCarriesIdentityEnhanceAndTheFramesOwnDevelop() {
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        let frame = developedFrame()

        let settled = model.renders.request(for: frame)
        XCTAssertEqual(settled?.enhance.exposure, 0.45)
        XCTAssertEqual(settled?.enhance.saturation, 0.3)

        model.showsOriginal = true
        let held = model.renders.request(for: frame)
        XCTAssertEqual(held?.enhance, .identity, "the Enhance layer is what Original turns off")
        // Everything else is the frame's own, so the engine's developed stage for this
        // frame and scale is the same one the settled request wants.
        XCTAssertEqual(held?.develop, frame.sidecar.develop)
        XCTAssertEqual(held?.geometry, settled?.geometry)
        XCTAssertEqual(held?.scale, settled?.scale)
        // A Look is a named slider set written into the enhance layer and nothing more, so
        // identity enhance is the look off as well. The label survives because holding is
        // not an edit: the sidecar is untouched and the renderer never reads the label.
        XCTAssertEqual(frame.sidecar.enhance?.exposure, 0.45)
        XCTAssertEqual(frame.sidecar.look, "bw-classic")
        XCTAssertEqual(held?.develop.tone, .print, "develop is not part of what Original means")

        model.showsOriginal = false
        XCTAssertEqual(model.renders.request(for: frame), settled)
    }

    @MainActor
    func testClosingTheCloseupClearsTheFlag() {
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        model.showsOriginal = true
        model.closeViewer()
        XCTAssertFalse(model.showsOriginal)
        XCTAssertFalse(model.renders.showsOriginal)
    }

    /// The closeup clears it on every frame change, which is the release that never
    /// arrives: arrow away with M held and the next frame must not open on its original.
    /// The view's `onChange` calls this same setter, and the model is where the clear can
    /// be asserted without a window.
    @MainActor
    func testTheFlagCanBeClearedOnAFrameChangeWithoutTouchingTheSelection() {
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        model.showsOriginal = true
        model.showsOriginal = false
        XCTAssertFalse(model.renders.showsOriginal)
    }

    // MARK: the same hold on the gallery

    /// Three developed frames in a real folder, each with a visible Enhance block.
    @MainActor
    private func galleryWithDevelopedFrames() throws -> (AppModel, [Frame]) {
        let dir = scratch.appendingPathComponent("roll-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...3 {
            try Data(repeating: 0x42, count: 64).write(to: dir.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        XCTAssertNotNil(model.addFolder(dir))
        let frames = (model.selectedFolder?.frames ?? []).map { frame -> Frame in
            var f = frame
            f.sidecar = developedFrame().sidecar
            return f
        }
        XCTAssertEqual(frames.count, 3)
        return (model, frames)
    }

    @MainActor
    func testAGalleryHoldSwapsTheSelectedFramesAndLeavesTheRest() throws {
        let (model, frames) = try galleryWithDevelopedFrames()
        model.selection = [frames[0].id, frames[2].id]

        model.holdOriginalInGallery()

        XCTAssertTrue(model.showsOriginal)
        XCTAssertEqual(model.renders.originalScope, [frames[0].id, frames[2].id])
        XCTAssertEqual(model.renders.request(for: frames[0])?.enhance, .identity)
        XCTAssertEqual(model.renders.request(for: frames[2])?.enhance, .identity)
        XCTAssertEqual(model.renders.request(for: frames[1])?.enhance.exposure, 0.45,
                       "a frame outside the selection keeps its Enhance")
    }

    @MainActor
    func testAGalleryHoldWithNothingSelectedCoversTheRoll() throws {
        let (model, frames) = try galleryWithDevelopedFrames()
        model.selection = []

        model.holdOriginalInGallery()

        XCTAssertNil(model.renders.originalScope)
        for frame in frames {
            XCTAssertEqual(model.renders.request(for: frame)?.enhance, .identity)
        }
    }

    @MainActor
    func testTheReleaseClearsTheGalleryScope() throws {
        let (model, frames) = try galleryWithDevelopedFrames()
        model.selection = [frames[0].id]
        let settled = model.renders.request(for: frames[0])

        model.holdOriginalInGallery()
        model.showsOriginal = false

        XCTAssertNil(model.renders.originalScope, "a scope never outlives the hold")
        XCTAssertEqual(model.renders.request(for: frames[0]), settled)
        // The closeup's next hold is the closeup's, not the old selection's.
        model.showsOriginal = true
        XCTAssertEqual(model.renders.request(for: frames[1])?.enhance, .identity)
    }

    /// Return with M still held: the closeup must not open on a gallery hold.
    @MainActor
    func testOpeningTheCloseupEndsAGalleryHold() throws {
        let (model, frames) = try galleryWithDevelopedFrames()
        model.selection = [frames[1].id]
        model.holdOriginalInGallery()

        model.openViewer(on: frames[1].id)

        XCTAssertFalse(model.showsOriginal)
        XCTAssertNil(model.renders.originalScope)
    }

    /// The grid reads M through the closeup's own phase rule, repeats swallowed.
    func testTheGalleryHoldUsesTheCloseupsPhaseRule() throws {
        let grid = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FilmPositive/UI/Grid/GridView.swift"), encoding: .utf8)
        XCTAssertTrue(grid.contains("holdKey.install"), "the gallery catches M above the focus chain")
        XCTAssertTrue(grid.contains("ViewerView.originalHold(phase)"))
    }

    // MARK: one menu, two sites

    /// `GridView` has no `cellMenu` and both sites build `FrameContextMenu`. A source scan
    /// rather than a view assertion, because what is being protected is that a second copy
    /// of the menu cannot appear: two copies drift on the first change.
    func testBothSitesBuildTheOneSharedContextMenu() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FilmPositive/UI")

        let grid = try String(contentsOf: sources.appendingPathComponent("Grid/GridView.swift"), encoding: .utf8)
        let viewer = try String(contentsOf: sources.appendingPathComponent("Viewer/ViewerView.swift"), encoding: .utf8)
        let shared = try String(contentsOf: sources.appendingPathComponent("Shared/FrameContextMenu.swift"), encoding: .utf8)

        XCTAssertTrue(grid.contains("FrameContextMenu("), "the grid builds the shared menu")
        XCTAssertTrue(viewer.contains("FrameContextMenu("), "the closeup builds the shared menu")
        XCTAssertFalse(grid.contains("func cellMenu"), "the grid's private copy is gone for good")
        XCTAssertFalse(viewer.contains("func cellMenu"), "and the closeup never grew one")

        // The items, in order, in the one place they now live.
        for item in ["\"Develop\"", "\"Reset Develop\"", "\"Reset Enhance\"", "\"Reset Crop\"",
                     "Copy \\(section.title)", "\"Copy All\"", "model.pasteSettingsTitle",
                     "\"Duplicate\"", "\"Export…\"", "\"Reveal in Finder\""] {
            XCTAssertTrue(shared.contains(item), "the shared menu is missing \(item)")
        }
        // Flat, not a submenu. Line-based, because the prose above the
        // menu names `focusForContextMenu(on:)` and a bare substring search for "Menu("
        // matches that sentence rather than any code.
        let submenus = shared.split(separator: "\n").filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("Menu(") || line.hasPrefix("Menu {")
        }
        XCTAssertTrue(submenus.isEmpty, "the copy items stay flat, found \(submenus)")
    }

    /// The selection rule the menu depends on, at the model level: a right click on a frame
    /// that is already one of three leaves all three selected, so a paste or a reset from
    /// the closeup's menu still acts on the three.
    @MainActor
    func testContextMenuFocusOnAFrameInsideASelectionKeepsAllThree() {
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        let ids = (1...3).map { i -> Frame.ID in
            let url = scratch.appendingPathComponent("IMG_000\(i).CR2")
            FileManager.default.createFile(atPath: url.path, contents: Data([0]))
            return Frame(url: url, sidecar: Sidecar(source: Self.source(url))).id
        }
        model.selection = Set(ids)
        model.focusForContextMenu(on: ids[1])
        XCTAssertEqual(model.selection.count, 3)
        XCTAssertEqual(model.selection, Set(ids))

        // A frame outside it narrows to that one, which is Finder's other half.
        let outside = scratch.appendingPathComponent("IMG_0009.CR2")
        FileManager.default.createFile(atPath: outside.path, contents: Data([0]))
        let lone = Frame(url: outside, sidecar: Sidecar(source: Self.source(outside))).id
        model.focusForContextMenu(on: lone)
        XCTAssertEqual(model.selection, [lone])
    }
}
