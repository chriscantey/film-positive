import Foundation
import CoreGraphics

/// Straightening arithmetic, ported from Film Tether's `FineRotation`, which began as Alex
/// Teslik's contribution there. The two apps share the sidecar's
/// `Film:StraightenDeg`, so they must agree on what an angle means: **positive degrees
/// turn the picture clockwise on screen**, about the frame's center, in a space where
/// one unit is the same distance on both axes.
///
/// This type carries no pixels. `Straighten` does the resample; this is the point
/// mapping every overlay and every test needs to keep pointing at the same film after the
/// picture has been turned.
public enum FineRotation {
    /// Angles smaller than this are treated as none.
    public static let negligibleDegrees = 0.01

    /// Largest straightening the crop tool applies; beyond it the operator wants a
    /// quarter turn.
    public static let limitDegrees = 45.0

    public static func isNegligible(_ degrees: Double) -> Bool { abs(degrees) < negligibleDegrees }

    public static func clamped(_ degrees: Double) -> Double { min(max(degrees, -limitDegrees), limitDegrees) }

    /// Where a normalized point of the un-straightened frame ends up once the frame has
    /// been straightened by `degrees`. `aspect` is width over height.
    public static func straightened(_ p: CGPoint, byDegrees degrees: Double, aspect: CGFloat) -> CGPoint {
        rotate(p, byDegrees: degrees, aspect: aspect)
    }

    /// Inverse of `straightened`: a point on the straightened picture back to the pixel of
    /// the original frame.
    public static func unstraightened(_ p: CGPoint, byDegrees degrees: Double, aspect: CGFloat) -> CGPoint {
        rotate(p, byDegrees: -degrees, aspect: aspect)
    }

    private static func rotate(_ p: CGPoint, byDegrees degrees: Double, aspect: CGFloat) -> CGPoint {
        guard !isNegligible(degrees) else { return p }
        let a = max(aspect, 0.0001)
        let t = CGFloat(degrees) * .pi / 180
        let c = cos(t), s = sin(t)
        let x = (p.x - 0.5) * a
        let y = p.y - 0.5
        return CGPoint(x: (x * c - y * s) / a + 0.5, y: (x * s + y * c) + 0.5)
    }
}
