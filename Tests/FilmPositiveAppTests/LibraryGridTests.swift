import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Evidence for the Library and the Grid.
///
/// The pure pieces (selection rules, the negative thumbnail transform, the cell state)
/// are tested directly. The folder rules are tested against a real `AppModel` over a real
/// temporary directory, because the thing worth proving about removing a folder is that
/// files survive a removal and no reading of the code can prove that.
final class LibraryGridTests: XCTestCase {

    // MARK: helpers

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-library-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A folder of plausible raw files. The bytes do not matter to anything under test
    /// here: scanning, selection and the develop commands never decode.
    @discardableResult
    private func makeFolder(_ name: String, files: [String], subfolder: (String, [String])? = nil) throws -> URL {
        let dir = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files {
            try Data(repeating: 0x42, count: 64).write(to: dir.appendingPathComponent(f))
        }
        if let (subName, subFiles) = subfolder {
            let sub = dir.appendingPathComponent(subName)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for f in subFiles {
                try Data(repeating: 0x42, count: 64).write(to: sub.appendingPathComponent(f))
            }
        }
        return dir
    }

    @MainActor
    private func makeModel() -> AppModel {
        AppModel(service: FailingRenderService(message: "no engine in tests"))
    }

    // MARK: the selection rules

    private typealias Sel = GridSelection<Int>

    func testPlainClickReplacesSelectionAndMovesAnchor() {
        let order = [1, 2, 3, 4, 5]
        var state = Sel.State(selected: [2, 3], anchor: 2)
        state = Sel.click(4, order: order, state: state, modifiers: [])
        XCTAssertEqual(state.selected, [4])
        XCTAssertEqual(state.anchor, 4)
    }

    func testCommandClickTogglesOneItemAndMovesAnchor() {
        let order = [1, 2, 3, 4, 5]
        var state = Sel.State(selected: [2], anchor: 2)
        state = Sel.click(4, order: order, state: state, modifiers: .command)
        XCTAssertEqual(state.selected, [2, 4], "command click adds without clearing")
        XCTAssertEqual(state.anchor, 4)

        state = Sel.click(2, order: order, state: state, modifiers: .command)
        XCTAssertEqual(state.selected, [4], "command click on a selected item removes it")
        XCTAssertEqual(state.anchor, 2)
    }

    func testShiftClickSelectsTheRunFromTheAnchorInEitherDirection() {
        let order = [1, 2, 3, 4, 5]
        var state = Sel.State(selected: [3], anchor: 3)
        state = Sel.click(5, order: order, state: state, modifiers: .shift)
        XCTAssertEqual(state.selected, [3, 4, 5])
        XCTAssertEqual(state.anchor, 3, "a range click must not move the anchor")

        state = Sel.click(1, order: order, state: state, modifiers: .shift)
        XCTAssertEqual(state.selected, [1, 2, 3], "the second range click re-ranges from the same anchor")
        XCTAssertEqual(state.anchor, 3)
    }

    func testShiftClickReplacesRatherThanAccumulates() {
        let order = [1, 2, 3, 4, 5]
        let state = Sel.click(2, order: order, state: Sel.State(selected: [5], anchor: 1), modifiers: .shift)
        XCTAssertEqual(state.selected, [1, 2], "5 was selected but is outside the run, so it goes")
    }

    func testCommandShiftClickUnionsTheRunIntoTheSelection() {
        let order = [1, 2, 3, 4, 5]
        let state = Sel.click(2, order: order, state: Sel.State(selected: [5], anchor: 1), modifiers: [.command, .shift])
        XCTAssertEqual(state.selected, [1, 2, 5])
        XCTAssertEqual(state.anchor, 1)
    }

    func testShiftClickWithNoAnchorBehavesLikeAPlainClick() {
        let state = Sel.click(3, order: [1, 2, 3], state: Sel.State(), modifiers: .shift)
        XCTAssertEqual(state.selected, [3])
        XCTAssertEqual(state.anchor, 3)
    }

    func testSelectAllTakesEveryItemInOrder() {
        let state = Sel.selectAll(order: [1, 2, 3, 4], state: Sel.State())
        XCTAssertEqual(state.selected, [1, 2, 3, 4])
        XCTAssertEqual(state.anchor, 1)
    }

    func testPruneDropsItemsAndAnchorsThatAreGone() {
        let state = Sel.prune(Sel.State(selected: [1, 2, 9], anchor: 9), to: [1, 2, 3])
        XCTAssertEqual(state.selected, [1, 2])
        XCTAssertNil(state.anchor)
    }

    // MARK: scanning is top level only

    func testScanReadsOnlyTheFoldersOwnRawFiles() throws {
        let dir = try makeFolder("roll-a",
                                 files: ["b.CR2", "a.cr2", "notes.txt", "c.NEF"],
                                 subfolder: ("rejects", ["deep1.CR2", "deep2.CR2"]))
        let frames = try FolderSession.scan(dir)
        XCTAssertEqual(frames.map(\.name), ["a.cr2", "b.CR2", "c.NEF"],
                       "raw files only, sorted, and nothing from the subfolder")
        XCTAssertFalse(frames.contains { $0.name.hasPrefix("deep") })
    }

    @MainActor
    func testAddFolderListsOnlyTheTopLevelFrames() throws {
        let dir = try makeFolder("roll-b", files: ["1.CR2", "2.CR2"], subfolder: ("sub", ["3.CR2"]))
        let model = makeModel()
        let session = model.addFolder(dir)
        XCTAssertNotNil(session, "addFolder failed: \(model.lastError ?? "no error reported")")
        XCTAssertEqual(model.folders.count, 1)
        XCTAssertEqual(model.folders[0].frames.count, 2)
    }

    // MARK: the sidebar row's numbers

    @MainActor
    func testSidebarHasOneRowPerFolderWithItsFrameCount() throws {
        let a = try makeFolder("roll-c", files: ["1.CR2", "2.CR2", "3.CR2"])
        let b = try makeFolder("roll-d", files: ["1.CR2"])
        let model = makeModel()
        model.addFolder(a)
        model.addFolder(b)
        XCTAssertEqual(model.folders.map { ($0.name, $0.frames.count) }.map { "\($0.0):\($0.1)" },
                       ["roll-c:3", "roll-d:1"])
        // The row also reports how many are developed, which starts at zero.
        XCTAssertEqual(model.folders.map { $0.frames.filter(\.isDeveloped).count }, [0, 0])
    }

    @MainActor
    func testAddingTheSameFolderTwiceDoesNotDuplicateTheRow() throws {
        let a = try makeFolder("roll-e", files: ["1.CR2"])
        let model = makeModel()
        model.addFolder(a)
        model.addFolder(a)
        XCTAssertEqual(model.folders.count, 1)
    }

    // MARK: removing touches nothing on disk

    @MainActor
    func testRemovingAFolderLeavesEveryFileOnDisk() throws {
        let dir = try makeFolder("roll-f", files: ["1.CR2", "2.CR2", "3.CR2"])
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        let model = makeModel()
        model.addFolder(dir)
        XCTAssertEqual(model.folders.count, 1)

        model.removeFolder(model.folders[0].id)
        XCTAssertTrue(model.folders.isEmpty)
        XCTAssertTrue(model.selection.isEmpty, "frames of a removed folder leave the selection")

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "the folder itself survives")
        let after = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(before, after, "every file is still there, byte for byte the same listing")
    }

    @MainActor
    func testRemovingAFolderIsUndoable() throws {
        let dir = try makeFolder("roll-g", files: ["1.CR2", "2.CR2"])
        let model = makeModel()
        model.addFolder(dir)
        model.removeFolder(model.folders[0].id)
        XCTAssertTrue(model.folders.isEmpty)

        model.undoManager.undo()
        XCTAssertEqual(model.folders.count, 1)
        XCTAssertEqual(model.folders[0].frames.count, 2)
    }

    // MARK: relaunch

    @MainActor
    func testRelaunchRestoresFoldersAndSilentlyDropsADeletedOne() throws {
        let keep = try makeFolder("roll-keep", files: ["1.CR2", "2.CR2"])
        let gone = try makeFolder("roll-gone", files: ["1.CR2"])

        let first = makeModel()
        first.addFolder(keep)
        first.addFolder(gone)
        XCTAssertEqual(first.folders.count, 2)

        // Between launches the second folder is deleted outside the app.
        try FileManager.default.removeItem(at: gone)

        let relaunched = makeModel()
        XCTAssertEqual(relaunched.folders.map(\.name), ["roll-keep"],
                       "the surviving folder comes back and the deleted one is dropped without an error")
        XCTAssertNil(relaunched.lastError, "dropping a deleted folder is silent")
        XCTAssertEqual(relaunched.folders.first?.frames.count, 2)
        XCTAssertEqual(relaunched.selectedFolderID, relaunched.folders.first?.id)
    }

    // MARK: develop acts on the selection alone

    @MainActor
    func testDevelopSelectionDevelopsOnlyTheSelectedFrames() throws {
        let dir = try makeFolder("roll-h", files: ["1.CR2", "2.CR2", "3.CR2", "4.CR2"])
        let model = makeModel()
        guard let session = model.addFolder(dir) else { return XCTFail("addFolder failed: \(model.lastError ?? "")") }
        try XCTSkipIf(model.renders.profiles == nil, "bundled profiles are not reachable from the test bundle")

        let ids = session.frames.map(\.id)
        model.selection = [ids[1], ids[3]]
        model.developSelection()

        let developed = model.folders[0].frames.filter(\.isDeveloped).map(\.name)
        XCTAssertEqual(developed, ["2.CR2", "4.CR2"])
        XCTAssertEqual(model.folders[0].frames.filter { !$0.isDeveloped }.map(\.name), ["1.CR2", "3.CR2"])
    }

    @MainActor
    func testSelectAllInViewCoversTheWholeFolderAndDevelopThenTakesItAll() throws {
        let dir = try makeFolder("roll-i", files: ["1.CR2", "2.CR2", "3.CR2"])
        let model = makeModel()
        model.addFolder(dir)
        try XCTSkipIf(model.renders.profiles == nil, "bundled profiles are not reachable from the test bundle")

        model.selectAllInView()
        XCTAssertEqual(model.selection.count, 3)
        model.developSelection()
        XCTAssertEqual(model.developedCountInView, 3)
    }

    @MainActor
    func testContextMenuOnAnUnselectedFrameRetargetsTheSelection() throws {
        let dir = try makeFolder("roll-j", files: ["1.CR2", "2.CR2", "3.CR2"])
        let model = makeModel()
        guard let session = model.addFolder(dir) else { return XCTFail("addFolder failed") }
        let ids = session.frames.map(\.id)

        model.selection = [ids[0], ids[1]]
        model.focusForContextMenu(on: ids[1])
        XCTAssertEqual(model.selection, [ids[0], ids[1]], "clicking inside the selection keeps it")

        model.focusForContextMenu(on: ids[2])
        XCTAssertEqual(model.selection, [ids[2]], "clicking outside it makes that frame the selection")
    }

    // MARK: the layers as the grid sees them

    @MainActor
    func testResetDevelopReturnsTheCellToTheNegativeAndResetEnhanceDoesNot() throws {
        let dir = try makeFolder("roll-k", files: ["1.CR2"])
        let model = makeModel()
        guard let session = model.addFolder(dir) else { return XCTFail("addFolder failed") }
        try XCTSkipIf(model.renders.profiles == nil, "bundled profiles are not reachable from the test bundle")
        let id = session.frames[0].id

        model.selection = [id]
        // An untouched frame is parked on the negative and renders nothing until the
        // Positive button is pressed.
        XCTAssertEqual(FrameCellState.of(frame: model.frame(id)!, hasImage: false), .negative)
        XCTAssertEqual(FrameCellState.of(frame: model.frame(id)!, hasImage: true), .negative)
        XCTAssertNil(model.renders.request(for: model.frame(id)!),
                     "and there is no render request for it at all")

        model.developSelection()
        XCTAssertEqual(FrameCellState.of(frame: model.frame(id)!, hasImage: false), .rendering,
                       "developed but the proxy has not landed, so the cell keeps the negative under a spinner")
        XCTAssertEqual(FrameCellState.of(frame: model.frame(id)!, hasImage: true), .positive)

        // Enhance comes and goes without disturbing the positive.
        model.apply({ SidecarEdits.setEnhance($0, EnhanceSettings(contrast: 0.5)) }, to: id, actionName: "Contrast")
        XCTAssertNotNil(model.frame(id)!.sidecar.enhance)
        model.resetEnhanceSelection()
        XCTAssertEqual(FrameCellState.of(frame: model.frame(id)!, hasImage: true), .positive,
                       "reset enhance leaves the frame developed")
        XCTAssertNotNil(model.frame(id)!.sidecar.develop)

        // Reset Positive clears the develop layer and the cell goes back to the negative,
        // while enhance, the look and geometry stay in the sidecar, dormant, and apply again
        // when the frame is made positive again.
        let look = Look(id: "arcade", name: "Arcade", blurb: "loud",
                        settings: EnhanceSettings(contrast: 0.25, saturation: 0.35), shipped: true)
        model.apply({ SidecarEdits.applyLook($0, look) }, to: id, actionName: "Apply Arcade")
        model.apply({ SidecarEdits.setGeometry($0, GeometrySettings(rotate: 90)) }, to: id, actionName: "Rotate")
        let held = model.frame(id)!.sidecar
        model.resetDevelopSelection()
        XCTAssertEqual(model.undoManager.undoActionName, "Reset Develop")
        let reset = model.frame(id)!.sidecar
        XCTAssertNil(reset.develop)
        XCTAssertEqual(reset.enhance, held.enhance, "the enhance layer is held")
        XCTAssertEqual(reset.look, "arcade", "and the look name")
        XCTAssertEqual(reset.geometry, held.geometry, "and geometry is untouched")
        XCTAssertEqual(FrameCellState.of(frame: model.frame(id)!, hasImage: true), .negative,
                       "reset develop puts the cell back on the negative")
        XCTAssertNil(model.renders.request(for: model.frame(id)!),
                     "a held enhance layer renders nothing while the frame is a negative")

        // Positive again: the held layer is back in the render.
        model.developSelection()
        let again = model.frame(id)!
        XCTAssertNotNil(again.sidecar.develop)
        XCTAssertEqual(again.sidecar.enhance, held.enhance)
        XCTAssertEqual(again.sidecar.look, "arcade")
        XCTAssertEqual(model.renders.request(for: again)?.enhance, held.enhance,
                       "the held enhance applies to the new positive")
    }

    @MainActor
    func testResetEnhanceOnANegativeClearsTheHeldLayerAndLeavesItANegative() throws {
        let dir = try makeFolder("roll-p75", files: ["1.CR2"])
        let model = makeModel()
        guard let session = model.addFolder(dir) else { return XCTFail("addFolder failed") }
        try XCTSkipIf(model.renders.profiles == nil, "bundled profiles are not reachable from the test bundle")
        let id = session.frames[0].id
        model.selection = [id]
        model.developSelection()
        model.apply({ SidecarEdits.setEnhance($0, EnhanceSettings(contrast: 0.5)) }, to: id, actionName: "Contrast")
        model.resetDevelopSelection()
        XCTAssertNotNil(model.frame(id)!.sidecar.enhance, "precondition: a held enhance layer")

        model.resetEnhanceSelection()
        XCTAssertNil(model.frame(id)!.sidecar.enhance, "Reset Enhance clears the held layer")
        XCTAssertNil(model.frame(id)!.sidecar.develop, "and does not make the frame positive")
        XCTAssertEqual(FrameCellState.of(frame: model.frame(id)!, hasImage: true), .negative)
    }

    // MARK: the negative thumbnail

    func testReduceBoxAveragesAndBoundsTheLongEdge() {
        // 100 x 40, a horizontal ramp, so the reduction has something to average.
        let w = 100, h = 40
        var pixels = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let p = (y * w + x) * 3
                let v = UInt16(x * 600)
                pixels[p] = v; pixels[p + 1] = v / 2; pixels[p + 2] = v / 4
            }
        }
        let bitmap = NegativeThumbnail.reduce(DecodedFrame(width: w, height: h, pixels: pixels), maxEdge: 25)
        XCTAssertEqual(bitmap.width, 25)
        XCTAssertEqual(bitmap.height, 10)
        XCTAssertEqual(bitmap.rgb.count, 25 * 10 * 3)

        let means = bitmap.channelMeans
        XCTAssertGreaterThan(means.r, means.g)
        XCTAssertGreaterThan(means.g, means.b, "no per channel normalization, so the channel imbalance survives")
        XCTAssertGreaterThan(means.r, 1.0, "the sRGB transfer lifts the linear ramp off black")
    }

    func testPercentileIgnoresAFewHotSamples() {
        var samples = [UInt16](repeating: 1000, count: 1000)
        samples.append(contentsOf: [UInt16](repeating: 65535, count: 3))
        XCTAssertEqual(NegativeThumbnail.percentile(samples, 0.995), 1000,
                       "three blown samples in a thousand must not set white")
    }

    func testReduceNeverDividesByZeroOnABlackFrame() {
        let frame = DecodedFrame(width: 8, height: 8, pixels: [UInt16](repeating: 0, count: 8 * 8 * 3))
        let bitmap = NegativeThumbnail.reduce(frame, maxEdge: 4)
        XCTAssertEqual(bitmap.rgb.count, 4 * 4 * 3)
        XCTAssertTrue(bitmap.rgb.allSatisfy { $0 == 0 })
    }

    /// The real thing: a fixture CR2 decoded at half size becomes a legible picture of the
    /// negative, and the mask is the check that matters.
    ///
    /// The ordering to expect is not the perceptual one. This is unity white balance raw
    /// camera space, where the C-41 orange mask attenuates red far harder than blue, so the
    /// signature of a negative here is that red is the lowest channel by a wide margin.
    /// That is what is asserted, for every fixture, with no threshold chosen by hand: were
    /// the transform quietly inverting or white balancing, red would not stay lowest.
    ///
    /// Green against blue is deliberately NOT asserted. Blue sits close enough to green
    /// that scene content moves it, and the six fixtures prove it: the 2026-09-11 session
    /// reads G above B while the 2026-09-10 session reads B a little above G. An assertion
    /// on that ordering would have been a fact about one session dressed as a fact about
    /// negatives.
    func testFixtureNegativeThumbnailIsALegiblePictureWithTheMaskIntact() throws {
        let urls = try fixtureRaws()
        for url in urls {
            let bitmap = try NegativeThumbnail.bitmap(of: url, maxEdge: 512)
            let means = bitmap.channelMeans
            let unique = Set(bitmap.rgb).count
            print("negative \(url.lastPathComponent): \(bitmap.width)x\(bitmap.height) "
                  + "means r=\(String(format: "%.1f", means.r)) g=\(String(format: "%.1f", means.g)) "
                  + "b=\(String(format: "%.1f", means.b)) "
                  + "r/g=\(String(format: "%.3f", means.r / means.g)) b/g=\(String(format: "%.3f", means.b / means.g)) "
                  + "distinct=\(unique)")

            XCTAssertLessThanOrEqual(max(bitmap.width, bitmap.height), 512, "\(url.lastPathComponent)")
            XCTAssertGreaterThan(min(bitmap.width, bitmap.height), 64, "\(url.lastPathComponent)")
            XCTAssertGreaterThan(unique, 32, "\(url.lastPathComponent): a real picture, not a flat rectangle")
            XCTAssertEqual(means.r, min(means.r, means.g, means.b), accuracy: 0,
                           "\(url.lastPathComponent): red is the lowest channel, which is the mask in raw camera space")
            XCTAssertLessThan(means.r / means.g, means.b / means.g,
                              "\(url.lastPathComponent): and red is attenuated harder than blue, which is the mask's own shape")
            XCTAssertGreaterThan(means.g, 8, "\(url.lastPathComponent): and it is not a black rectangle")
        }
        XCTAssertEqual(urls.count, 6, "all six fixture frames were checked")
    }

    /// And the developed positive of the same frame is a visibly different picture, which
    /// is what the grid's develop transition shows.
    func testDevelopedPositiveOfTheSameFrameLooksNothingLikeTheNegative() async throws {
        let url = try fixtureRaw()
        let service = CPURenderService(profiles: try ProfileLibrary.bundled(), enhance: IdentityEnhance())
        let request = RenderRequest(imageURL: url,
                                    develop: DevelopSettings(stock: "kodak-gold-200",
                                                             autoTone: true,
                                                             base: BaseSettings(mode: .anchor)),
                                    scale: .proxy)
        let positive = try await service.render(request).frame
        let positiveMeans = means(of: positive)
        let negativeMeans = try NegativeThumbnail.bitmap(of: url, maxEdge: 512).channelMeans

        print("positive \(url.lastPathComponent): means r=\(String(format: "%.1f", positiveMeans.r)) "
              + "g=\(String(format: "%.1f", positiveMeans.g)) b=\(String(format: "%.1f", positiveMeans.b))")

        // Develop divides the orange mask out and inverts the density, so the very thing
        // that makes a negative look like a negative has to be gone afterwards. The mask's
        // signature is the gap between blue and red in raw camera space; the claim is that
        // the gap survives in the negative and collapses in the positive, which is a
        // comparison between two numbers this run produced rather than a threshold.
        let negativeGap = negativeMeans.b - negativeMeans.r
        let positiveGap = abs(positiveMeans.b - positiveMeans.r)
        print(String(format: "blue minus red: negative %.1f, positive %.1f", negativeGap, positiveGap))
        XCTAssertGreaterThan(negativeGap, 10, "in the negative the mask holds blue well above red")
        XCTAssertLessThan(positiveGap, negativeGap / 2, "develop has to divide the mask out, not carry it through")

        // And the cell visibly changes, which is what the grid's develop transition shows.
        func luma(_ m: (r: Double, g: Double, b: Double)) -> Double { 0.2126 * m.r + 0.7152 * m.g + 0.0722 * m.b }
        XCTAssertGreaterThan(abs(luma(positiveMeans) - luma(negativeMeans)), 10,
                             "the two pictures differ by a margin no viewer could mistake")
    }

    private func means(of frame: DecodedFrame) -> (r: Double, g: Double, b: Double) {
        var sums = (0.0, 0.0, 0.0)
        for i in stride(from: 0, to: frame.pixels.count, by: 3) {
            sums.0 += Double(frame.pixels[i]) / 257
            sums.1 += Double(frame.pixels[i + 1]) / 257
            sums.2 += Double(frame.pixels[i + 2]) / 257
        }
        let n = Double(frame.width * frame.height)
        return (sums.0 / n, sums.1 / n, sums.2 / n)
    }

    private func fixturesRoot() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["FP_FIXTURES"] else {
            throw XCTSkip("FP_FIXTURES is not set")
        }
        return URL(fileURLWithPath: path)
    }

    private func fixtureRaws() throws -> [URL] {
        let root = try fixturesRoot()
        let urls = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.lowercased().hasSuffix(".cr2") }
            .sorted()
            .map { root.appendingPathComponent($0) }
        if urls.isEmpty { throw XCTSkip("no CR2 in FP_FIXTURES") }
        return urls
    }

    private func fixtureRaw() throws -> URL { try fixtureRaws()[0] }

    // MARK: the thumbnail cache

    @MainActor
    func testCacheAsksForEachFileOnceAndRemembersAFailure() async throws {
        let dir = try makeFolder("roll-l", files: ["broken.CR2"])
        let url = dir.appendingPathComponent("broken.CR2")
        let cache = NegativeThumbnailCache()

        XCTAssertNil(cache.thumbnail(for: url))
        XCTAssertNil(cache.thumbnail(for: url), "a second read in the same pass must not enqueue again")

        // 64 bytes of 0x42 is not a raw file, so LibRaw refuses it.
        for _ in 0..<200 where cache.failure(for: url) == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNotNil(cache.failure(for: url), "the failure is recorded rather than retried forever")
        XCTAssertEqual(cache.counts.pending, 0)
        XCTAssertNil(cache.thumbnail(for: url))
        XCTAssertEqual(cache.counts.pending, 0, "a known failure never queues work again")
    }

    @MainActor
    func testCacheLoadsAFixtureAndKeepsIt() async throws {
        let url = try fixtureRaw()
        let cache = NegativeThumbnailCache()
        XCTAssertNil(cache.thumbnail(for: url))
        for _ in 0..<400 where cache.counts.cached == 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let image = cache.thumbnail(for: url)
        XCTAssertNotNil(image, "cache failure: \(cache.failure(for: url) ?? "none reported")")
        XCTAssertLessThanOrEqual(image!.width, 512)
        XCTAssertEqual(cache.counts.cached, 1)
    }
}
