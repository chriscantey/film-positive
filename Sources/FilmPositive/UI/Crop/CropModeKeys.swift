import SwiftUI
import AppKit
import FilmSidecar
import FilmPositiveCore

/// Return and Escape while the crop rectangle is up.
///
/// Return keeps the crop and puts the rectangle away, Escape puts the frame's geometry back
/// as it was when the rectangle came up on it, straighten angle included, and puts the
/// rectangle away. Both stay in the closeup. Escape with the rectangle down goes back to the
/// roll.
///
/// Every crop gesture already commits as it ends, one undo step each, so Return has nothing
/// to write. Escape writes ONE step, "Cancel Crop", that Undo takes back.
///
/// ONE FRAME, NOT THE PASS. The rectangle stays up while the arrows walk the roll, so a crop
/// session can span a whole roll. Escape restores the frame ON SCREEN only, from when the
/// rectangle came up on THAT frame. Throwing away a whole roll's crops on one keypress would
/// be the worst reading of "cancel", and each earlier frame's crops are still one Undo each.
enum CropModeKeys {
    enum Action: Equatable { case keep, cancel }

    /// What a key does in the closeup with the rectangle up, or nil when it is not ours.
    /// Nothing while a drag is in flight: the drag owns the geometry until it ends.
    static func action(for key: KeyEquivalent, showsCrop: Bool, dragging: Bool) -> Action? {
        guard showsCrop, !dragging else { return nil }
        switch key {
        case .return: return .keep
        case .escape: return .cancel
        default: return nil
        }
    }

    /// The frame's geometry when the rectangle came up on it.
    struct Entry: Equatable {
        let frameID: Frame.ID
        let geometry: GeometrySettings

        init(frameID: Frame.ID, geometry: GeometrySettings?) {
            self.frameID = frameID
            self.geometry = geometry ?? GeometrySettings()
        }

        /// What Escape writes back to `frameID`, or nil when nothing changed since entry, so a
        /// look at a frame that was never touched costs no undo step. A missing geometry and
        /// an identity one are the same thing on disk (`SidecarEdits.setGeometry`).
        func restoring(_ current: GeometrySettings?, on shown: Frame.ID) -> GeometrySettings? {
            guard shown == frameID else { return nil }
            return (current ?? GeometrySettings()) == geometry ? nil : geometry
        }
    }

    /// A typed straighten angle. Takes what the readout shows, so "1.50°" parses, and a comma
    /// for the decimal point. Nil for anything that is not a finite number. The range is the
    /// editor's to enforce: `CropEditor.setDegrees` clamps to `FineRotation.limitDegrees`.
    static func parseDegrees(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "\u{00B0}", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let d = Double(cleaned), d.isFinite else { return nil }
        return d
    }
}

/// Tells a control about a double click on it, for controls that are AppKit underneath.
///
/// The straighten slider is a system `Slider`, which is an `NSSlider` running its own mouse
/// tracking loop, so a SwiftUI tap gesture on it never sees the click. A local monitor sees
/// every mouse down before it is dispatched, and a background view converts the point into
/// its own bounds, the same shape as `ClickAwayMonitor`. The event is passed on untouched, so
/// the slider still gets it, and the callback runs after the click has been handled.
struct DoubleClickMonitor: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.onDoubleClick = onDoubleClick
        view.install()
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.remove() }

    final class Probe: NSView {
        var onDoubleClick: () -> Void = {}
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                self?.check(event)
                return event
            }
        }

        func remove() {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
        }

        private func check(_ event: NSEvent) {
            guard event.clickCount == 2, let w = window, event.window === w,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            // After the slider's own tracking of this click, so the reset lands last.
            DispatchQueue.main.async { [weak self] in self?.onDoubleClick() }
        }
    }
}

/// Catches Escape for a text field before anything else sees it.
///
/// Without it, Escape with a value typed into the straighten angle field COMMITS the value.
/// A local monitor sees the key before dispatch, so the field is closed as abandoned before
/// anything else moves, and the event is swallowed, so the closeup does not also read it as
/// Escape for the crop. The other half is in the field's text binding
/// (`CropControlBar.degreesReadout`).
struct EscapeKeyMonitor: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.onEscape = onEscape
        view.install()
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.remove() }

    final class Probe: NSView {
        var onEscape: () -> Void = {}
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self, event.keyCode == 53, event.window === self.window else { return event }
                self.onEscape()
                return nil
            }
        }

        func remove() {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
        }
    }
}
