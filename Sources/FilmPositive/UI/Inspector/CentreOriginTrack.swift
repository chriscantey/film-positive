import SwiftUI
import AppKit

/// A flat track whose fill grows from a neutral point, with NO thumb.
///
/// `Slider(neutralValue:)` is not it. That parameter moves where the fill originates and keeps
/// SwiftUI's circular thumb, and it needs `#available(macOS 26)`, so a thumbless track on the
/// macOS 14 minimum needs a real control.
///
/// The interaction surface is deliberately larger than the ink. The drawn track is
/// `trackHeight` tall and the row accepts a press anywhere in `hitHeight`, because a 4 pt
/// target is not a target.
struct CentreOriginTrack: View {
    @Binding var value: Double
    /// The range the track currently SPANS, which is not fixed: typing an out-of-range number
    /// into the readout widens it and the track rescales to fit. See `EnhanceSliderRow`.
    let range: ClosedRange<Double>
    /// Where the fill grows from. Zero for every enhance control, but named rather than
    /// assumed so the control is not secretly about this one panel.
    let neutral: Double
    let isEnabled: Bool
    /// True while a drag is in flight, so the coordinator can render at preview scale.
    let onEditingChanged: (Bool) -> Void
    /// Called when Escape gives the keyboard up, so the caller can hand it somewhere useful.
    let onReleaseFocus: () -> Void

    /// One arrow key press, in this control's own unit.
    ///
    /// The unit is not a detail of the widget. An enhance slider is a dimensionless -1...1 and
    /// steps 0.01, one unit of the readout's two decimals. A color axis is measured in printer
    /// points, a real unit a lab quotes, and its natural quantum is one whole point. A shared
    /// 0.01 would make an arrow press on a point-valued control mean a hundredth of the
    /// smallest thing anybody names.
    ///
    /// Defaults to the enhance step.
    var keyStep: Double = CentreOriginTrack.defaultKeyStep

    /// How the track is DRAWN. Input handling is identical in both, which is the point of
    /// keeping one control: every drag, key and accessibility rule above and below applies
    /// to either look unchanged.
    enum Look: Equatable {
        /// The thin 4 pt bar with a fill, as the color axis rows draw it.
        case line
        /// The enhance rows. One rounded box the height of the row, filled from the center
        /// toward the value at the full box height, with a brighter edge at the value end.
        /// `ticks` are faint marks at values the caller wants shown, the normal limits while a
        /// grown range is held. No center line.
        case capsule(ticks: [Double])
    }
    var look: Look = .line

    /// How the capsule draws a `tick`, the normal limit of a grown span: with a typed 1.50 the
    /// track spans -2...2 and the ticks stand at -1 and 1, where the ends of the track were
    /// before it grew.
    enum LimitMark: CaseIterable {
        /// A 1 pt line, 40 percent of the box tall, floating in the middle.
        case line
        /// 1 pt, dashed, the full height of the box.
        case dashed
        /// A short notch down from the top edge and up from the bottom one, a ruler's
        /// graduation, leaving the middle of the box to the text.
        case notches
    }
    /// The mark every enhance row draws. Notches, because the line and the dashes run through
    /// the row label.
    static let defaultLimitMark: LimitMark = .notches
    var limitMark: LimitMark = CentreOriginTrack.defaultLimitMark
    /// Shared by all three marks, so a side by side compares the shape and not the ink.
    static let limitMarkOpacity = 0.28
    /// The dashed mark's dash count, and the notch length.
    static let limitDashes = 6
    static let limitNotch: CGFloat = 6

    static let trackHeight: CGFloat = 4
    static let hitHeight: CGFloat = 20
    /// The capsule look: 34 pt tall, 9 pt corners, the fill at 42
    /// percent of the accent and a 2 pt edge at full accent.
    static let capsuleHeight: CGFloat = 34
    static let capsuleRadius: CGFloat = 9
    static let capsuleFillOpacity = 0.42
    static let capsuleEdgeWidth: CGFloat = 2
    /// The gap left in the value edge where it passes under the readout, a line of text.
    static let readoutGap: CGFloat = 18
    /// The box itself, the same quiet lift a grouped section card has over the window.
    static let capsuleBackground = 0.06
    /// The box while it holds keyboard focus. Replaces `RowFocusWash` for this look, because
    /// the box IS the row now and a wash around it would bleed into the 7 pt gap.
    static let capsuleFocusedBackground = 0.10
    static let capsuleFocusedEdge = 0.14
    /// One arrow key press on an enhance slider. Matches the readout's two decimal places,
    /// so a press always changes the number the user can see.
    static let defaultKeyStep = 0.01
    /// 10x, the drag's coarse factor. The app does not read it: Shift is fine on both a drag
    /// and an arrow, no key is assigned to coarse, and so the arrows have no fast step.
    ///
    /// `TrackDragTests.testCoarseOnADragCouldOnlyEverSaturate` records why a coarse drag
    /// cannot exist on this control at all: plain drag already maps the whole track onto the
    /// whole range, so there is nothing for it to be coarse relative to, and 10x crosses the
    /// span in a tenth of the width. That argument is about the drag and says nothing about an
    /// arrow, where a press is a fixed quantum and a bigger quantum is simply a bigger press.
    static let coarseMultiplier = 10.0
    /// 0.1. Shift reaches this on both a drag and an arrow.
    ///
    /// On an arrow a fine step is 0.001, which the two-decimal readout cannot show, so a single
    /// Shift-press leaves the number where it was. That is expected: the feedback for this
    /// control is the photograph, where a 0.001 change is visible. Do not "fix" it on the
    /// grounds that it looks dead.
    static let fineMultiplier = 0.1

    /// How far Option opens the range past its bounds while dragging.
    ///
    /// 2x, measured on an existing Option-drag convention rather than invented.
    ///
    /// It coexists with the typed readout on purpose. One is the convention, the other is
    /// explicit and unbounded.
    static let optionRangeFactor = 2.0

    /// Whether this track holds keyboard focus, owned by the row rather than by the track.
    ///
    /// The focus indication is a background across the whole row, so the row has to know. A
    /// control that hides its focus state cannot be indicated by anything outside itself.
    var isFocused: FocusState<Bool>.Binding
    /// The width, in points from the trailing edge, that the caller's readout sits over. The
    /// capsule's value edge and its ticks are drawn clear of the text there: the edge as a
    /// stub above and below it, a tick not at all. Zero, the default, clears nothing.
    var readoutClearance: CGFloat = 0
    /// Values marked on the LINE look with a small tick across the track: the Tone
    /// rows mark their preset's value, so the fill shows where the value is and the tick
    /// where the preset put it. Empty, the default, draws nothing.
    var marks: [Double] = []

    /// The line look's tick: 2 pt wide, 10 pt tall across the 4 pt track, in the quiet ink
    /// the capsule's limit marks use, a little stronger so it reads over the fill.
    static let markWidth: CGFloat = 2
    static let markHeight: CGFloat = 10
    static let markOpacity = 0.45

    @State private var dragOrigin: Double?
    /// The range as it stood when the drag BEGAN.
    ///
    /// Option opens this, never the live `range`. `EnhanceSliderRow.effectiveRange` grows to
    /// contain the value, so doubling the live range compounds: each `onChanged` doubles a
    /// range that the previous event just widened. Inside a single drag that way, +40 px
    /// reaches 2.22 and a drag to the edge reaches 1,000.00, saturating `storageLimit`.
    @State private var dragRange: ClosedRange<Double>?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ink(width: w, height: geo.size.height)
                .frame(width: w, height: geo.size.height, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(drag(width: w))
        }
        .frame(height: look == .line ? Self.hitHeight : Self.capsuleHeight)
        .focusable(isEnabled)
        // The ring is OFF, the focus is NOT. The system draws a rounded rectangle around a
        // focusable custom view, which a stock `Slider` never draws, so it is suppressed here.
        //
        // Focusability itself stays, because arrow keys, tab order and the accessibility path
        // all hang off it and a control that cannot take focus is not reachable without a
        // mouse.
        .focusEffectDisabled(true)
        .focused(isFocused)
        // ESCAPE GIVES FOCUS BACK. This view takes focus and answers all four arrows
        // `.handled`, so without it the only way out is clicking elsewhere, and with no ring
        // the focus would be both invisible and inescapable.
        //
        // Escape rather than a new key because it already means "back out of this" everywhere
        // else in the app: it leaves the closeup, and it abandons a typed value in the
        // readout. Those two are unaffected. A focused TEXT FIELD keeps focus while it is
        // open, so this handler does not run in front of the readout's own Escape.
        .onKeyPress(.escape) {
            guard isFocused.wrappedValue else { return .ignored }
            isFocused.wrappedValue = false
            // Releasing is only half of it. Focus would otherwise land on the window, where
            // the arrow keys drive nothing, so the keyboard is handed BACK to the gallery
            // explicitly.
            onReleaseFocus()
            return .handled
        }
        .onKeyPress(.leftArrow) { nudge(-1); return .handled }
        .onKeyPress(.rightArrow) { nudge(+1); return .handled }
        .onKeyPress(.downArrow) { nudge(-1); return .handled }
        .onKeyPress(.upArrow) { nudge(+1); return .handled }
        .disabled(!isEnabled)
        // One element to VoiceOver, because a ZStack of capsules is otherwise announced as
        // decoration. There is no `.isSlider` trait in SwiftUI: an element is announced as
        // adjustable because it HAS an adjustable action, so the action below is what confers
        // the behavior and a trait would be the wrong tool even if one existed.
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text(String(format: "%.2f", value)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(+1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    // MARK: drawing

    @ViewBuilder
    private func ink(width w: CGFloat, height h: CGFloat) -> some View {
        let xv = x(of: value, in: w)
        let xn = x(of: neutral, in: w)
        switch look {
        case .line:
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: Self.trackHeight)
                // Drawn from the neutral point toward the value, in whichever direction that
                // is, so a control at rest shows NO fill at all and a nudge either way shows
                // which way it went. That is the whole affordance.
                Capsule()
                    .fill(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: max(0, abs(xv - xn)), height: Self.trackHeight)
                    .offset(x: min(xv, xn))
            }
            // The fill is cut to the track's own shape, so it can never reach above or
            // below the track, whatever pixel the row lands on. The capsule look is cut to its box
            // the same way, by `clipShape(shape)` below.
            .frame(height: Self.trackHeight)
            .clipShape(Capsule())
            // The marks sit OUTSIDE the clip, so a tick can stand taller than the track.
            .overlay(alignment: .leading) {
                ForEach(marks, id: \.self) { m in
                    Rectangle()
                        .fill(Color.primary.opacity(Self.markOpacity))
                        .frame(width: Self.markWidth, height: Self.markHeight)
                        .offset(x: Self.markX(x(of: m, in: w), width: w))
                }
            }
        case .capsule(let ticks):
            let shape = RoundedRectangle(cornerRadius: Self.capsuleRadius, style: .continuous)
            let focused = isFocused.wrappedValue
            ZStack(alignment: .leading) {
                shape.fill(Color.primary.opacity(focused ? Self.capsuleFocusedBackground
                                                         : Self.capsuleBackground))
                // The same rule as the line: nothing at rest, and the fill grows from the
                // neutral point toward the value. Full height, so the box reads as a level.
                if abs(xv - xn) > 0.5 {
                    Rectangle()
                        .fill(Color.accentColor.opacity(isEnabled ? Self.capsuleFillOpacity : 0.15))
                        .frame(width: abs(xv - xn), height: h)
                        .offset(x: min(xv, xn))
                    // The edge sits at the VALUE end, inside the fill: the right edge for a
                    // positive value, the left for a negative.
                    let edge = Self.valueEdge(valueX: xv, neutralX: xn, width: w)
                    let edgeX = edge.x
                    let under = edgeX + Self.capsuleEdgeWidth > w - readoutClearance
                    VStack(spacing: under ? Self.readoutGap : 0) {
                        Rectangle().frame(height: under ? (h - Self.readoutGap) / 2 : h)
                        if under { Rectangle().frame(height: (h - Self.readoutGap) / 2) }
                    }
                    .foregroundStyle(Color.accentColor.opacity((isEnabled ? 1 : 0.3) * edge.opacity))
                    .frame(width: Self.capsuleEdgeWidth, height: h)
                    .offset(x: edgeX)
                }
                ForEach(ticks.filter { x(of: $0, in: w) < w - readoutClearance }, id: \.self) { t in
                    limitMark(height: h)
                        .offset(x: x(of: t, in: w) - 0.5)
                }
            }
            .frame(width: w, height: h, alignment: .leading)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.primary.opacity(focused ? Self.capsuleFocusedEdge : 0),
                                   lineWidth: 1)
            }
            .animation(.easeOut(duration: 0.12), value: focused)
        }
    }

    /// One limit mark, 1 pt wide, in the box's full height so every form lines up on the same
    /// x. See `LimitMark`.
    @ViewBuilder
    private func limitMark(height h: CGFloat) -> some View {
        let ink = Color.primary.opacity(Self.limitMarkOpacity)
        switch limitMark {
        case .line:
            Rectangle()
                .fill(ink)
                .frame(width: 1, height: h * 0.4)
                .frame(width: 1, height: h)
        case .dashed:
            // Equal dashes and gaps, sized so a dash starts at the top edge and one ends at
            // the bottom, rather than a fixed pattern running off the end at a random phase.
            let dash = h / CGFloat(2 * Self.limitDashes - 1)
            Path { p in
                p.move(to: CGPoint(x: 0.5, y: 0))
                p.addLine(to: CGPoint(x: 0.5, y: h))
            }
            .stroke(ink, style: StrokeStyle(lineWidth: 1, dash: [dash, dash]))
            .frame(width: 1, height: h)
        case .notches:
            VStack(spacing: 0) {
                Rectangle().frame(height: Self.limitNotch)
                Spacer(minLength: 0)
                Rectangle().frame(height: Self.limitNotch)
            }
            .foregroundStyle(ink)
            .frame(width: 1, height: h)
        }
    }

    // MARK: geometry

    /// Where the capsule's value edge goes, and how much of it to draw.
    ///
    /// The edge FADES OUT across the box's rounded end, and is gone when the value reaches the
    /// end of the span. There the 2 pt edge sits in the last 2 pt of the box, which is all
    /// rounded corner, and because the readout sits over it there it is drawn as two 8 pt
    /// stubs, entirely inside the 9 pt corner. The clip would trim each stub to the curve and
    /// leave two crescents on the box's end, in bounds but reading as a line that escaped.
    ///
    /// The fill already reaches the box's end there, so the end of the box IS the level and
    /// the edge has nothing left to say. It fades linearly over one corner radius, which keeps
    /// it continuous as a drag approaches the end (no pop), and it is computed in points, so
    /// it is zero at the end whatever pixel the row lands on. Both ends: a negative value
    /// reaching the lower bound meets the left corner the same way.
    static func valueEdge(valueX xv: CGFloat, neutralX xn: CGFloat,
                          width w: CGFloat) -> (x: CGFloat, opacity: Double) {
        let x = xv >= xn ? xv - capsuleEdgeWidth : xv
        let fromEnd = min(x, w - (x + capsuleEdgeWidth))
        return (x, Double(min(max(fromEnd / capsuleRadius, 0), 1)))
    }

    /// Where a line-look mark's leading edge goes: centered on the value, kept inside the
    /// track so a mark at either end is drawn whole.
    static func markX(_ valueX: CGFloat, width w: CGFloat) -> CGFloat {
        min(max(valueX - markWidth / 2, 0), max(0, w - markWidth))
    }

    /// Where a value sits, in points from the leading edge.
    private func x(of v: Double, in width: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let t = (v - range.lowerBound) / span
        return CGFloat(min(max(t, 0), 1)) * width
    }

    /// The value at a point, which is the inverse and must stay the inverse: a press should
    /// land the fill edge under the pointer.
    ///
    /// Takes the range explicitly because Option drags over a WIDER one than the track draws.
    static func value(atX px: CGFloat, in width: CGFloat, over range: ClosedRange<Double>) -> Double {
        guard width > 0 else { return range.lowerBound + (range.upperBound - range.lowerBound) / 2 }
        let t = Double(min(max(px, 0), width) / width)
        return range.lowerBound + t * (range.upperBound - range.lowerBound)
    }

    // MARK: interaction

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if dragOrigin == nil {
                    dragOrigin = value
                    dragRange = range
                    onEditingChanged(true)
                }
                let base = dragRange ?? range
                let m = Self.modifiers()
                if m.contains(.option) {
                    // OPTION OPENS THE RANGE, it does not change the rate.
                    //
                    // The drag stays absolute and the same track simply addresses twice as
                    // much value. Let go and the
                    // value stays where it was put, outside the normal bounds, exactly as a
                    // typed number leaves it.
                    let opened = Self.opened(base)
                    set(Self.value(atX: g.location.x, in: width, over: opened), allowing: opened)
                } else if m.contains(.shift) {
                    // SHIFT IS FINE.
                    //
                    // Relative to where the drag STARTED, scaled down. An absolute mapping
                    // would jump the value to the pointer on the first pixel and make fine
                    // adjustment impossible, which is the whole point of holding the key.
                    //
                    // Coarse is a mode this control cannot have: plain drag already maps the
                    // whole track onto the whole range, so there is nothing for coarse to be
                    // coarse relative to, and at 10x the span is crossed in a tenth of the
                    // width. Fine is the direction with somewhere to go.
                    set((dragOrigin ?? value) + Self.modifierDelta(
                        translation: g.translation.width, width: width,
                        span: base.upperBound - base.lowerBound, scale: Self.fineMultiplier))
                } else {
                    set(Self.value(atX: g.location.x, in: width, over: base))
                }
            }
            .onEnded { _ in
                dragOrigin = nil
                dragRange = nil
                onEditingChanged(false)
            }
    }

    /// The range Option addresses: the shown span, opened about its center.
    static func opened(_ r: ClosedRange<Double>) -> ClosedRange<Double> {
        let centre = (r.lowerBound + r.upperBound) / 2
        let half = (r.upperBound - r.lowerBound) / 2 * optionRangeFactor
        return (centre - half)...(centre + half)
    }

    /// How far ONE arrow press moves the value, for the keys being held.
    ///
    /// Its own static function so the mapping can be asserted rather than described.
    ///
    /// Shift is FINE, the same as on a drag. One key, one meaning, across both input devices.
    ///
    /// THERE IS NO COARSE ARROW KEY, on any control in this app, and there is no parameter
    /// to pass one through either. No parameter at all is a rule nothing can break. Every
    /// slider in the app reads the same: shift is fine, option opens the range, nothing else
    /// does anything. A coarse key, if one is ever added, belongs HERE, once, for all of them.
    static func step(_ keyStep: Double, modifiers: NSEvent.ModifierFlags) -> Double {
        modifiers.contains(.shift) ? keyStep * fineMultiplier : keyStep
    }

    /// How far a modifier-drag moves the value, as a SIGNED fraction of the track.
    ///
    /// Not `value(atX:)`, which clamps its input to `0...width` because it is meant for an
    /// absolute POSITION. A relative TRANSLATION fed through it clamps every leftward drag to
    /// zero, so -120 px and -1 px both produce exactly +0.0000.
    ///
    /// A position and a translation are different quantities and only one of them may be
    /// clamped to the track.
    static func modifierDelta(translation: CGFloat, width: CGFloat, span: Double, scale: Double) -> Double {
        guard width > 0 else { return 0 }
        return Double(translation / width) * span * scale
    }

    private func nudge(_ direction: Double) {
        let m = Self.modifiers()
        let step = Self.step(keyStep, modifiers: m)
        // And Option means the same thing here as on a drag: it OPENS the range. Stepping past
        // the shown bound is the arrow-key form of dragging past it.
        set(Self.stepped(value, by: direction * step, keyStep: keyStep, neutral: neutral),
            allowing: m.contains(.option) ? Self.opened(range) : range)
    }

    /// The value one arrow press lands on: `value + delta`, with the floating point residue
    /// of repeated steps removed.
    ///
    /// A step such as 0.01 has no exact binary form, so three presses right and three left
    /// from 0 end on -3.5e-18 rather than 0. That value reads "0.00", yet it is not the
    /// resting value, so a row holding it counts as adjusted: it shows its reset mark and
    /// its section stays lit. The sum is therefore snapped onto the grid of fine steps
    /// counted from `neutral`, and only when it is within a rounding error of a grid point.
    /// The tolerance is a billionth of a fine step, so a value a drag or a typed number put
    /// between grid points is carried exactly as it was, and a step that comes back to the
    /// neutral lands on it exactly.
    static func stepped(_ value: Double, by delta: Double, keyStep: Double, neutral: Double) -> Double {
        let sum = value + delta
        let grid = keyStep * fineMultiplier
        guard grid > 0, sum.isFinite else { return sum }
        let onGrid = neutral + ((sum - neutral) / grid).rounded() * grid
        return abs(sum - onGrid) <= grid * 1e-9 ? onGrid : sum
    }

    /// Clamped to the track's CURRENT span rather than to the control's nominal range: the
    /// span is what the user can see, and dragging must not silently exceed it.
    private func set(_ v: Double) { set(v, allowing: range) }

    /// Clamped to the range the CURRENT gesture addresses, which is the shown span for an
    /// ordinary drag and the opened one while Option is held. Never unbounded: a drag must not
    /// silently exceed what the gesture claims to cover.
    private func set(_ v: Double, allowing bounds: ClosedRange<Double>) {
        value = min(max(v, bounds.lowerBound), bounds.upperBound)
    }

    /// From AppKit rather than a stack of modifier-qualified gestures, the same way
    /// `GridView` reads a click, because that is the OS's own answer and it cannot disagree
    /// with what the user is holding.
    private static func modifiers() -> NSEvent.ModifierFlags {
        NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
    }
}
