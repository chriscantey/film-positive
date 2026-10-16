import XCTest
import CoreGraphics
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The concurrency cap on the render coordinator.
///
/// Every visible cell of a PROCESSED frame wants a proxy decode plus a rebate histogram,
/// and a grid that asks for all of them at once hands the machine a thundering herd whose
/// first result the user sees last. That is the real case: a roll somebody has worked on
/// and comes back to, scrolled from the top.
///
/// The frames here are developed deliberately. An untouched frame renders nothing at all, so
/// a fixture of negatives would reach the cap zero times and this suite would pass by
/// measuring nothing.
///
/// So: at most four renders run and the rest queue, and `invalidate` drops a frame's
/// pending request so scrolling away before its slot comes up costs nothing.
///
/// The service here parks every render on a continuation until the test releases it, so
/// "four are running and the rest are waiting" is asserted rather than raced.
final class RenderConcurrencyCapTests: XCTestCase {

    /// A render service that never finishes on its own. One continuation per frame url, so
    /// the test can let exactly one render through and watch a queued one take its slot.
    final class ParkedRenderService: RenderService, @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
        private var startedNames: [String] = []

        func render(_ request: RenderRequest) async throws -> RenderResult {
            let name = request.imageURL.lastPathComponent
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                waiters[name] = c
                startedNames.append(name)
                lock.unlock()
            }
            return RenderResult(frame: DecodedFrame(width: 2, height: 2,
                                                    pixels: Array(repeating: 1000, count: 12)),
                                analysis: nil)
        }

        /// The frames whose render actually entered the engine, in order.
        var started: [String] { lock.lock(); defer { lock.unlock() }; return startedNames }

        func release(_ name: String) {
            lock.lock()
            let c = waiters.removeValue(forKey: name)
            lock.unlock()
            c?.resume()
        }
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-render-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    @MainActor
    private func model(count: Int, service: any RenderService) throws -> (AppModel, [Frame]) {
        let dir = scratch.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...count {
            try Data(repeating: 0x42, count: 64)
                .write(to: dir.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        let m = AppModel(service: service)
        m.undoManager.groupsByEvent = false
        XCTAssertNotNil(m.addFolder(dir))
        // The defaults must resolve, or every committed layer is nil and the cap is never
        // reached.
        m.renders.defaults = DevelopDefaults(profiles: try ProfileLibrary.bundled())
        // Press Develop on the whole roll, which is what makes these frames renderable at
        // all. Done before anything asks for a picture, so no render has started.
        m.selectAllInView()
        m.developSelection()
        m.deselectAllInView()
        let frames = m.selectedFolder?.frames ?? []
        XCTAssertEqual(frames.count, count)
        XCTAssertTrue(frames.allSatisfy(\.isDeveloped), "the fixture must be renderable")
        XCTAssertEqual(m.renders.activeRenderCount, 0, "and nothing has been asked for yet")
        return (m, frames)
    }

    /// Ten visible cells, four slots. The other six wait.
    @MainActor
    func testScrollingTenCellsRunsFourRendersAndQueuesTheRest() throws {
        let service = ParkedRenderService()
        let (m, frames) = try model(count: 10, service: service)

        for f in frames { _ = m.renders.displayImage(for: f) }

        XCTAssertEqual(m.renders.activeRenderCount, RenderCoordinator.maxConcurrentRenders,
                       "exactly the cap is in flight")
        XCTAssertEqual(m.renders.pendingRenderCount, 10 - RenderCoordinator.maxConcurrentRenders,
                       "and the rest are queued rather than dropped or started")
    }

    /// The queue is FIFO, because arrival order here IS roughly the order cells became
    /// visible. A stack would render the bottom of the screen first.
    @MainActor
    func testAFinishedRenderLetsTheOldestQueuedOneThrough() async throws {
        let service = ParkedRenderService()
        let (m, frames) = try model(count: 6, service: service)
        for f in frames { _ = m.renders.displayImage(for: f) }

        // A render is an async Task, so it enters the engine on a later turn of the loop.
        // The coordinator's own slot count is synchronous and is what the cap is about; the
        // service's `started` is what proves the queued one was not merely counted.
        XCTAssertEqual(m.renders.activeRenderCount, RenderCoordinator.maxConcurrentRenders)
        try await waitFor("four renders to enter the engine") {
            service.started.count == RenderCoordinator.maxConcurrentRenders
        }

        let first = try XCTUnwrap(service.started.first)
        service.release(first)
        try await waitFor("the freed slot to be taken") {
            service.started.count > RenderCoordinator.maxConcurrentRenders
        }

        XCTAssertEqual(service.started.count, RenderCoordinator.maxConcurrentRenders + 1,
                       "the freed slot went to exactly one queued render")
        XCTAssertEqual(service.started.last, "IMG_0005.CR2",
                       "and it went to the OLDEST queued request, not the newest")
        XCTAssertEqual(m.renders.pendingRenderCount, 1)
    }

    /// Polls a condition on the main actor rather than sleeping a fixed time, so the test is
    /// not a race that happens to pass on a fast machine.
    @MainActor
    private func waitFor(_ what: String, timeout: TimeInterval = 5,
                         _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Scroll-away: a queued request is dropped by `invalidate`, so a cell that left the
    /// screen never spends a slot. This is the half that makes the cap cheap rather than
    /// merely polite.
    @MainActor
    func testInvalidateDropsAQueuedRequestWithoutRenderingIt() async throws {
        let service = ParkedRenderService()
        let (m, frames) = try model(count: 8, service: service)
        for f in frames { _ = m.renders.displayImage(for: f) }
        XCTAssertEqual(m.renders.pendingRenderCount, 4)
        try await waitFor("the first four to enter the engine") {
            service.started.count == RenderCoordinator.maxConcurrentRenders
        }

        // The last two cells scroll off.
        m.renders.invalidate(frames[6].id)
        m.renders.invalidate(frames[7].id)

        XCTAssertEqual(m.renders.pendingRenderCount, 2, "the two queued requests are gone")
        XCTAssertFalse(service.started.contains("IMG_0007.CR2"), "and neither was ever rendered")
        XCTAssertFalse(service.started.contains("IMG_0008.CR2"))
    }

    /// Asking repeatedly for the same frame, which is what every SwiftUI pass does, must not
    /// grow the queue. Without the de-duplication in `startRender` a grid that redraws a few
    /// times would hold hundreds of copies of the same request.
    @MainActor
    func testAskingForTheSameFrameRepeatedlyDoesNotGrowTheQueue() throws {
        let service = ParkedRenderService()
        let (m, frames) = try model(count: 6, service: service)
        for _ in 0..<5 {
            for f in frames { _ = m.renders.displayImage(for: f) }
        }
        XCTAssertEqual(m.renders.activeRenderCount, RenderCoordinator.maxConcurrentRenders)
        XCTAssertEqual(m.renders.pendingRenderCount, 2,
                       "one queue entry per frame however many times it is asked for")
    }
}
