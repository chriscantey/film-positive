import Foundation
import CoreGraphics

/// Quarter turns and their point mappings, the pure part of Film Tether's
/// `PreviewRotation` (its bitmap rotation stays in Tether; ours is `Geometry.orient`).
/// The sidecar's `Film:Rotate` is Tether's `PreviewRotation` in clockwise degrees, so
/// the two mappings must agree exactly: a quarter turn is the only rotation that carries
/// an axis-aligned rectangle to another one, which is what lets the crop be stored in
/// original space while being edited as a plain rectangle on screen.
public enum QuarterTurn: Int, CaseIterable, Sendable {
    case none = 0
    case cw90 = 90
    case cw180 = 180
    case cw270 = 270

    public init?(degrees: Int) { self.init(rawValue: ((degrees % 360) + 360) % 360) }

    public var next: QuarterTurn {
        switch self { case .none: return .cw90; case .cw90: return .cw180; case .cw180: return .cw270; case .cw270: return .none }
    }
    public var previous: QuarterTurn {
        switch self { case .none: return .cw270; case .cw90: return .none; case .cw180: return .cw90; case .cw270: return .cw180 }
    }
    public var swapsAxes: Bool { self == .cw90 || self == .cw270 }

    public func displayAspect(originalAspect: CGFloat) -> CGFloat { swapsAxes ? 1 / originalAspect : originalAspect }

    /// A point in unrotated original space to where it appears in the displayed frame.
    public func displayPoint(fromOriginal p: CGPoint) -> CGPoint {
        switch self {
        case .none: return p
        case .cw90: return CGPoint(x: 1 - p.y, y: p.x)
        case .cw180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case .cw270: return CGPoint(x: p.y, y: 1 - p.x)
        }
    }

    public func originalPoint(fromDisplay p: CGPoint) -> CGPoint {
        switch self {
        case .none: return p
        case .cw90: return CGPoint(x: p.y, y: 1 - p.x)
        case .cw180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case .cw270: return CGPoint(x: 1 - p.y, y: p.x)
        }
    }

    public func displayRect(fromOriginal r: CGRect) -> CGRect {
        Self.rect(from: displayPoint(fromOriginal: CGPoint(x: r.minX, y: r.minY)),
                  to: displayPoint(fromOriginal: CGPoint(x: r.maxX, y: r.maxY)))
    }

    public func originalRect(fromDisplay r: CGRect) -> CGRect {
        Self.rect(from: originalPoint(fromDisplay: CGPoint(x: r.minX, y: r.minY)),
                  to: originalPoint(fromDisplay: CGPoint(x: r.maxX, y: r.maxY)))
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).standardized
    }
}
