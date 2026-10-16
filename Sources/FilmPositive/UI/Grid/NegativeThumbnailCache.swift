import Foundation
import CoreGraphics
import Observation
import FilmSidecar

/// The grid's cache of undeveloped negative thumbnails.
///
/// `thumbnail(for:)` is the only entry point and behaves like `RenderCoordinator.proxy`:
/// it returns the picture if it has one and otherwise returns nil and starts the work.
/// Four rules matter here.
///
/// The decode runs off the main actor. `NegativeThumbnail.bitmap` is a half size LibRaw
/// decode plus a reduction, hundreds of milliseconds of CPU, so it goes to a detached task
/// and only the small bitmap comes back.
///
/// At most `maxConcurrent` decodes run at once, and the queue is drained newest first.
/// A half size decode of a 20 MP raw allocates about 27 MB, so a forty frame folder
/// scrolled quickly would otherwise try to hold a gigabyte, and the frames the user is
/// actually looking at are the ones asked for last.
///
/// A failure is remembered. Without that, a file LibRaw cannot read would be retried on
/// every single redraw forever.
///
/// The decoded bitmap is kept geometry-free and the frame's geometry is applied to it on
/// the way out, memoized per URL for the geometry last asked for. That is what makes a
/// flip or a rotate show on a frame that has never been made positive: such a frame never
/// reaches the render service, so this is the only picture it has.
///
/// The cost of that is one extra copy of a cached thumbnail's bytes: the reduced bitmap
/// and the image drawn from it are both held. A 512 edge thumbnail is about half a
/// megabyte, so a full cache is roughly twice what holding the image alone would be. The
/// alternative is re-decoding the raw on every geometry edit, which is hundreds of
/// milliseconds and a visible stall on a frame the user is turning.
///
/// Nothing observable is written on the read path. `thumbnail(for:)` is called from inside
/// a view body, so the bookkeeping fields are `@ObservationIgnored` and the queue is
/// touched on a later turn of the main actor. Only `bitmaps`, `failed` and `lastError`
/// participate in observation, and all three are written after the update that asked.
@MainActor
@Observable
final class NegativeThumbnailCache {
    /// The geometry-free reduced negative, one per file. Observed, so a cell wakes when
    /// its decode lands.
    private var bitmaps: [URL: ThumbnailBitmap] = [:]
    private var failed: [URL: String] = [:]

    /// The last geometry drawn for a file and the image it produced. One entry per file,
    /// because a frame draws one geometry at a time. `@ObservationIgnored` on purpose: it
    /// is written from inside a view body (see the read path note above) and it is a memo,
    /// not state, so nothing needs to wake when it changes.
    @ObservationIgnored private var rendered: [URL: (geometry: GeometrySettings, image: CGImage)] = [:]

    @ObservationIgnored private var requested: Set<URL> = []
    @ObservationIgnored private var queued: [URL] = []
    @ObservationIgnored private var running: Set<URL> = []
    /// Insertion order, for eviction.
    @ObservationIgnored private var arrival: [URL] = []

    let capacity: Int
    let maxConcurrent: Int
    let maxEdge: Int

    /// Set when a decode fails, so a caller can surface it once rather than per cell.
    private(set) var lastError: String?

    init(capacity: Int = 160, maxConcurrent: Int = 3, maxEdge: Int = NegativeThumbnail.defaultMaxEdge) {
        self.capacity = capacity
        self.maxConcurrent = maxConcurrent
        self.maxEdge = maxEdge
    }

    /// The thumbnail for this raw under this geometry, or nil while it is being made.
    ///
    /// The decode happens once per file; the geometry is a pass over the small bitmap and
    /// is redone whenever the frame's geometry differs from the one last drawn, so an edit
    /// lands on the next redraw with no re-decode and nothing to invalidate.
    func thumbnail(for url: URL, geometry: GeometrySettings = GeometrySettings()) -> CGImage? {
        if let bitmap = bitmaps[url] {
            if let last = rendered[url], last.geometry == geometry { return last.image }
            guard let image = NegativeThumbnail.image(NegativeThumbnail.geometry(bitmap, geometry)) else { return nil }
            rendered[url] = (geometry, image)
            return image
        }
        if failed[url] != nil { return nil }
        guard !requested.contains(url) else { return nil }
        requested.insert(url)
        Task { @MainActor [weak self] in self?.enqueue(url) }
        return nil
    }

    /// Whether this raw was tried and could not be read, and why.
    func failure(for url: URL) -> String? { failed[url] }

    /// Drops a frame's picture, for a rescan or a folder removal.
    func forget(_ url: URL) {
        bitmaps[url] = nil
        rendered[url] = nil
        failed[url] = nil
        requested.remove(url)
        queued.removeAll { $0 == url }
        arrival.removeAll { $0 == url }
    }

    func forgetAll() {
        bitmaps.removeAll()
        rendered.removeAll()
        failed.removeAll()
        requested.removeAll()
        queued.removeAll()
        arrival.removeAll()
    }

    /// Counts for the tests: what is cached, what failed, what is still outstanding.
    var counts: (cached: Int, failed: Int, pending: Int) {
        (bitmaps.count, failed.count, queued.count + running.count)
    }

    // MARK: work

    private func enqueue(_ url: URL) {
        guard bitmaps[url] == nil, failed[url] == nil, !running.contains(url), !queued.contains(url) else { return }
        queued.append(url)
        pump()
    }

    private func pump() {
        // Newest first: the cells the user just scrolled to are the ones asked for last.
        while running.count < maxConcurrent, let url = queued.popLast() {
            running.insert(url)
            let edge = maxEdge
            Task { [weak self] in
                let outcome: Result<ThumbnailBitmap, Error>
                do { outcome = .success(try await Self.make(url, maxEdge: edge)) }
                catch { outcome = .failure(error) }
                self?.finish(url, outcome)
            }
        }
    }

    /// `nonisolated` and detached, so the body runs on the cooperative pool rather than
    /// hopping back to the main actor with a 27 MB frame in hand.
    private nonisolated static func make(_ url: URL, maxEdge: Int) async throws -> ThumbnailBitmap {
        try await Task.detached(priority: .utility) {
            try NegativeThumbnail.bitmap(of: url, maxEdge: maxEdge)
        }.value
    }

    private func finish(_ url: URL, _ outcome: Result<ThumbnailBitmap, Error>) {
        running.remove(url)
        switch outcome {
        case .success(let bitmap):
            bitmaps[url] = bitmap
            arrival.append(url)
            evict()
        case .failure(let error):
            failed[url] = "\(error)"
            lastError = "\(url.lastPathComponent): \(error)"
        }
        pump()
    }

    private func evict() {
        while arrival.count > capacity {
            let oldest = arrival.removeFirst()
            bitmaps[oldest] = nil
            rendered[oldest] = nil
            requested.remove(oldest)
        }
    }
}
