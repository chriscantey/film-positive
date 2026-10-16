import CoreGraphics
import Foundation

/// Zoom and pan in the closeup: ⌘+ and ⌘− to zoom, drag to pan.
///
/// A value, so every rule here is testable without a window. The view reports the
/// `Layout` it measured, the menu and the gestures call the mutating methods, and the view
/// draws `displaySize` at `offset`. The pointer is NOT in here: it moves on every mouse
/// move, and anything the closeup's body reads must not change that often. The model keeps
/// it beside this, unobserved, and passes it in as the anchor.
///
/// SCALE IS SCREEN PIXELS PER IMAGE PIXEL, and an image pixel is a pixel of the full
/// resolution frame, not of the half size proxy the closeup normally draws. So 1.0 is the
/// slider's right end ("100 percent", one image pixel on one screen pixel), and it means
/// the same thing on a Retina screen and on a 1x one. Past
/// `proxyDensity` the proxy is being enlarged, which is where the view asks for a full
/// render.
///
/// Nil scale is FIT, not a number that happens to equal the fit scale. A window resize at
/// fit stays at fit, which a stored number would not.
struct CloseupZoom: Equatable {
    struct Layout: Equatable {
        /// The picture's box in points, inside the closeup's padding: exactly the box the
        /// fitted picture is drawn into, so fit here and `scaledToFit` there agree.
        var viewport: CGSize
        /// The frame at full resolution, in pixels.
        var imagePixels: CGSize
        /// Screen pixels per point (2 on a Retina display, 1 on a 1x one).
        var backingScale: CGFloat
    }

    /// Where ⌘+ and ⌘− step, the same kind of ladder Preview uses. Fit is always the
    /// bottom rung, wherever it falls between these.
    static let stops: [CGFloat] = [0.125, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4]
    static let maxScale: CGFloat = 4
    /// The closeup's picture is a LibRaw half size decode, so it carries one pixel for
    /// every two of the frame's along each side.
    static let proxyDensity: CGFloat = 0.5
    /// Within this much of either end the slider snaps onto it, which is the detent.
    static let sliderDetent: Double = 0.04

    /// Nil is fit.
    private(set) var scale: CGFloat?
    /// The image point at the middle of the viewport, as fractions of the image's width
    /// and height. (0.5, 0.5) is centered.
    private(set) var centre = CGPoint(x: 0.5, y: 0.5)
    private(set) var layout: Layout?

    var isFit: Bool { scale == nil }

    // MARK: reading

    /// The scale at which the whole frame fits the viewport.
    func fitScale(_ l: Layout) -> CGFloat {
        guard l.imagePixels.width > 0, l.imagePixels.height > 0 else { return 1 }
        return min(l.viewport.width / l.imagePixels.width, l.viewport.height / l.imagePixels.height) * l.backingScale
    }

    /// The scale in force, fit resolved to its number. Nil without a layout.
    var effectiveScale: CGFloat? {
        guard let layout else { return nil }
        return scale ?? fitScale(layout)
    }

    /// The picture's size in points at the current scale.
    var displaySize: CGSize? {
        guard let layout, let s = effectiveScale else { return nil }
        return Self.displaySize(layout, s)
    }

    /// How far the picture's middle sits from the viewport's middle, in points. Zero at fit.
    var offset: CGSize {
        guard let d = displaySize else { return .zero }
        return CGSize(width: (0.5 - centre.x) * d.width, height: (0.5 - centre.y) * d.height)
    }

    /// Whether the picture on screen is the proxy made larger than it is, which is when a
    /// full render is worth asking for. A hair of slack so the fit scale on a large display
    /// does not trip it.
    var needsDetail: Bool {
        guard scale != nil, let s = effectiveScale else { return false }
        return s > Self.proxyDensity * 1.02
    }

    /// Whether the keys can zoom in any further.
    var canZoomIn: Bool {
        guard let layout, let s = effectiveScale else { return false }
        return s < Self.ceiling(layout, fit: fitScale(layout)) * 0.999
    }

    var canZoomOut: Bool { layout != nil && scale != nil }

    /// Where the corner slider sits, 0 at fit and 1 at 100 percent, on a log scale so each
    /// equal step is an equal ratio. Past 100 percent it rests at the right end.
    var sliderValue: Double {
        guard let layout, let s = effectiveScale else { return 0 }
        let fit = fitScale(layout)
        guard fit < 1 else { return 0 }
        return min(max(Double(log(s / fit) / log(1 / fit)), 0), 1)
    }

    /// The slider does nothing when the frame already fits at 100 percent or larger.
    var sliderEnabled: Bool {
        guard let layout else { return false }
        return fitScale(layout) < 1
    }

    // MARK: changing

    /// A new measurement from the view: a resize, a new frame's size, a move to another
    /// display. Keeps the scale and re-clamps the pan, and drops back to fit when the
    /// window has grown past the scale that was set.
    mutating func update(layout new: Layout) {
        guard new != layout else { return }
        layout = new
        if let s = scale, s <= fitScale(new) * 1.001 { reset(); return }
        clamp()
    }

    /// Back to fit, centered. A frame step does this, and so does ⌘0.
    mutating func reset() {
        scale = nil
        centre = CGPoint(x: 0.5, y: 0.5)
    }

    /// Nothing zoomable on screen: the negative, the crop rectangle, the eyedropper, or the
    /// closeup gone. Back to fit, and the menu items grey out.
    mutating func forgetLayout() {
        reset()
        layout = nil
    }

    /// The next rung up, around `anchor` (the pointer, in viewport points from the top
    /// left), or around the middle when the pointer is not over the picture.
    mutating func zoomIn(around anchor: CGPoint?) {
        guard let layout, let s = effectiveScale else { return }
        let fit = fitScale(layout)
        let next = Self.stops.first { $0 > s * 1.01 && $0 > fit * 1.01 } ?? Self.ceiling(layout, fit: fit)
        set(scale: next, anchor: anchor)
    }

    /// The next rung down, the same way. Below the fit scale is fit.
    mutating func zoomOut(around anchor: CGPoint?) {
        guard let layout, let s = effectiveScale else { return }
        let fit = fitScale(layout)
        let next = Self.stops.last { $0 < s / 1.01 } ?? fit
        set(scale: max(next, fit), anchor: anchor)
    }

    /// View > Actual Size: one image pixel on one screen pixel, around `anchor`. A
    /// frame that already fits at 100 percent or larger stays at fit, which `set` does.
    mutating func actualSize(around anchor: CGPoint?) { set(scale: 1, anchor: anchor) }

    /// Whether Actual Size would change anything.
    var canShowActualSize: Bool {
        guard let layout, let s = effectiveScale else { return false }
        return fitScale(layout) < 1 && abs(s - 1) > 0.001
    }

    /// The corner slider moved. Snaps onto either end within the detent, and zooms around
    /// the middle of the picture, since the pointer is on the slider.
    mutating func setSlider(_ t: Double) {
        guard let layout else { return }
        let fit = fitScale(layout)
        guard fit < 1 else { return }
        if t <= Self.sliderDetent { reset(); return }
        let snapped = t >= 1 - Self.sliderDetent ? 1 : t
        set(scale: fit * pow(1 / fit, CGFloat(snapped)), anchor: nil)
    }

    /// Any scale, held to fit at the bottom and the ceiling at the top, keeping the image
    /// point under `anchor` where it is. The anchor is in viewport points from the top
    /// left, nil for the middle. What the keys, the slider and the pinch all come through.
    mutating func set(scale wanted: CGFloat, anchor: CGPoint?) {
        guard let layout, let before = effectiveScale else { return }
        let fit = fitScale(layout)
        let target = min(wanted, Self.ceiling(layout, fit: fit))
        if target <= fit * 1.001 { reset(); return }
        // The anchor as an offset from the viewport's middle, then the image point under
        // it now, then the center that puts that same image point under it at the new size.
        let a = anchor ?? CGPoint(x: layout.viewport.width / 2, y: layout.viewport.height / 2)
        let p = CGPoint(x: a.x - layout.viewport.width / 2, y: a.y - layout.viewport.height / 2)
        let d0 = Self.displaySize(layout, before)
        let d1 = Self.displaySize(layout, target)
        let u = CGPoint(x: centre.x + p.x / d0.width, y: centre.y + p.y / d0.height)
        centre = CGPoint(x: u.x - p.x / d1.width, y: u.y - p.y / d1.height)
        scale = target
        clamp()
    }

    /// A drag moved by `translation` points since the last call. The picture follows the
    /// pointer, so the center moves the other way. Nothing at fit.
    mutating func pan(by translation: CGSize) {
        guard scale != nil, let d = displaySize else { return }
        centre.x -= translation.width / d.width
        centre.y -= translation.height / d.height
        clamp()
    }

    // MARK: rules

    /// The top of the ladder: 400 percent, or fit when a small frame already fits larger.
    private static func ceiling(_ l: Layout, fit: CGFloat) -> CGFloat { max(maxScale, fit) }

    private static func displaySize(_ l: Layout, _ s: CGFloat) -> CGSize {
        CGSize(width: l.imagePixels.width * s / l.backingScale, height: l.imagePixels.height * s / l.backingScale)
    }

    /// No empty band inside the viewport while the picture is larger than it: each edge
    /// stops at the viewport's edge. Along a side where the picture is the smaller, it is
    /// centered on that side.
    private mutating func clamp() {
        guard let layout, let d = displaySize else { return }
        centre.x = Self.clampAxis(centre.x, view: layout.viewport.width, shown: d.width)
        centre.y = Self.clampAxis(centre.y, view: layout.viewport.height, shown: d.height)
    }

    private static func clampAxis(_ c: CGFloat, view: CGFloat, shown: CGFloat) -> CGFloat {
        guard shown > view, shown > 0 else { return 0.5 }
        let half = view / (2 * shown)
        return min(max(c, half), 1 - half)
    }
}
