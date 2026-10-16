import SwiftUI
import AppKit

/// The two pieces of row chrome that more than one slider-shaped inspector row needs: the
/// readout's tap target and the focus wash.
///
/// They are shared rather than copied, so a change to the behavior and to the comment that
/// explains it happens in one file.

/// What a click on a slider row means, shared by the enhance rows and the color axis rows.
///
/// A SINGLE click anywhere in the row only moves the slider, the readout included, so a click
/// on the number never opens a field by accident. A DOUBLE click on the readout opens the field
/// to type a value, and a double click anywhere else in the row resets it to 0. The first click
/// of a double click on the readout has already moved the slider by then, so the value from
/// before that first press is put back and the field opens on it.
///
/// No gesture sits on the readout. A grouped `Form` plus `LabeledContent` kills a tap on a
/// child (a 2x2 with the click held constant isolates exactly that pair), and a
/// `highPriorityGesture` does not help, because the tap never enters the gesture arena there.
/// So the double click rides on the ROW, as the reset does, and tells readout from track by
/// where it landed.
struct RowClicks {
    /// The value when the first press of the current click run began.
    private(set) var valueBeforeClicks: Double?
    private var lastPress = Date.distantPast

    /// Called at the start of every press on the track, before the press moves the value.
    mutating func pressed(at value: Double) {
        let now = Date()
        if now.timeIntervalSince(lastPress) > NSEvent.doubleClickInterval { valueBeforeClicks = value }
        lastPress = now
    }

    /// Whether a double click at `x` in a row `width` wide landed on a readout `readout` wide
    /// at the trailing edge.
    static func onReadout(_ x: CGFloat, width: CGFloat, readout: CGFloat) -> Bool {
        width > 0 && x >= width - readout
    }
}

/// Reads a view's width into a binding, for the row's click zones.
struct WidthReader: ViewModifier {
    @Binding var width: CGFloat

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { g in
                Color.clear
                    .onAppear { width = g.size.width }
                    .onChange(of: g.size.width) { _, w in width = w }
            }
        }
    }
}

/// The background a row wears while its control has keyboard focus.
///
/// It replaces the system focus ring. It is the whole row, icon and label and track and
/// readout together, and a background rather than an outline.
///
/// DELIBERATELY NOT THE ACCENT COLOR. With Pink as both the accent AND the highlight color,
/// a pink ring, a pink fill and a pink selection are indistinguishable. A neutral wash off
/// `primary` inherits the text color, so it inverts correctly between light and dark without
/// naming either.
///
/// Subtle on purpose, but a 0.06 fill is invisible: on screen the focused row cannot be told
/// from its neighbors. The border carries most of the legibility, so the fill can stay quiet.
struct RowFocusWash: ViewModifier {
    let isFocused: Bool

    static let fill = 0.10
    static let edge = 0.14

    func body(content: Content) -> some View {
        content
            // Inset negatively so the wash covers the Form's own row padding rather than
            // floating inside it, the row and not a panel within the row.
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isFocused ? Self.fill : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(isFocused ? Self.edge : 0),
                                          lineWidth: 1)
                    }
                    .padding(.horizontal, -8)
                    .padding(.vertical, -4)
                    .animation(.easeOut(duration: 0.12), value: isFocused)
            }
    }
}

/// Tells a row when the mouse goes down anywhere outside it.
///
/// A background NSView rather than a SwiftUI gesture, because the question is about clicks
/// that land on OTHER views, which no gesture on this row ever sees. A local event monitor
/// sees every mouse down in the app before it is dispatched, and the view converts the point
/// into its own bounds, so there is no coordinate space for SwiftUI and AppKit to disagree
/// about. The view never takes a hit itself.
///
/// Installed only while `isActive`, and removed when the row goes away.
struct ClickAwayMonitor: NSViewRepresentable {
    let isActive: Bool
    let onClickAway: () -> Void

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.onClickAway = onClickAway
        view.setActive(isActive)
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.setActive(false) }

    final class Probe: NSView {
        var onClickAway: () -> Void = {}
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func setActive(_ on: Bool) {
            if on, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
                ) { [weak self] event in
                    self?.check(event)
                    return event
                }
            } else if !on, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        private func check(_ event: NSEvent) {
            if let w = window, event.window === w,
               bounds.contains(convert(event.locationInWindow, from: nil)) { return }
            // After the click has been dispatched, so a press on another row lands first.
            DispatchQueue.main.async { [weak self] in self?.onClickAway() }
        }
    }
}
