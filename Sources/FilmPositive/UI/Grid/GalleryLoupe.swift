import SwiftUI
import AppKit
import CoreGraphics
import FilmSidecar
import FilmPositiveCore

/// Pick Base in the gallery.
///
/// After pressing the dropper, hovering any thumbnail shows the loupe magnifying that spot
/// of that frame at proxy resolution, and a click samples it for the selection. So the
/// eyedropper does not route through the closeup, and a click on a hundred point cell,
/// which alone would be a guess and not a pick, is answered by the magnifier rather than by
/// a change of screen.
///
/// The mapping is the part that can quietly write a wrong number into somebody's files, so
/// it is a pure value here with no SwiftUI in it, and it ends in exactly the same
/// `PickBaseMapping` the closeup uses. One display-normalized point comes out of the hover
/// and BOTH the loupe's content offset and the sampled patch are derived from it, so the
/// picture cannot show one spot while the click measures another.
enum GalleryPick {

    /// The geometry the gallery pick works in: the frame's quarter turn and mirror, with
    /// the crop and the straighten stripped.
    ///
    /// A cropped positive is a picture of part of the frame, and the film base is by
    /// definition outside the part anybody crops to, so a pick over a cropped cell would be
    /// aiming at the one region the picture no longer contains. Stripping the crop is what
    /// makes the cell under the cursor and `PickBaseMapping` describe the same rectangle of
    /// film.
    static func pickGeometry(_ g: GeometrySettings?) -> GeometrySettings {
        let g = g ?? GeometrySettings()
        return GeometrySettings(rotate: g.rotate, flip: g.flip, straightenDegrees: 0, crop: nil)
    }

    /// Where the picture actually lands inside a cell's picture box.
    ///
    /// The cell box is a fixed 3 by 2 and the negative is drawn `scaledToFit` inside it, so
    /// every frame that is not exactly 3 by 2 is letterboxed, and the letterbox is NOT
    /// film. Deriving this rather than treating the box as the picture is what makes a
    /// hover over the grey bar report no reading instead of a point off the end of the
    /// frame.
    static func fittedRect(aspect: CGFloat, in box: CGSize) -> CGRect {
        guard aspect > 0, box.width > 0, box.height > 0 else { return .zero }
        var w = box.width, h = box.width / aspect
        if h > box.height { h = box.height; w = h * aspect }
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    /// A point in the cell's picture box as a DISPLAY normalized point, or nil when the
    /// cursor is on the letterbox rather than on film.
    static func displayPoint(_ p: CGPoint, box: CGSize, aspect: CGFloat) -> CGPoint? {
        let rect = fittedRect(aspect: aspect, in: box)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let n = CGPoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height)
        guard (0...1).contains(n.x), (0...1).contains(n.y) else { return nil }
        return n
    }

    /// The sampled square as a DISPLAY normalized rect, for drawing inside the loupe.
    ///
    /// `pixels` is the drawn picture's own pixel size, already oriented. Only its ASPECT
    /// reaches the answer: `patchRect` states the half width as a fraction of the decode's
    /// width and the half height as the same number of pixels over its height, so the rect
    /// is scale free and a 512 pixel thumbnail and a 1400 pixel negative give the same
    /// normalized square.
    static func patchDisplayRect(at display: CGPoint, mapping: PickBaseMapping,
                                 pixels: CGSize) -> CGRect {
        let turned = mapping.rotate == 90 || mapping.rotate == 270
        let w = Int(turned ? pixels.height : pixels.width)
        let h = Int(turned ? pixels.width : pixels.height)
        let decode = mapping.decodePoint(fromDisplay: display)
        let patch = PickBaseMapping.patchRect(around: decode, radius: PickBasePatch.radius,
                                              width: max(w, 1), height: max(h, 1))
        return mapping.displayRect(fromDecode: patch)
    }
}

/// What the grid's one loupe is currently pointed at, and the sharper negatives it has
/// fetched.
///
/// One object owned by `GridView`, written by whichever cell the cursor is over. The
/// alternative, a loupe per cell, cannot work: a cell clips its own overlays and later
/// cells paint over earlier ones, so a magnifier that hangs off the top of a thumbnail
/// would be cut in half by the row above it.
@MainActor
@Observable
final class GalleryPickHover {

    /// One hover, resolved all the way to a display normalized point so nothing downstream
    /// has to redo the mapping.
    struct Spot: Equatable {
        var frame: Frame.ID
        var url: URL
        /// The frame's name, so the readout can say which cell it is reading.
        var stem: String
        /// Turn and mirror only, see `GalleryPick.pickGeometry`.
        var geometry: GeometrySettings
        /// The cell's picture box in the grid's named coordinate space.
        var box: CGRect
        /// The drawn picture's aspect, so the fitted rect can be rebuilt for drawing.
        var aspect: CGFloat
        /// The drawn picture's pixel size, for the patch rect's proportions.
        var pixels: CGSize
        /// Where the cursor is, normalized inside the fitted picture.
        var point: CGPoint
    }

    private(set) var spot: Spot?

    /// The live reading under the cursor, the same number the closeup's readout shows.
    ///
    /// Without it a pick from the grid is blind: the user aims at what LOOKS like clear
    /// film and finds out whether it was by reading the note after the write. The closeup
    /// shows R/G and B/G under the cursor, and the gallery has to say the same thing or the
    /// two tools disagree about what a pick is.
    private(set) var reading: BaseRatios?

    /// Proxy resolution negatives, at most three. Keyed by file, so scrubbing back and
    /// forth across a few frames costs one decode each and then nothing.
    private(set) var sharp: [URL: CGImage] = [:]
    @ObservationIgnored private var order: [URL] = []
    @ObservationIgnored private var dwell: Task<Void, Never>?
    /// One sample in flight at a time. A mouse move fires far faster than a patch mean and
    /// the answer worth having is the one under the cursor NOW, so a busy sampler drops the
    /// request rather than queueing it. Exactly the closeup's `read(at:)` rule.
    @ObservationIgnored private var sampling = false

    /// How long the cursor has to sit on one frame before its negative is decoded. A half
    /// size decode of a twenty megapixel raw is hundreds of milliseconds of CPU, so sweeping
    /// the cursor across a row of forty cells must not start forty of them.
    static let dwellNanoseconds: UInt64 = 150_000_000
    static let capacity = 3
    /// Long edge of the decoded negative. The thumbnail is 512, which is soft at three
    /// times; this is proxy resolution in the sense that matters, the same half size LibRaw
    /// decode the sample itself reads, reduced far less.
    static let sharpMaxEdge = 1400

    func moved(to s: Spot, service: RenderService) {
        let arrived = spot?.frame != s.frame
        spot = s
        if arrived {
            // A stale reading belongs to the frame the cursor just left, and a number from
            // the wrong frame is worse than no number.
            reading = nil
            beginDwell(s, service: service)
        } else {
            read(s, service: service)
        }
    }

    /// Only the frame that owns the hover may clear it, or a neighbour disappearing off the
    /// top of the scroll view would put the loupe out while the cursor is still on film.
    func left(_ id: Frame.ID) {
        guard spot?.frame == id else { return }
        clear()
    }

    func clear() {
        spot = nil
        reading = nil
        dwell?.cancel()
        dwell = nil
    }

    func image(for url: URL) -> CGImage? { sharp[url] }

    /// The reading for one spot. Canceled per frame id by construction: the result is
    /// dropped unless the cursor is still on the frame it was measured from.
    private func read(_ s: Spot, service: RenderService) {
        guard !sampling else { return }
        sampling = true
        let point = PickBaseMapping(geometry: s.geometry).decodePoint(fromDisplay: s.point)
        Task { [weak self] in
            let means = await service.samplePatch(url: s.url, at: point,
                                                  radius: PickBasePatch.radius)
            guard let self else { return }
            self.sampling = false
            guard self.spot?.frame == s.frame else { return }
            self.reading = means.flatMap { BaseResolver.ratios(fromRebate: $0) }
        }
    }

    private func beginDwell(_ s: Spot, service: RenderService) {
        dwell?.cancel()
        let url = s.url, geometry = s.geometry
        dwell = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.dwellNanoseconds)
            guard !Task.isCancelled else { return }
            // The reading first: it is what the user is waiting on, and the first sample of
            // a frame carries the proxy decode that the sharper picture then reuses.
            self?.read(s, service: service)
            guard self?.sharp[url] == nil else { return }
            let made = await Task.detached(priority: .userInitiated) { () -> ThumbnailBitmap? in
                guard let bitmap = try? NegativeThumbnail.bitmap(of: url, maxEdge: Self.sharpMaxEdge) else {
                    return nil
                }
                return NegativeThumbnail.geometry(bitmap, geometry)
            }.value
            guard !Task.isCancelled, let made, let image = NegativeThumbnail.image(made) else { return }
            self?.store(image, for: url)
        }
    }

    private func store(_ image: CGImage, for url: URL) {
        sharp[url] = image
        order.removeAll { $0 == url }
        order.append(url)
        while order.count > Self.capacity, let oldest = order.first {
            sharp[oldest] = nil
            order.removeFirst()
        }
    }
}

/// The grid's single loupe, drawn in the scroll content's named space so no cell can clip
/// it and no later cell can paint over it.
struct GalleryPickLoupe: View {
    let hover: GalleryPickHover
    let thumbnails: NegativeThumbnailCache
    /// The scroll content's bounds, which the loupe is kept inside.
    let content: CGSize

    var body: some View {
        if let spot = hover.spot, let image = picture(spot) {
            let fitted = GalleryPick.fittedRect(aspect: spot.aspect, in: spot.box.size)
            let picture = CGRect(x: spot.box.minX + fitted.minX, y: spot.box.minY + fitted.minY,
                                 width: fitted.width, height: fitted.height)
            let cursor = CGPoint(x: picture.minX + spot.point.x * picture.width,
                                 y: picture.minY + spot.point.y * picture.height)
            let mapping = PickBaseMapping(geometry: spot.geometry)
            let patch = GalleryPick.patchDisplayRect(at: spot.point, mapping: mapping,
                                                    pixels: spot.pixels)
            PickBaseOverlay(image: image, fitted: picture.size, center: spot.point, patch: patch,
                            stem: spot.stem, reading: hover.reading,
                            cursor: cursor, bounds: content)
        }
    }

    /// The sharper negative once the dwell has produced one, and the cell's own thumbnail
    /// until then, so the loupe appears on the first frame the cursor lands on rather than
    /// a beat later.
    private func picture(_ spot: GalleryPickHover.Spot) -> CGImage? {
        hover.image(for: spot.url) ?? thumbnails.thumbnail(for: spot.url, geometry: spot.geometry)
    }
}
