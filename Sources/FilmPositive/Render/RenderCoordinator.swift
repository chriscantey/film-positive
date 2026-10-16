import Foundation
import CoreGraphics
import Observation
import FilmSidecar
import FilmPositiveCore

/// One frame's render, in its own observable box.
///
/// Under Observation a view that reads `cache[someFrame]` from one `@Observable`
/// dictionary registers a dependency on the whole `cache` property, so storing the dragged
/// frame's render would invalidate every grid cell, the inspector and the viewer on every
/// drag tick. A box per frame means a view depends on the one frame it draws, and a drag
/// tick wakes exactly one cell.
@MainActor
@Observable
final class FrameRender {
    var entry: RenderCoordinator.Entry?
    init() {}
}

/// Renders on demand through the `RenderService`, one proxy per frame cached against the
/// request that produced it, so the grid and the viewer never render twice for the same
/// state and a slider drag only re-renders the frames under it.
@MainActor
@Observable
final class RenderCoordinator {
    struct Entry {
        let request: RenderRequest
        let image: CGImage
        let analysis: FrameAnalysis?
        /// What the render and the CGImage wrap cost, so the bench can split a
        /// slider-to-pixel interval into engine time and everything else.
        let renderMS: Double
        let wrapMS: Double
        /// Uptime nanoseconds when the render task started running and when the entry
        /// was stored, so the bench can see how long the main thread was busy before and
        /// after the engine (SwiftUI passes are the rest of a slider tick).
        let createdAt: UInt64
        let startedAt: UInt64
        let renderedAt: UInt64
        let resumedAt: UInt64
        let finishedAt: UInt64
    }

    let service: any RenderService
    /// Observation is per box, so this dictionary itself must not be observed: creating a
    /// box for a frame that has never rendered would otherwise invalidate every reader.
    ///
    /// Boxes are never dropped, which is deliberate: removing a folder is undoable, so an
    /// undo puts the same frames back and their renders are still here rather than the grid
    /// blanking and re-rendering the roll. One box holds one CGImage per frame that has
    /// been looked at.
    @ObservationIgnored private var boxes: [Frame.ID: FrameRender] = [:]
    private var inFlight: [Frame.ID: Task<Void, Never>] = [:]
    /// Bumped by every `invalidate` and every render start. A render task remembers the
    /// number it started under and, when it finishes, stores its picture only if that number
    /// is still current.
    ///
    /// Why a counter and not `Task.isCancelled`: the engine is synchronous CPU work with no
    /// suspension point inside, so canceling the task never stops the render. Without this
    /// guard the canceled task runs to the end, writes its picture of a state that no
    /// longer exists over the fresh one, and sets `inFlight` to nil under the render that
    /// replaced it, so the viewer holds the stale picture with `isStale` true and the
    /// spinner in the corner. Pinned by `RenderCoordinatorTests`, which lands the two
    /// renders in both orders.
    @ObservationIgnored private var generation: [Frame.ID: Int] = [:]
    var lastError: String?
    /// Where a vanished file's one readable sentence goes. `AppModel` points this at its
    /// non-modal banner, so deleting a frame in Finder never raises an alert. Unset in the
    /// bench and in tests that build a coordinator alone, where it falls back to
    /// `lastError` so nothing is ever swallowed.
    @ObservationIgnored var onFileVanished: ((String) -> Void)?
    /// Every frame under the drag, not just the one whose slider is being held, because a
    /// selection-wide edit re-renders the whole selection. Their requests ask for `.preview`
    /// (a quarter of the proxy's pixels through the same chain) and every other frame is
    /// untouched, so a drag never re-renders the rest of the grid. When the drag ends the
    /// desired request changes back to `.proxy`, the views ask for the settled render and
    /// keep showing the preview until it lands.
    var dragging: Set<Frame.ID> = []
    /// Set while the user holds M or the Original button: every request built while it is
    /// true asks for the frame with its Enhance layer at `.identity`.
    ///
    /// That is the whole of what "the original" means, and it takes a Look off with it. A
    /// Look is a named slider set written INTO the enhance layer and nothing more; the
    /// renderer never reads `sidecar.look`, which only tags the name. So there is no second
    /// layer to switch off and no second meaning to choose between.
    ///
    /// Transient and observed: flipping it changes the request every view asks for, so the
    /// picture swaps and swaps back with no edit, no undo entry and nothing written to disk.
    /// `AppModel.showsOriginal` is the one thing that writes it.
    var showsOriginal = false
    /// Which frames the hold covers. nil is every frame, which is the closeup's case
    /// (one frame on screen). A set is the gallery's selection, so holding M over a roll
    /// swaps the frames the person chose and leaves the rest of the roll as it is.
    var originalScope: Set<Frame.ID>?

    /// The develop layer an undeveloped frame renders through, snapshotted per folder
    /// session by `AppModel`. Every frame in the grid asks for a request, so this
    /// is read on the hot path and must stay a plain stored value.
    @ObservationIgnored var defaults = DevelopDefaults()

    /// A visible cell costs a proxy decode plus a rebate histogram. Scrolling a folder
    /// of 114 frames would otherwise start 114 renders at once and hand the machine a
    /// thundering herd whose first result the user sees last.
    ///
    /// So: at most `maxConcurrentRenders` renders run, and the rest queue in arrival order.
    /// FIFO rather than LIFO on purpose, because arrival order here IS roughly the order
    /// cells became visible, and a stack would render the bottom of the screen first.
    /// `invalidate` drops a frame's pending request, so scrolling away before a render
    /// starts costs nothing.
    static let maxConcurrentRenders = 4
    @ObservationIgnored private var pending: [(id: Frame.ID, frame: Frame, request: RenderRequest)] = []

    /// How many renders are running right now. Test seam for the cap.
    var activeRenderCount: Int { inFlight.count }
    /// How many requests are waiting for a slot. Test seam for the cap.
    var pendingRenderCount: Int { pending.count }

    init(service: any RenderService) { self.service = service }

    /// The box for a frame, created on first ask. Creating one registers no observation,
    /// so a cell asking about a frame that has not rendered yet wakes nobody.
    func box(for id: Frame.ID) -> FrameRender {
        if let b = boxes[id] { return b }
        let b = FrameRender()
        boxes[id] = b
        return b
    }

    /// The cached entry for a frame. Reading this from a view is what subscribes that view
    /// to THAT frame alone, which is the whole point of the box.
    func entry(for id: Frame.ID) -> Entry? { box(for: id).entry }

    var profiles: ProfileLibrary? { (service as? CPURenderService)?.profiles ?? (try? ProfileLibrary.bundled()) }

    /// The request the frame's current state wants. `scale` nil means the display scale,
    /// `.preview` for the frame under a drag and `.proxy` otherwise.
    ///
    /// A frame with NO develop layer gets no request, so it is not rendered at all and the
    /// grid, the closeup and the inspector all show the negative. An undeveloped frame is
    /// seen as it is and spends no resources until the user develops it.
    ///
    /// Only the automatic RENDER is skipped. The defaults machinery stays: the Positive
    /// rows still read `AppModel.effectiveDevelop`, so an untouched frame's rows show the
    /// values a press would write, and the funnel in `AppModel.apply` still commits those
    /// same values on the first edit. `defaults` never puts a picture on screen nobody
    /// asked for.
    func request(for frame: Frame, scale: RenderScale? = nil) -> RenderRequest? {
        guard frame.sidecar.develop != nil,
              let develop = defaults.develop(for: frame.sidecar) else { return nil }
        var enhance = frame.sidecar.enhance ?? .identity
        // Hold to see the original. One request differing from the settled one in its
        // enhance block alone, so the engine's developed stage for this frame and scale is
        // the same cache entry and the swap costs the enhance chain rather than a decode.
        if showsOriginal, originalScope?.contains(frame.id) ?? true { enhance = .identity }
        return RenderRequest(imageURL: frame.url, develop: develop, geometry: frame.sidecar.geometry ?? GeometrySettings(),
                             enhance: enhance, scale: scale ?? (dragging.contains(frame.id) ? .preview : .proxy))
    }

    /// The cached proxy for this frame's CURRENT state, or nil while it renders (a render
    /// is started if none is in flight). Strict: it answers "are the pixels on screen the
    /// pixels this state wants", which is what the slider latency measurement needs.
    /// To DRAW a frame, use `displayImage` instead.
    func proxy(for frame: Frame) -> CGImage? {
        guard let req = request(for: frame) else { return nil }
        if let e = entry(for: frame.id), e.request == req { return e.image }
        startRender(frame, req)
        return nil
    }

    /// What a view should actually DRAW: the fresh render when there is one, otherwise the
    /// last positive this frame had, marked stale.
    ///
    /// A view asking `proxy` gets nil the instant a setting changes and would fall back to
    /// the NEGATIVE thumbnail, so applying a look would make the picture jump back to an
    /// orange negative and then return, which reads as "it reset my frame to zero and
    /// started over" rather than as "the new version is a moment away". Holding the previous
    /// positive avoids that, and it costs nothing: the image is already in the box.
    func displayImage(for frame: Frame) -> (image: CGImage, isStale: Bool)? {
        guard let req = request(for: frame) else { return nil }
        if let e = entry(for: frame.id), e.request == req { return (e.image, false) }
        startRender(frame, req)
        guard let e = entry(for: frame.id) else { return nil }
        return (e.image, true)
    }

    /// Asks for a render, which either starts now or waits for a slot.
    ///
    /// The in-flight check stays here rather than moving into the queue: a frame that is
    /// already rendering the request it wants needs neither a second render nor a queue
    /// slot, and that case is most of the calls, because every SwiftUI pass over a visible
    /// cell asks again.
    private func startRender(_ frame: Frame, _ req: RenderRequest) {
        guard inFlight[frame.id] == nil else { return }
        if let i = pending.firstIndex(where: { $0.id == frame.id }) { pending[i] = (frame.id, frame, req) }
        else { pending.append((frame.id, frame, req)) }
        drainPending()
    }

    /// Starts as many queued renders as there are free slots, oldest first.
    private func drainPending() {
        while inFlight.count < Self.maxConcurrentRenders, !pending.isEmpty {
            let next = pending.removeFirst()
            // Something started this frame between queueing and draining. Its own
            // completion drains again, so dropping this entry loses nothing.
            guard inFlight[next.id] == nil else { continue }
            beginRender(next.frame, next.request)
        }
    }

    private func beginRender(_ frame: Frame, _ req: RenderRequest) {
        let gen = (generation[frame.id] ?? 0) + 1
        generation[frame.id] = gen
        let created = DispatchTime.now()
        inFlight[frame.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let t0 = DispatchTime.now()
                let result = try await service.render(req)
                let t1 = DispatchTime.now()
                let img = try Exporter.cgImage(result.frame, tagged: ExportColorSpace.sRGB.cgColorSpace)
                let t2 = DispatchTime.now()
                // Invalidated while rendering: this is a picture of a state that no longer
                // exists. Drop it, and leave the slot to whichever render replaced this one.
                guard self.generation[frame.id] == gen else { return }
                self.box(for: frame.id).entry = Entry(request: req, image: img, analysis: result.analysis,
                                             renderMS: Self.ms(t0, t1), wrapMS: Self.ms(t1, t2),
                                             createdAt: created.uptimeNanoseconds, startedAt: t0.uptimeNanoseconds,
                                             renderedAt: result.renderedAt, resumedAt: t1.uptimeNanoseconds,
                                             finishedAt: DispatchTime.now().uptimeNanoseconds)
            } catch {
                // A stale render's failure is nobody's business either: the state it failed on
                // is gone and the alert would name a problem the user cannot see.
                guard self.generation[frame.id] == gen else { return }
                // A file that vanished under us is not an engine failure and must not read
                // like one. The alert's complete error text exists for a raw the engine
                // REFUSED, where every word of the engine's complaint is diagnostic. A
                // `NSCocoaErrorDomain Code=260` with a file path in it is noise about
                // something the user already knows they did.
                if !FileManager.default.fileExists(atPath: frame.url.path) {
                    let sentence = "\(frame.name) is no longer on disk."
                    if let vanished = self.onFileVanished { vanished(sentence) } else { self.lastError = sentence }
                } else {
                    self.lastError = "\(frame.name): \(error)"
                }
            }
            self.inFlight[frame.id] = nil
            self.drainPending()
        }
    }

    func analysis(for id: Frame.ID) -> FrameAnalysis? { entry(for: id)?.analysis }

    private static func ms(_ a: DispatchTime, _ b: DispatchTime) -> Double {
        Double(b.uptimeNanoseconds &- a.uptimeNanoseconds) / 1_000_000
    }

    func invalidate(_ id: Frame.ID) {
        // A queued request for this frame is a picture of a state that is now
        // gone, so it is dropped rather than rendered and thrown away. This is also what
        // makes scroll-away cheap: the cell stops asking and its slot is never spent.
        pending.removeAll { $0.id == id }
        inFlight[id]?.cancel()
        inFlight[id] = nil
        // The running task cannot be stopped (see `generation`), so it is disowned instead:
        // whatever it produces is for a state that is gone.
        generation[id, default: 0] += 1
        // keep the stale image until the new one lands so the grid never blanks
    }
}
