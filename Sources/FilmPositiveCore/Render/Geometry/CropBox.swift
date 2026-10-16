import Foundation
import CoreGraphics

/// An adjustable crop rectangle: which handle a click lands on, and what dragging it
/// does. Ported as-is from Film Tether's `CropBox`, which Alex Teslik contributed there:
/// pure arithmetic about corners, which is where crop editors go wrong in ways that are
/// tedious to find by hand.
///
/// Everything is normalized [0,1]², y-down, in the space the box is displayed in. The
/// caller converts to and from original-frame space around the edit.
public enum CropBox {
    public enum Handle: String, CaseIterable, Sendable {
        case topLeft, top, topRight
        case left, right
        case bottomLeft, bottom, bottomRight
        case interior

        var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    }

    /// Smallest the box may become, normalized.
    public static let minSize = 0.03

    public static func handlePositions(in rect: CGRect) -> [(Handle, CGPoint)] {
        [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.top, CGPoint(x: rect.midX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.left, CGPoint(x: rect.minX, y: rect.midY)),
            (.right, CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottom, CGPoint(x: rect.midX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
    }

    /// Which grip `point` is on, `.interior` inside the box, nil outside. Corners are
    /// tested before edges because their targets overlap.
    public static func handle(at point: CGPoint, in rect: CGRect, tolerance: CGSize) -> Handle? {
        let corners: [Handle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let positions = handlePositions(in: rect)
        for handle in corners {
            guard let p = positions.first(where: { $0.0 == handle })?.1 else { continue }
            if abs(point.x - p.x) <= tolerance.width, abs(point.y - p.y) <= tolerance.height { return handle }
        }
        for (handle, p) in positions where !corners.contains(handle) {
            if abs(point.x - p.x) <= tolerance.width, abs(point.y - p.y) <= tolerance.height { return handle }
        }
        return rect.insetBy(dx: -tolerance.width, dy: -tolerance.height).contains(point) ? .interior : nil
    }

    public enum Zone: Equatable, Sendable {
        case resize(Handle)
        /// Just outside a grip: a drag straightens the picture underneath.
        case rotate(Handle)
        case move
        case none
    }

    /// The rotate zone is a band outside each grip, so resizing and straightening never
    /// compete for the same pixel.
    public static func zone(at point: CGPoint, in rect: CGRect, tolerance: CGSize, rotateBand: CGSize) -> Zone {
        if let handle = handle(at: point, in: rect, tolerance: tolerance), handle != .interior { return .resize(handle) }
        if !rect.contains(point) {
            let outer = CGSize(width: tolerance.width + rotateBand.width, height: tolerance.height + rotateBand.height)
            if let handle = handle(at: point, in: rect, tolerance: outer), handle != .interior { return .rotate(handle) }
        }
        return rect.contains(point) ? .move : .none
    }

    /// Angle in degrees from `centre` to `point`, clockwise from up, aspect-corrected so a
    /// straightening drag tracks the pointer on a wide pane.
    public static func angle(of point: CGPoint, about centre: CGPoint, aspect: CGFloat) -> CGFloat {
        let dx = (point.x - centre.x) * max(aspect, 0.0001)
        let dy = point.y - centre.y
        guard dx != 0 || dy != 0 else { return 0 }
        return atan2(dx, -dy) * 180 / .pi
    }

    /// Apply a drag. The result stays inside the unit square and no smaller than `minSize`;
    /// a corner dragged across the box stops rather than inverting it.
    public static func dragged(_ rect: CGRect, handle: Handle, by delta: CGSize) -> CGRect {
        guard handle != .interior else { return moved(rect, by: delta) }
        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY
        if handle.movesLeft { minX += delta.width }
        if handle.movesRight { maxX += delta.width }
        if handle.movesTop { minY += delta.height }
        if handle.movesBottom { maxY += delta.height }
        if handle.movesLeft { minX = min(max(minX, 0), maxX - minSize) }
        if handle.movesRight { maxX = max(min(maxX, 1), minX + minSize) }
        if handle.movesTop { minY = min(max(minY, 0), maxY - minSize) }
        if handle.movesBottom { maxY = max(min(maxY, 1), minY + minSize) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public static func moved(_ rect: CGRect, by delta: CGSize) -> CGRect {
        let w = min(rect.width, 1), h = min(rect.height, 1)
        let x = min(max(rect.minX + delta.width, 0), 1 - w)
        let y = min(max(rect.minY + delta.height, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    public static func centered(_ rect: CGRect) -> CGRect {
        let w = min(rect.width, 1), h = min(rect.height, 1)
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    public static func nudged(_ rect: CGRect, handle: Handle, byPixels pixels: CGVector, in frame: CGSize) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return rect }
        return dragged(rect, handle: handle, by: CGSize(width: pixels.dx / frame.width, height: pixels.dy / frame.height))
    }

    /// Grow a rect by a fraction of its own size, evenly on all sides: a detected edge
    /// lands where the picture stops, and a crop taken exactly there shaves a row of it.
    public static func expanded(_ rect: CGRect, byFraction f: Double) -> CGRect {
        guard f != 0, rect.width > 0, rect.height > 0 else { return rect }
        return rect.insetBy(dx: -rect.width * f / 2, dy: -rect.height * f / 2)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Bring a rect back inside the frame and up to the minimum size.
    public static func sanitised(_ rect: CGRect) -> CGRect {
        let w = min(max(rect.width, minSize), 1)
        let h = min(max(rect.height, minSize), 1)
        let x = min(max(rect.minX, 0), 1 - w)
        let y = min(max(rect.minY, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

public extension CropBox {
    /// Reshape a normalized crop rect to a target ON-SCREEN aspect ratio, holding the
    /// handle's opposite corner still.
    ///
    /// The conversion is the part that is easy to get wrong. `rect` is normalized 0 to 1 on
    /// a canvas that is not square, so a rect with equal width and height is NOT a square on
    /// screen. A normalized rect of (w, h) on a canvas of aspect `canvasAspect` shows as
    /// `w * canvasAspect / h`, so the target height for a given width is
    /// `w * canvasAspect / targetAspect`. Skipping that step produces a lock that is exactly
    /// right on a square image and silently wrong on every real frame.
    ///
    /// Shrinks rather than grows: whichever dimension has to change moves inward, so a
    /// locked drag can never push the box outside the picture and then get clamped into a
    /// shape that is no longer the ratio it claims.
    static func constrained(_ rect: CGRect, toAspect targetAspect: CGFloat,
                            canvasAspect: CGFloat, anchor: Handle?) -> CGRect {
        guard targetAspect > 0, canvasAspect > 0, rect.width > 0, rect.height > 0 else { return rect }
        let wantedHeight = rect.width * canvasAspect / targetAspect
        var out = rect
        if wantedHeight <= rect.height {
            out.size.height = wantedHeight
        } else {
            out.size.width = rect.height * targetAspect / canvasAspect
        }
        // Keep the corner the user is NOT dragging where it was, so the box grows and
        // shrinks from the fixed corner the way every crop tool does.
        switch anchor {
        case .topLeft:     out.origin = CGPoint(x: rect.maxX - out.width, y: rect.maxY - out.height)
        case .topRight:    out.origin = CGPoint(x: rect.minX, y: rect.maxY - out.height)
        case .bottomLeft:  out.origin = CGPoint(x: rect.maxX - out.width, y: rect.minY)
        case .bottomRight: out.origin = CGPoint(x: rect.minX, y: rect.minY)
        default:
            out.origin = CGPoint(x: rect.midX - out.width / 2, y: rect.midY - out.height / 2)
        }
        return sanitised(out)
    }
}
