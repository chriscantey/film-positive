import AppKit

/// Two fingers on a trackpad pan the zoomed closeup.
///
/// A two finger swipe is a scroll wheel event, not a gesture SwiftUI hands the closeup, and
/// the closeup is not a scroll view, so nothing else receives it. A local monitor catches it
/// while the closeup is up and feeds the same `pan(by:)` the drag uses, so the clamp is the
/// same.
/// It only takes the event when the pan is wanted (zoomed, pointer over the picture), and
/// hands everything else on untouched, so a scroll anywhere else still scrolls.
@MainActor
final class ScrollPan {
    private var monitor: Any?

    /// `pan` returns whether it used the event. False lets the event through.
    func install(_ pan: @escaping (CGSize) -> Bool) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // A sheet over the closeup (Export) owns its own scrolling.
            if event.window?.attachedSheet != nil { return event }
            let d = Self.delta(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                               precise: event.hasPreciseScrollingDeltas)
            return pan(d) ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Points a mouse wheel's one line moves the picture. A trackpad reports points already.
    nonisolated static let lineStep: CGFloat = 12

    /// The picture's move for one scroll event, in points, the same sign convention as a
    /// drag's translation: the picture follows the fingers. `scrollingDelta` already carries
    /// the user's natural scrolling choice, so it is not flipped here. Pure so it is testable.
    nonisolated static func delta(dx: CGFloat, dy: CGFloat, precise: Bool) -> CGSize {
        let k: CGFloat = precise ? 1 : lineStep
        return CGSize(width: dx * k, height: dy * k)
    }
}
