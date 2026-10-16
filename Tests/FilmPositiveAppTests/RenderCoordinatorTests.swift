import XCTest
import CoreGraphics
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// A render service whose renders finish when the test says so, in the order the test
/// says, so the coordinator's handling of two overlapping renders of the same frame can be
/// asserted rather than raced. Each render parks on a continuation keyed by the request's
/// quarter turn, and the picture it returns encodes that turn in its pixels, so the image
/// that lands can be told apart from the one that should have.
final class GatedRenderService: RenderService, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var started: [Int: Int] = [:]

    func render(_ request: RenderRequest) async throws -> RenderResult {
        let key = request.geometry.rotate
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            waiters[key, default: []].append(c)
            started[key, default: 0] += 1
            lock.unlock()
        }
        let v = UInt16(key)
        return RenderResult(frame: DecodedFrame(width: 2, height: 2, pixels: Array(repeating: v, count: 12)), analysis: nil)
    }

    /// How many renders have been asked for at this turn, landed or not.
    func renders(of key: Int) -> Int { lock.lock(); defer { lock.unlock() }; return started[key] ?? 0 }

    /// True once at least one render for this turn is parked and waiting.
    func isWaiting(_ key: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return !(waiters[key] ?? []).isEmpty }

    /// Let every parked render for this turn finish.
    func release(_ key: Int) {
        lock.lock()
        let cs = waiters.removeValue(forKey: key) ?? []
        lock.unlock()
        for c in cs { c.resume() }
    }
}

/// The coordinator holds one render per frame. What this suite pins down is what happens
/// when a second edit arrives while the first edit's render is still running: the frame's
/// state has moved on, so the first render is now a picture of a state that no longer
/// exists, and it must never be shown as the current one.
///
/// The task that `invalidate` cancels keeps running, because the engine never checks for
/// cancellation. When it finishes it must not store its stale picture over the fresh one or
/// clear the in-flight slot that belongs to the newer render.
final class RenderCoordinatorTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-coordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    @MainActor
    private func modelWithOneDevelopedFrame(service: any RenderService) throws -> (AppModel, Frame.ID) {
        let dir = scratch.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 64).write(to: dir.appendingPathComponent("IMG_0001.CR2"))
        let model = AppModel(service: service)
        model.undoManager.groupsByEvent = false
        XCTAssertNotNil(model.addFolder(dir))
        let id = try XCTUnwrap(model.selectedFolder?.frames.first?.id)
        model.undoManager.beginUndoGrouping()
        model.apply({ s in
            SidecarEdits.setDevelop(s, DevelopSettings(
                stock: "kodak-gold-200",
                autoTone: false,
                base: BaseSettings(mode: .anchor, anchor: 4000, ratios: BaseRatios(rg: 0.22648, bg: 1.32673))))
        }, to: id, actionName: "seed")
        model.undoManager.endUndoGrouping()
        return (model, id)
    }

    @MainActor
    private func turn(_ model: AppModel, _ id: Frame.ID, to degrees: Int) {
        model.undoManager.beginUndoGrouping()
        model.apply({ SidecarEdits.setGeometry($0, GeometrySettings(rotate: degrees)) }, to: id, actionName: "turn")
        model.undoManager.endUndoGrouping()
    }

    /// Polls on the main actor so the coordinator's tasks get to run between checks.
    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor
    private func settle() async throws { try await Task.sleep(nanoseconds: 150_000_000) }

    /// The reported bug, made deterministic: the newer render lands first, then the stale
    /// one arrives late. The picture on screen must stay the newer one.
    @MainActor
    func testAStaleRenderLandingLateNeverOverwritesTheCurrentOne() async throws {
        let service = GatedRenderService()
        let (model, id) = try modelWithOneDevelopedFrame(service: service)

        turn(model, id, to: 90)
        XCTAssertNil(model.renders.proxy(for: try XCTUnwrap(model.frame(id))), "nothing rendered yet")
        try await waitUntil("the 90 render to start") { service.isWaiting(90) }

        // The second edit arrives while the first render is still running.
        turn(model, id, to: 180)
        XCTAssertNil(model.renders.proxy(for: try XCTUnwrap(model.frame(id))))
        try await waitUntil("the 180 render to start") { service.isWaiting(180) }

        service.release(180)
        try await waitUntil("the 180 picture to land") { model.renders.entry(for: id)?.request.geometry.rotate == 180 }

        service.release(90)
        try await settle()

        let entry = try XCTUnwrap(model.renders.entry(for: id))
        XCTAssertEqual(entry.request.geometry.rotate, 180, "the cancelled render wrote its stale picture over the current one")
        let shown = try XCTUnwrap(model.renders.displayImage(for: try XCTUnwrap(model.frame(id))))
        XCTAssertFalse(shown.isStale, "the viewer would draw the old picture and spin forever")
        XCTAssertEqual(service.renders(of: 180), 1, "the current state was rendered more than once")
    }

    /// The other order, which already worked and must keep working: the stale render lands
    /// first and the newer one after it. Guards the fix from over-correcting into a
    /// coordinator that drops the newer render too.
    @MainActor
    func testTheNewerRenderStillLandsWhenTheStaleOneFinishesFirst() async throws {
        let service = GatedRenderService()
        let (model, id) = try modelWithOneDevelopedFrame(service: service)

        turn(model, id, to: 90)
        _ = model.renders.proxy(for: try XCTUnwrap(model.frame(id)))
        try await waitUntil("the 90 render to start") { service.isWaiting(90) }
        turn(model, id, to: 180)
        _ = model.renders.proxy(for: try XCTUnwrap(model.frame(id)))
        try await waitUntil("the 180 render to start") { service.isWaiting(180) }

        service.release(90)
        try await settle()
        service.release(180)
        try await waitUntil("the 180 picture to land") { model.renders.entry(for: id)?.request.geometry.rotate == 180 }

        let shown = try XCTUnwrap(model.renders.displayImage(for: try XCTUnwrap(model.frame(id))))
        XCTAssertFalse(shown.isStale)
        XCTAssertEqual(service.renders(of: 180), 1, "the current state was rendered more than once")
    }

    /// Invalidated with nothing new asked for yet: the stale picture is dropped rather than
    /// kept as if it were current, and no engine-error alert is raised on its account.
    @MainActor
    func testAStaleRenderIsDroppedEvenWhenNothingNewWasAskedFor() async throws {
        let service = GatedRenderService()
        let (model, id) = try modelWithOneDevelopedFrame(service: service)
        turn(model, id, to: 90)
        _ = model.renders.proxy(for: try XCTUnwrap(model.frame(id)))
        try await waitUntil("the 90 render to start") { service.isWaiting(90) }
        // Invalidate with no new render asked for, then let the stale one finish.
        turn(model, id, to: 180)
        service.release(90)
        try await settle()
        XCTAssertNil(model.renders.lastError)
        XCTAssertNotEqual(model.renders.entry(for: id)?.request.geometry.rotate, 90, "a picture of a state that no longer exists was kept")
    }

    // MARK: no automatic render on open

    /// A frame with no develop layer is asked for nothing, so nothing renders and every
    /// consumer (`request`, `proxy`, `displayImage`) sees no picture.
    ///
    /// Asserted through all three accessors rather than just `request`, because `request` is
    /// the gate and the other two are what the grid and the closeup actually call. Both of
    /// them also START a render as a side effect, so a gate that held for `request` alone
    /// would still burn the CPU this change exists to stop spending.
    @MainActor
    func testAnUndevelopedFrameGetsNoRequestNoProxyAndNoRender() async throws {
        // GatedRenderService counts every render it is asked for, at turn 0 here, and
        // parks it forever: a render that should never start cannot be released, so the
        // count is the assertion and the park is what makes a leaked render visible rather
        // than merely slow.
        let service = GatedRenderService()
        let dir = scratch.appendingPathComponent("roll-negative")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 64).write(to: dir.appendingPathComponent("IMG_0001.CR2"))
        let model = AppModel(service: service)
        model.undoManager.groupsByEvent = false
        XCTAssertNotNil(model.addFolder(dir))
        let frame = try XCTUnwrap(model.selectedFolder?.frames.first)

        XCTAssertNil(model.renders.request(for: frame))
        XCTAssertNil(model.renders.proxy(for: frame))
        XCTAssertNil(model.renders.displayImage(for: frame))
        try await settle()
        XCTAssertEqual(service.renders(of: 0), 0, "no render was started for a negative")
        XCTAssertEqual(model.renders.activeRenderCount, 0)
        XCTAssertEqual(model.renders.pendingRenderCount, 0)

        // The defaults are still there: the inspector's rows read this.
        XCTAssertNotNil(model.effectiveDevelop(for: frame))

        // And a press of Positive turns it on.
        model.selection = [frame.id]
        model.developSelection()
        let after = try XCTUnwrap(model.frame(frame.id))
        XCTAssertTrue(after.isDeveloped)
        XCTAssertNotNil(model.renders.request(for: after), "after the press it renders like any other")
    }
}
