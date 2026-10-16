import SwiftUI
import AppKit
import CoreGraphics
import FilmSidecar
import FilmPositiveCore

/// Pick Base: the eyedropper over the uncropped frame in the closeup.
///
/// The coordinate mapping is the one place a wrong number reaches the user's files, and it
/// is the whole reason this file is shaped the way it is: a click arrives in view points,
/// after the quarter turn and the mirror the engine applied, after the aspect-fit letterbox
/// the pane laid out, and it has to come back as a normalized point in the DECODE's own
/// space, which is where `Calibrator.patchEstimate` reads pixels.
///
/// Two consequences, both deliberate.
///
/// The mapping is a plain value type with no SwiftUI in it (`PickBaseMapping`), so it is
/// testable at four asymmetric corners of a rotated and flipped frame against
/// `Geometry.orient` as ground truth rather than against itself.
///
/// The moving square is drawn by projecting the SAMPLED rect back through the INVERSE of
/// the same mapping. That is not a nicety: it means the overlay cannot agree with the
/// sample unless the mapping is right, so the picture on screen is evidence about the
/// number being written rather than a second implementation of it.

/// The view-space to decode-space mapping for one frame, in normalized coordinates on
/// both sides, x and y in 0 to 1 with y down.
///
/// The only transform in play is the engine's orientation, `flip` then `rotate` clockwise
/// (`DevelopTables.dstIndex`), because the pane deliberately renders the frame with NO
/// crop and NO straighten: `GalleryPick.pickGeometry` sets `straightenDegrees: 0, crop: nil`
/// and the pane applies no `rotationEffect`. A straighten preview is a view rotation the
/// engine has not performed, so leaving it out is what keeps this mapping exact rather
/// than approximately right by a degree or two.
struct PickBaseMapping: Equatable {
    /// The frame's stored quarter turn, 0, 90, 180 or 270, clockwise.
    var rotate: Int
    /// The frame's stored mirror, applied before the turn.
    var flip: Bool

    init(geometry: GeometrySettings) {
        self.rotate = ((geometry.rotate % 360) + 360) % 360
        self.flip = geometry.flip
    }

    init(rotate: Int, flip: Bool) {
        self.rotate = ((rotate % 360) + 360) % 360
        self.flip = flip
    }

    /// Display normalized to decode normalized: the inverse of what the engine did.
    ///
    /// `dstIndex` maps a decode pixel (cx, cy) to a display pixel. With `uf` for the
    /// mirrored x, that is (uf, v) at 0 degrees, (1 - v, uf) at 90, (1 - uf, 1 - v) at 180
    /// and (v, 1 - uf) at 270. These four cases are those read backwards.
    func decodePoint(fromDisplay p: CGPoint) -> CGPoint {
        let dx = Double(p.x), dy = Double(p.y)
        let uf: Double, v: Double
        switch rotate {
        case 90:  v = 1 - dx; uf = dy
        case 180: uf = 1 - dx; v = 1 - dy
        case 270: v = dx; uf = 1 - dy
        default:  uf = dx; v = dy
        }
        return CGPoint(x: flip ? 1 - uf : uf, y: v)
    }

    /// Decode normalized to display normalized: what the engine did.
    func displayPoint(fromDecode p: CGPoint) -> CGPoint {
        let u = Double(p.x), v = Double(p.y)
        let uf = flip ? 1 - u : u
        switch rotate {
        case 90:  return CGPoint(x: 1 - v, y: uf)
        case 180: return CGPoint(x: 1 - uf, y: 1 - v)
        case 270: return CGPoint(x: v, y: 1 - uf)
        default:  return CGPoint(x: uf, y: v)
        }
    }

    /// The sampled square, projected back for drawing. Two opposite corners are enough
    /// because every case here is axis aligned; the min and max put them back in order
    /// after a reflection.
    func displayRect(fromDecode r: CGRect) -> CGRect {
        let a = displayPoint(fromDecode: CGPoint(x: r.minX, y: r.minY))
        let b = displayPoint(fromDecode: CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// The patch `Calibrator.patchEstimate` will read, as a normalized DECODE rect, given
    /// the decode's pixel dimensions. The patch is square in PIXELS, so it is only square
    /// in normalized coordinates on a square frame, which is exactly why the drawing goes
    /// through this rather than through a normalized radius.
    static func patchRect(around point: CGPoint, radius: Double,
                          width: Int, height: Int) -> CGRect {
        guard width > 0, height > 0 else { return .zero }
        let halfPixels = max(1.0, Double(width) * radius)
        let halfU = halfPixels / Double(width)
        let halfV = halfPixels / Double(height)
        return CGRect(x: Double(point.x) - halfU, y: Double(point.y) - halfV,
                      width: 2 * halfU, height: 2 * halfV)
    }
}

/// The eyedropper's two numbers that every site has to agree on.
///
/// `radius` is shared by the drawing, the sample and the gallery mode. It is stated once
/// because the square on screen is evidence about the number being written, and a drawing
/// radius that drifted from the sampling radius would turn that evidence into a decoration.
/// It is 0.01, not 0.02: 0.02 of the frame width is a patch wide enough to swallow the
/// strip between two sprocket holes, which is exactly the place a base gets picked.
enum PickBasePatch {
    /// Half-width of the sampled square as a fraction of the DECODE's width.
    static let radius = 0.01
    /// The loupe circle, in points.
    static let loupeDiameter: CGFloat = 96
    /// How much bigger the film looks inside it.
    static let magnification: CGFloat = 3
}

/// The round loupe: the negative magnified around one point, with the SQUARE that will
/// actually be sampled drawn inside it.
///
/// The square inside the circle is the whole reason the loupe is safe to show. A round
/// magnifier over a square mean invites the reading that everything in the circle is being
/// averaged, and it is not; drawing the footprint in the magnified coordinate frame means
/// the picture cannot lie about the number.
struct PickBaseLoupe: View {
    /// The picture to magnify, already oriented the way the user sees it.
    let image: CGImage
    /// The size the image is drawn at, unmagnified, in points.
    let fitted: CGSize
    /// The point under the cursor, normalized in that fitted rect.
    let center: CGPoint
    /// The sampled square, normalized in the same space.
    let patch: CGRect

    var body: some View {
        let d = PickBasePatch.loupeDiameter
        let m = PickBasePatch.magnification
        let w = fitted.width * m, h = fitted.height * m
        let ox = d / 2 - center.x * w, oy = d / 2 - center.y * h
        Color.black
            .frame(width: d, height: d)
            .overlay(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: w, height: h)
                    .offset(x: ox, y: oy)
            }
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .stroke(Color.white, lineWidth: 1)
                    .frame(width: max(patch.width * w, 2), height: max(patch.height * h, 2))
                    .offset(x: ox + patch.minX * w, y: oy + patch.minY * h)
            }
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Where the circle and the label go, given the pointer and the bounds they live in.
    ///
    /// The circle is centered on the pointer and is NEVER CLAMPED, on either axis. It may
    /// overhang the bounds and be clipped, and that is correct: the circle is what says
    /// where the sample is taken, so a rule that moves it is a rule that lies. Clamping the
    /// two together would put the center 24.5 points right of the pointer at the film's
    /// bottom left corner and 53 points right at the left edge, both pinning to x about
    /// 725, because the LABEL is 124 wide against the circle's 96 and its left edge hits the
    /// pane first.
    ///
    /// The label is placed independently: centered under the circle, flipped above it when
    /// it would fall out of the bottom, then clamped so it stays readable. Letting it slide
    /// out from under the circle near an edge is the cost, and it is the right one, because
    /// the label is a caption and the circle is the instrument.
    static func place(cursor: CGPoint, in bounds: CGSize) -> Placement {
        let d = PickBasePatch.loupeDiameter
        let w = PickBasePanel.width, h = PickBasePanel.labelHeight, gap = PickBasePanel.gap
        let loupe = CGPoint(x: cursor.x - d / 2, y: cursor.y - d / 2)

        var y = loupe.y + d + gap
        if y + h > bounds.height { y = loupe.y - gap - h }
        y = min(max(y, 0), max(bounds.height - h, 0))
        let x = min(max(cursor.x - w / 2, 0), max(bounds.width - w, 0))
        return Placement(loupe: loupe, label: CGPoint(x: x, y: y))
    }

    /// Two top left corners, in the bounds' own space.
    struct Placement: Equatable {
        var loupe: CGPoint
        var label: CGPoint
        /// The circle's center, which must always be the pointer.
        var loupeCenter: CGPoint {
            CGPoint(x: loupe.x + PickBasePatch.loupeDiameter / 2,
                    y: loupe.y + PickBasePatch.loupeDiameter / 2)
        }
    }

    /// The panel's width, kept here for the callers that were written against it.
    static var readoutWidth: CGFloat { PickBasePanel.width }
}

/// The dark rounded label under the loupe: which frame is being read, and what it reads.
///
/// Shared by both surfaces. Two implementations of the same idea drift on the first edit,
/// so there is one.
struct PickBaseReadout: View {
    let stem: String
    let reading: BaseRatios?

    var body: some View {
        // No file name line, because which file it is is already clear. The stem is still
        // passed in so the accessibility label can name the frame, and only the picture
        // drops it.
        VStack(spacing: 1) {
            Group {
                if let reading {
                    Text(String(format: "R/G %.3f   B/G %.3f", reading.rg, reading.bg))
                } else {
                    Text("no reading")
                }
            }
            .font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
        .frame(width: PickBasePanel.width)
        .accessibilityLabel(stem)
    }
}

/// The whole floating magnifier: the circle with the sample square inside it, and the label
/// under it. ONE view for the closeup and the gallery, placing both pieces by one rule
/// (`PickBaseLoupe.place`), so the two surfaces cannot drift apart.
///
/// It fills the bounds it is given and positions its two children inside them, rather than
/// being a panel the caller offsets, because the two are not one rectangle: the
/// circle tracks the pointer and the label clamps on its own.
struct PickBaseOverlay: View {
    let image: CGImage
    /// The size the picture is drawn at, unmagnified, in points.
    let fitted: CGSize
    /// The point under the cursor, normalized in that picture.
    let center: CGPoint
    /// The sampled square, normalized in the same space.
    let patch: CGRect
    let stem: String
    let reading: BaseRatios?
    /// The pointer, in the bounds' own space.
    let cursor: CGPoint
    /// The surface the label is kept inside: the pane, or the scroll content.
    let bounds: CGSize

    var body: some View {
        let p = PickBaseLoupe.place(cursor: cursor, in: bounds)
        ZStack(alignment: .topLeading) {
            PickBaseLoupe(image: image, fitted: fitted, center: center, patch: patch)
                .offset(x: p.loupe.x, y: p.loupe.y)
            PickBaseReadout(stem: stem, reading: reading)
                .offset(x: p.label.x, y: p.label.y)
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The floating magnifier's fixed sizes, in one place so both surfaces measure the same.
enum PickBasePanel {
    /// The label is wider than the circle, which is the whole reason the two are placed
    /// separately.
    static let width: CGFloat = 124
    static let labelHeight: CGFloat = 22
    static let gap: CGFloat = 4
    static var readoutHeight: CGFloat { labelHeight + gap }
    /// Circle plus label, for anything that needs the pair's footprint.
    static var size: CGSize {
        CGSize(width: width, height: PickBasePatch.loupeDiameter + readoutHeight)
    }
}

/// The full width bar that says the next click measures film. ONE view for both surfaces.
struct PickBaseBar: View {
    /// `AppModel.pickBaseHeader`: the count it will write, and the frame it is sampling.
    let text: String

    static let hint = "Click the unexposed film on any frame. Escape to cancel."

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eyedropper")
            Text(text).fontWeight(.semibold)
            Text(Self.hint).foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.tint)
    }
}

/// The picture the closeup aims at while the eyedropper is on: the RAW NEGATIVE.
///
/// A develop render here would show a POSITIVE on a processed frame while the gallery loupe
/// shows the negative, so the same tool would point at two different pictures depending on
/// which screen you armed it from. It is the negative, everywhere, for the duration of the
/// mode.
///
/// It is the same source the gallery uses, `NegativeThumbnail.bitmap`, at a long edge that
/// suits a full window rather than a thumbnail, with the frame's turn and mirror applied
/// and the crop and straighten stripped by the same `GalleryPick.pickGeometry`. One
/// function for both sites is the point: the drawn square, the loupe and `samplePatch` all
/// resolve against one normalized point only because the picture under them was oriented
/// exactly the way `PickBaseMapping` assumes.
struct PickBaseNegative: Equatable {
    var image: CGImage?
    /// The oriented picture's pixel size, which is what the patch rect's proportions need.
    var pixels: CGSize?
    var error: String?

    /// Long edge. The gallery's 512 is soft blown up across a closeup, and the decode is
    /// half size whatever this is, so the cost is the reduction rather than the read.
    static let maxEdge = 2400

    /// Turn and mirror only. Literally the gallery's function, not a copy of it.
    static func geometry(_ g: GeometrySettings?) -> GeometrySettings { GalleryPick.pickGeometry(g) }

    /// What identifies the picture, so the closeup decodes once per frame and orientation
    /// rather than once per redraw.
    struct Key: Equatable {
        var url: URL
        var geometry: GeometrySettings
    }

    /// Blocking and CPU bound. Never call this on the main actor.
    static func make(_ key: Key) throws -> ThumbnailBitmap {
        NegativeThumbnail.geometry(try NegativeThumbnail.bitmap(of: key.url, maxEdge: maxEdge),
                                   key.geometry)
    }
}

/// The pane: the whole frame, a crosshair, a square that follows the cursor and reads out
/// what is under it, and a click that writes.
struct PickBasePane: View {
    @Environment(AppModel.self) private var model
    let frame: Frame
    let negative: PickBaseNegative

    /// The patch half-width. One constant for the drawing, the readout, the click and the
    /// gallery mode, see `PickBasePatch`.
    private let radius = PickBasePatch.radius

    /// Where the cursor is, in display normalized coordinates. Nil when it is outside.
    @State private var hover: CGPoint?
    /// The live readout under the cursor: the ratios of the patch the square is over.
    @State private var reading: BaseRatios?
    /// Serialized so a fast mouse move cannot leave a stale reading behind a fresh one.
    @State private var sampling = false
    /// Whether this pane currently owns a pushed cursor, so the pops match the pushes.
    @State private var cursorPushed = false

    /// Built on the SAME stripped geometry the picture was oriented with, so the mapping
    /// and the pixels under it can never describe different rectangles of film.
    private var mapping: PickBaseMapping {
        PickBaseMapping(geometry: PickBaseNegative.geometry(frame.sidecar.geometry))
    }

    var body: some View {
        GeometryReader { geo in
            let box = fittedBox(in: geo.size)
            ZStack {
                if let image = negative.image {
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: box.width, height: box.height)
                    }
                    .frame(width: box.width, height: box.height)
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let p):
                            let n = CGPoint(x: p.x / box.width, y: p.y / box.height)
                            guard (0...1).contains(n.x), (0...1).contains(n.y) else { hover = nil; return }
                            hover = n
                            Task { await read(at: n) }
                        case .ended:
                            hover = nil
                            reading = nil
                        }
                    }
                    // A tap gesture carries no location, so the click is the END of a
                    // zero-distance drag, the same shape `CropPane` uses for its grips.
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        let n = CGPoint(x: value.location.x / box.width,
                                        y: value.location.y / box.height)
                        guard (0...1).contains(n.x), (0...1).contains(n.y) else { return }
                        Task { await pick(at: n) }
                    })
                    // Balanced by a flag. A bare push on true and pop on false is not
                    // balanced under hover churn: SwiftUI can send two trues in a row when
                    // the overlay under the cursor changes, and every unmatched push leaves
                    // a crosshair on the whole app until something else pops it.
                    .onHover { inside in
                        if inside, !cursorPushed { NSCursor.crosshair.push(); cursorPushed = true }
                        if !inside, cursorPushed { NSCursor.pop(); cursorPushed = false }
                    }
                    .onDisappear {
                        if cursorPushed { NSCursor.pop(); cursorPushed = false }
                    }
                } else if let error = negative.error {
                    Text(error).font(.callout).foregroundStyle(.orange).padding()
                } else {
                    ProgressView()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // The panel is placed against the PANE, not against the picture. Clamped to
            // the fitted rect it cannot stay on the pointer at the film edge, which is the
            // one place the tool is actually used: at the bottom left corner of the film the
            // circle pins about 27 points right and 59 points above the pointer and stops
            // tracking it (probes at x 690 and 668 both land at 724).
            // Overhanging into the pane's dark margin is correct there, and it is what the
            // gallery already does against the scroll view's visible rect.
            .overlay(alignment: .topLeading) { panel(in: geo.size, box: box) }
        }
    }

    /// The floating panel: the magnified circle with the sample square inside it, and the
    /// label under it. Exactly what the gallery draws, placed by exactly the same rule.
    ///
    /// ONE square, inside the circle. A second one on the film at the pointer would read as
    /// two samples for one, and the label could cover it anyway, since the panel sits on the
    /// pointer.
    ///
    /// The panel is still a SECOND view of the same two numbers rather than a third
    /// computation of them: it is handed the display point and the display patch rect the
    /// sample is taken from, so it cannot disagree with the sample.
    ///
    /// `box` is the fitted picture inside `pane`, which the outer stack centers, so the
    /// pointer's pane-space position is the centering inset plus its position in the picture.
    @ViewBuilder
    private func panel(in pane: CGSize, box: CGSize) -> some View {
        if let hover, let pixels = negative.pixels, let image = negative.image {
            let point = mapping.decodePoint(fromDisplay: hover)
            let patch = PickBaseMapping.patchRect(around: point, radius: radius,
                                                  width: decodeWidth(pixels), height: decodeHeight(pixels))
            let shown = mapping.displayRect(fromDecode: patch)
            let inset = CGPoint(x: (pane.width - box.width) / 2, y: (pane.height - box.height) / 2)
            let cursor = CGPoint(x: inset.x + hover.x * box.width,
                                 y: inset.y + hover.y * box.height)
            PickBaseOverlay(image: image, fitted: box, center: hover, patch: shown,
                            stem: frame.stem, reading: reading, cursor: cursor, bounds: pane)
        }
    }

    /// The picture on screen carries the orientation already, so a quarter turn swaps its
    /// dimensions back to get the decode's own width and height. `negative.pixels` is the
    /// ORIENTED picture, not the raw decode, which is why this is not just `.width`.
    private func decodeWidth(_ pixels: CGSize) -> Int {
        Int((mapping.rotate == 90 || mapping.rotate == 270) ? pixels.height : pixels.width)
    }

    private func decodeHeight(_ pixels: CGSize) -> Int {
        Int((mapping.rotate == 90 || mapping.rotate == 270) ? pixels.width : pixels.height)
    }

    private func fittedBox(in size: CGSize) -> CGSize {
        let a = max(negative.displayAspect, 0.0001)
        var w = size.width, h = size.width / a
        if h > size.height { h = size.height; w = h * a }
        return CGSize(width: max(w, 1), height: max(h, 1))
    }

    /// The live readout. Refuses to queue: one sample in flight at a time, because a mouse
    /// move fires far faster than a patch mean and the answer the user wants is the one
    /// under the cursor NOW.
    private func read(at displayPoint: CGPoint) async {
        guard !sampling else { return }
        sampling = true
        defer { sampling = false }
        let point = mapping.decodePoint(fromDisplay: displayPoint)
        let means = await model.renders.service.samplePatch(url: frame.url, at: point, radius: radius)
        guard hover != nil else { return }
        reading = means.flatMap { BaseResolver.ratios(fromRebate: $0) }
    }

    /// The click. Samples the same patch the square was drawn from, then hands the three
    /// means to the model, which owns the band, the undo group and the write.
    private func pick(at displayPoint: CGPoint) async {
        let point = mapping.decodePoint(fromDisplay: displayPoint)
        let targets = model.pickBaseTargets
        guard let means = await model.renders.service.samplePatch(url: frame.url, at: point,
                                                                 radius: radius) else {
            model.pickBaseNote = "That patch did not measure. Pick a spot on the film base, "
                + "away from the sprockets."
            return
        }
        model.applyPickedBase(means, to: targets)
    }
}

extension PickBaseNegative {
    /// The aspect of the picture on screen, which already has the quarter turn in it.
    /// Falls back to the stand-in before anything has loaded.
    var displayAspect: CGFloat {
        guard let pixels, pixels.height > 0 else { return CropBase.placeholderAspect }
        return pixels.width / pixels.height
    }
}
