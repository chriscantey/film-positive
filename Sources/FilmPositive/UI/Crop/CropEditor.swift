import Foundation
import CoreGraphics
import FilmSidecar
import FilmPositiveCore

/// What the crop box is locked to.
///
/// `original` is the default because an unlocked crop tool produces a different shape on
/// every frame of a roll. Freeform stays available because a frame with a damaged edge
/// sometimes has to be cut to something else.
enum CropAspect: Hashable, Identifiable, CaseIterable {
    case freeform
    case original
    case square
    case threeTwo
    case fourThree
    case fiveFour
    case sixteenNine

    var id: Self { self }

    var name: String {
        switch self {
        case .freeform: return "Freeform"
        case .original: return "Original"
        case .square: return "Square"
        case .threeTwo: return "3:2"
        case .fourThree: return "4:3"
        case .fiveFour: return "5:4"
        case .sixteenNine: return "16:9"
        }
    }

    /// The target ratio on screen, or nil for freeform. `original` follows the frame, which
    /// is why this takes it rather than hardcoding one.
    func targetAspect(original: CGFloat) -> CGFloat? {
        switch self {
        case .freeform: return nil
        case .original: return original
        case .square: return 1
        case .threeTwo: return 3.0 / 2
        case .fourThree: return 4.0 / 3
        case .fiveFour: return 5.0 / 4
        case .sixteenNine: return 16.0 / 9
        }
    }

    /// A portrait frame wants the portrait form of every landscape ratio, so the list
    /// follows the picture rather than making the user think about which way up it is.
    func targetAspect(original: CGFloat, portrait: Bool) -> CGFloat? {
        guard let a = targetAspect(original: original) else { return nil }
        if self == .original { return a }
        return portrait ? 1 / a : a
    }
}

/// The crop tool's whole state and arithmetic as a plain type: no SwiftUI, no app types,
/// so every claim about it can be tested directly. `ViewerView` owns one of these and does
/// nothing but draw it and feed it gestures.
///
/// Three normalized [0,1]² spaces, y-down, and the conversions between them are the whole
/// reason this type exists. The sidecar's apply order is straighten, crop, rotate, flip
/// (film-sidecar README, `Geometry.apply`), so reading that chain backwards:
///
/// - raw original: the decoded frame as it came off the camera. Nothing applied.
/// - straightened original: raw original turned clockwise by `degrees` about its center
///   keeping the frame's dimensions. This is the space `geometry.crop` is stored in, which
///   is what "original orientation, measured after straighten" means, and it is the space
///   `Straighten.apply` uses the crop box in.
/// - display: straightened original after the mirror and the quarter turn, which is the
///   picture the user is looking at and the space `CropBox` does its arithmetic in.
///
/// `Geometry.orient` mirrors x first and then turns clockwise (`DevelopTables.dstIndex`),
/// and its normalized mapping is exactly `QuarterTurn.displayPoint(fromOriginal:)`,
/// verified against that function in `CropEditorTests.testDisplayMappingMatchesDstIndex`.
struct CropEditor: Equatable {
    /// A detected edge lands where the picture stops, so a crop taken exactly there
    /// shaves a row of it: the seed is grown by this fraction of its own size.
    /// For `CropDetector`, whose box bounds the picture itself, so it is grown outward.
    static let seedMargin = 0.02
    /// Grip target as a fraction of the pane, used when the view does not pass its own.
    static let defaultTolerance = CGSize(width: 0.03, height: 0.03)
    /// Band outside each grip where a drag straightens instead of resizing.
    static let defaultRotateBand = CGSize(width: 0.06, height: 0.06)
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    // MARK: state

    /// Quarter turns clockwise, the sidecar's `rotate`.
    private(set) var turn: QuarterTurn
    /// Mirror horizontally, the sidecar's `flip`.
    private(set) var flip: Bool
    /// The sidecar's `straightenDegrees`, always inside `FineRotation.limitDegrees`.
    private(set) var degrees: Double
    /// The crop rectangle in DISPLAY space. Meaningful only when `hasCrop`.
    private(set) var displayRect: CGRect
    /// The ratio a drag is held to. Default `.original` so a roll comes out as a roll.
    var aspect: CropAspect = .original
    /// False means the frame is uncropped and the sidecar gets `crop: nil`.
    private(set) var hasCrop: Bool
    /// Width over height of the RAW ORIGINAL frame, which is the space straighten works
    /// in, so this is the aspect `FineRotation` needs.
    let originalAspect: CGFloat

    private(set) var session: Session?

    struct Session: Equatable {
        let zone: CropBox.Zone
        let startPoint: CGPoint
        let startRect: CGRect
        let startDegrees: Double
        let startHasCrop: Bool
    }

    // MARK: building

    init(geometry: GeometrySettings, originalAspect: CGFloat) {
        let turn = QuarterTurn(degrees: geometry.rotate) ?? .none
        self.turn = turn
        self.flip = geometry.flip
        self.degrees = FineRotation.clamped(geometry.straightenDegrees)
        self.originalAspect = max(originalAspect, 0.0001)
        if let c = geometry.crop {
            let original = CGRect(x: c.x, y: c.y, width: c.w, height: c.h)
            self.displayRect = CropBox.sanitised(Self.displayRect(fromOriginal: original, turn: turn, flip: geometry.flip))
            self.hasCrop = true
        } else {
            self.displayRect = Self.unit
            self.hasCrop = false
        }
    }

    /// What to write back. A negligible angle is stored as a true zero so an untouched
    /// frame stays bit-identical through the engine's copy-only path.
    var geometry: GeometrySettings {
        var crop: CropRect?
        if hasCrop {
            let r = Self.originalRect(fromDisplay: CropBox.sanitised(displayRect), turn: turn, flip: flip)
            crop = CropRect(x: Double(r.minX), y: Double(r.minY), w: Double(r.width), h: Double(r.height))
        }
        return GeometrySettings(rotate: turn.rawValue, flip: flip,
                                straightenDegrees: FineRotation.isNegligible(degrees) ? 0 : degrees,
                                crop: crop)
    }

    // MARK: space conversions

    private static func mirrored(_ r: CGRect) -> CGRect {
        CGRect(x: 1 - r.maxX, y: r.minY, width: r.width, height: r.height)
    }
    private static func mirrored(_ p: CGPoint) -> CGPoint { CGPoint(x: 1 - p.x, y: p.y) }

    /// Straightened original to display: mirror, then turn, the order `Geometry.orient` uses.
    static func displayRect(fromOriginal r: CGRect, turn: QuarterTurn, flip: Bool) -> CGRect {
        turn.displayRect(fromOriginal: flip ? mirrored(r) : r)
    }

    /// Display back to straightened original, the inverse: unturn, then mirror.
    static func originalRect(fromDisplay r: CGRect, turn: QuarterTurn, flip: Bool) -> CGRect {
        let t = turn.originalRect(fromDisplay: r)
        return flip ? mirrored(t) : t
    }

    static func displayPoint(fromOriginal p: CGPoint, turn: QuarterTurn, flip: Bool) -> CGPoint {
        turn.displayPoint(fromOriginal: flip ? mirrored(p) : p)
    }

    static func originalPoint(fromDisplay p: CGPoint, turn: QuarterTurn, flip: Bool) -> CGPoint {
        let t = turn.originalPoint(fromDisplay: p)
        return flip ? mirrored(t) : t
    }

    /// A display point down to the RAW original frame: undo the turn and the mirror, then
    /// undo the straighten. This is the inverse of everything the engine does to place a
    /// pixel, so it is what says which film a drawn rectangle actually covers.
    func rawOriginalPoint(fromDisplay p: CGPoint) -> CGPoint {
        FineRotation.unstraightened(Self.originalPoint(fromDisplay: p, turn: turn, flip: flip),
                                    byDegrees: degrees, aspect: originalAspect)
    }

    /// The other way: a point of the raw frame to where it appears on screen. The crop
    /// detector runs on the unstraightened proxy, so its rect arrives in raw space.
    func displayPoint(fromRawOriginal p: CGPoint) -> CGPoint {
        Self.displayPoint(fromOriginal: FineRotation.straightened(p, byDegrees: degrees, aspect: originalAspect),
                          turn: turn, flip: flip)
    }

    /// Bounding box of a raw-space rect on screen. Exact for a zero angle, the smallest
    /// enclosing box otherwise, because a turned rectangle is not a rectangle.
    func displayRect(fromRawOriginal r: CGRect) -> CGRect {
        Self.bounds(of: Self.corners(of: r).map { displayPoint(fromRawOriginal: $0) })
    }

    static func corners(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: seeding

    /// The detector's rect as the crop. The detector runs on the proxy the viewer is
    /// showing, which has the mirror and the quarter turn applied but NOT the straighten,
    /// so its rect arrives in display space measured on the unstraightened picture: undo
    /// the turn and the mirror to reach the raw frame, then go back up through the
    /// straighten to land in the space the crop is stored in. With a zero angle the whole
    /// round trip is the identity, which is the common case.
    ///
    /// Grown by `seedMargin` first (`CropBox.expanded`) because a detected edge lands
    /// where the picture stops, so a crop taken exactly there shaves a row of it.
    mutating func seed(_ detection: Detection) {
        seed(fromDetected: detection.rect, margin: detection.suggestedMargin)
    }

    /// A seeded box is held to the CURRENT ratio, which defaults to `.original`, so a
    /// detection matches what clicking the box would give, since a click applies the ratio.
    ///
    /// The detector measures four edges independently, so one bad edge moves one side and
    /// nothing else objects. The frame's own ratio is a fact about the film that no single
    /// edge can outvote, so applying it turns four independent measurements into three plus
    /// a constraint. The center anchor means a side that ran long is pulled in rather than
    /// the opposite side being pushed out, which is the direction that cannot eat the
    /// photograph.
    mutating func seed(fromDetected r: CGRect, margin: Double = CropEditor.seedMargin) {
        let raw = Self.originalRect(fromDisplay: r, turn: turn, flip: flip)
        let onScreen = displayRect(fromRawOriginal: raw)
        displayRect = CropBox.sanitised(CropBox.expanded(onScreen, byFraction: margin))
        displayRect = lock(displayRect, anchor: nil)
        hasCrop = true
    }

    /// What autocrop found, and which detector found it.
    struct Detection {
        typealias Route = AutoCrop.Route

        let route: Route

        /// Rotation the planner measured, degrees clockwise, zero on every other rung.
        ///
        /// Carried but NOT applied. Straighten is its own control, and pressing autocrop does
        /// not turn the picture. It is here so whoever wires it does not have to re-derive it.
        let angle: Double

        /// The format the planner built on, when it had one. Only meaningful on
        /// `plannerDetected`: on `plannerAnchored` it is the size we told it to expect, so
        /// reading it back would be learning our own assumption.
        let size: FilmSize?

        let rect: CGRect
        /// False when this came from the coarse fallback, so the caller can say so rather
        /// than presenting a rough box with the same confidence as a real frame edge.
        let isFrameEdge: Bool
        /// Sides where the film ran past what the camera could see, so the box is a useful
        /// crop but not a measurement of the frame.
        let unboundedEdges: Set<CropDetector.Edge>

        /// Every edge of the frame was found inside the picture, so the box is a measurement
        /// rather than only a useful crop.
        var isFullyBounded: Bool { unboundedEdges.isEmpty }

        /// How much to grow (positive) or shrink (negative) this box before using it as the
        /// crop seed. It belongs to the DETECTOR, not to the editor.
        ///
        /// `CropEditor.seedMargin` (+0.02) rests on a detected edge landing where the picture
        /// stops, so a crop taken exactly there shaves a row off it. True of `CropDetector`,
        /// which bounds everything that is not background. Wrong for `FrameFinder`, which
        /// walks outward until it meets UNEXPOSED FILM, so its box already sits on the rebate:
        /// growing it by two percent pushes a strip of clear film inside the crop.
        ///
        /// Accepted crops usually sit a little inside the film edge, but not in all cases. So
        /// the sign is negative here, and the magnitude is measured rather than picked.
        let suggestedMargin: Double
    }

    /// Autocrop. The rule itself is `AutoCrop.detect` in Core, so a headless render draws the
    /// same box the app takes. This wrapper only decides the seed margin, which is an editor
    /// concern: a measured frame edge is pulled in, a coarse box is grown out.
    /// - Parameter insetPercent: how far inside the found film edge to sit, a taste setting
    ///   (`Preferences.autoCropInset`). It applies to a MEASURED edge only. The coarse box
    ///   bounds everything that is not background, so it is already inside the picture and
    ///   grows outward by `seedMargin` instead: insetting it further would eat the photograph.
    static func detect(in frame: DecodedFrame, expecting: FilmSize? = nil,
                       insetPercent: Double = 1.0) -> Detection? {
        guard let r = AutoCrop.detect(in: frame, expecting: expecting) else { return nil }
        return Detection(route: r.route, angle: r.angle, size: r.size, rect: r.rect,
                         isFrameEdge: r.isFrameEdge, unboundedEdges: r.unboundedEdges,
                         suggestedMargin: r.route == .coarse ? seedMargin : -insetPercent / 100)
    }

    mutating func clearCrop() {
        displayRect = Self.unit
        hasCrop = false
    }

    // MARK: straighten

    /// The angle as it reads ON SCREEN, which is not the stored angle whenever the frame
    /// is mirrored.
    ///
    /// `degrees` is the sidecar's `straightenDegrees` and it lives in RAW space: the
    /// engine's chain is straighten, crop, rotate, flip (`Geometry.apply`), so a positive
    /// angle turns the picture clockwise BEFORE the mirror. A mirror reverses handedness,
    /// so after it the same angle leans counter-clockwise. A quarter turn does not reverse
    /// handedness and leaves the reading alone, which is why a test roll with `Flip` false
    /// can never show this.
    ///
    /// Scans that come through Film Tether with `Flip="True"` show it. The preview turns the
    /// DISPLAY image, which already has the mirror in it, so everything the user touches has
    /// to speak display degrees and everything that maps points has to keep speaking raw
    /// degrees.
    var displayDegrees: Double { flip ? -degrees : degrees }

    /// Set the angle the user is reading on screen. The slider, its label and the rotate
    /// band all come through here.
    mutating func setDisplayDegrees(_ d: Double) {
        setDegrees(flip ? -d : d)
    }

    mutating func setDegrees(_ d: Double) {
        degrees = FineRotation.clamped(d)
    }

    /// The rotate band and the slider both land here. The crop box stays where it is on
    /// screen while the picture turns underneath it, which is the familiar behavior and
    /// is also exactly right by construction: the box is defined in straightened space,
    /// and straightened space is defined by the angle, so an unchanged box on screen is
    /// an unchanged stored rect.
    mutating func nudgeDegrees(by delta: Double) { setDegrees(degrees + delta) }

    // MARK: quarter turns and flip

    /// A quarter turn moves the display space, so the rect on screen has to turn with it
    /// or the crop would jump to different film. The stored rect never changes.
    mutating func rotateClockwise() { reorient(turn: turn.next, flip: flip) }
    mutating func rotateCounterClockwise() { reorient(turn: turn.previous, flip: flip) }
    mutating func toggleFlip() { reorient(turn: turn, flip: !flip) }

    private mutating func reorient(turn newTurn: QuarterTurn, flip newFlip: Bool) {
        let original = Self.originalRect(fromDisplay: displayRect, turn: turn, flip: flip)
        // A mirror reverses handedness, so leaving the stored angle alone would make the
        // picture lean the other way the instant Flip is pressed: a horizon the user had
        // just levelled would come out tilted by twice the angle. Negating it holds
        // `displayDegrees` still, which is the thing they levelled by eye. The stored crop
        // is unaffected either way, because `geometry` converts the box through turn and
        // flip alone and never through the angle.
        if newFlip != flip { degrees = -degrees }
        turn = newTurn
        flip = newFlip
        displayRect = CropBox.sanitised(Self.displayRect(fromOriginal: original, turn: newTurn, flip: newFlip))
    }

    /// Width over height of the picture as displayed.
    var displayAspect: CGFloat { turn.displayAspect(originalAspect: originalAspect) }

    // MARK: gestures, all in display space

    /// `CropBox.zone`, limited to grips outside the picture.
    ///
    /// The pane's hit area reaches one grip target past the picture on every side, so a
    /// grip sitting on the picture's edge (every grip, with the crop at full frame) can be
    /// taken from either side of that edge. Out there a press may take a grip and nothing
    /// else: the rotate band stays inside the picture.
    static func zone(at p: CGPoint, in rect: CGRect, tolerance: CGSize, rotateBand: CGSize) -> CropBox.Zone {
        let z = CropBox.zone(at: p, in: rect, tolerance: tolerance, rotateBand: rotateBand)
        let onPicture = p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1
        if onPicture { return z }
        if case .resize = z { return z }
        return .none
    }

    /// Which zone a press lands in, and the start of a drag session.
    @discardableResult
    mutating func begin(at p: CGPoint, tolerance: CGSize = CropEditor.defaultTolerance,
                        rotateBand: CGSize = CropEditor.defaultRotateBand) -> CropBox.Zone {
        let z = Self.zone(at: p, in: displayRect, tolerance: tolerance, rotateBand: rotateBand)
        session = Session(zone: z, startPoint: p, startRect: displayRect, startDegrees: degrees, startHasCrop: hasCrop)
        return z
    }

    mutating func drag(to p: CGPoint) {
        guard let s = session else { return }
        let delta = CGSize(width: p.x - s.startPoint.x, height: p.y - s.startPoint.y)
        switch s.zone {
        case .resize(let handle):
            displayRect = lock(CropBox.dragged(s.startRect, handle: handle, by: delta), anchor: handle)
            hasCrop = true
        case .move:
            displayRect = CropBox.moved(s.startRect, by: delta)
            hasCrop = true
        case .rotate:
            let centre = CGPoint(x: s.startRect.midX, y: s.startRect.midY)
            let from = CropBox.angle(of: s.startPoint, about: centre, aspect: displayAspect)
            let to = CropBox.angle(of: p, about: centre, aspect: displayAspect)
            // The band is dragged on screen, so its delta is a DISPLAY angle. `flip`
            // cannot change inside a drag, so the start angle converts the same way.
            let startDisplay = flip ? -s.startDegrees : s.startDegrees
            setDisplayDegrees(startDisplay + Double(to - from))
        case .none:
            break
        }
    }

    /// True while a straightening drag is in progress: the grid overlay's fade is bound
    /// to this.
    var isStraightening: Bool {
        guard let s = session else { return false }
        if case .rotate = s.zone { return true }
        return false
    }

    var isDragging: Bool {
        guard let s = session else { return false }
        return s.zone != CropBox.Zone.none
    }

    mutating func end() { session = nil }

    /// Hold a rect to the current ratio. A no-op on freeform, which is the point of having
    /// freeform at all.
    private func lock(_ rect: CGRect, anchor: CropBox.Handle?) -> CGRect {
        guard let target = aspect.targetAspect(original: displayAspect, portrait: displayAspect < 1) else { return rect }
        return CropBox.constrained(rect, toAspect: target, canvasAspect: displayAspect, anchor: anchor)
    }

    /// Re-shape the current box to a newly chosen ratio, about its own center.
    mutating func setAspect(_ a: CropAspect) {
        aspect = a
        guard a != .freeform else { return }
        displayRect = lock(displayRect, anchor: nil)
        hasCrop = true
    }

    /// An arrow key. `pixels` is the pane's size in points so a keypress moves the same
    /// distance whatever the window is.
    mutating func nudge(_ handle: CropBox.Handle, byPixels pixels: CGVector, paneSize: CGSize) {
        guard paneSize.width > 0, paneSize.height > 0 else { return }
        displayRect = lock(CropBox.sanitised(CropBox.nudged(displayRect, handle: handle, byPixels: pixels, in: paneSize)),
                           anchor: handle)
        hasCrop = true
    }

    /// Center the box without changing its size.
    mutating func centre() {
        displayRect = CropBox.centered(displayRect)
        hasCrop = true
    }
}
