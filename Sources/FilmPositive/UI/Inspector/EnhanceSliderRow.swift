import SwiftUI

/// One enhance control: SF Symbol, label, a thumbless center-origin track, and the value.
///
/// Drawn as one rounded box per row with the symbol, the name and the value inside it, the
/// fill growing from the center at the full box height, and a reset glyph outside on the
/// right that shows only when the row is not at 0. No center line.
///
/// Double-click resets this one slider to 0, anywhere but the number. It rides as a
/// `simultaneousGesture` because the track's own drag recognizer must keep working: an
/// exclusive gesture would swallow the drag and the control would stop sliding. A double
/// click ON the number types a value instead, and a single click anywhere, the number
/// included, only moves the slider (`RowClicks`).
struct EnhanceSliderRow: View {
    let control: EnhanceControl
    let value: Double
    /// The selected frames disagree about this control. The slider parks at the identity
    /// position and the readout says Multiple, so the position is never read as a number.
    /// A drag from there writes an absolute value to every selected frame, which is the
    /// only rule that gives the same result whichever frame you happened to look at.
    var isMultiple: Bool = false
    /// Continuous, called for every tick of the drag so the preview keeps up.
    let onChange: (Double) -> Void
    /// True at drag start, false at drag end, which is where undo coalescing hangs.
    let onEditing: (Bool) -> Void
    let onReset: () -> Void
    /// Escape on the track hands the keyboard back. The row does not know where it should go,
    /// so the owner says.
    let onReleaseFocus: () -> Void
    /// The frame the inspector is showing and the selection. When either changes, a held
    /// range lets go.
    var frameKey: AnyHashable? = nil

    /// The grown span this row is holding, if any. See `RangeHold`.
    @State private var hold = RangeHold()

    /// The typed value while the readout is being edited. Nil means it is a label again.
    @State private var typing: String?
    /// The value before a click run began, and the box's width for the click zones.
    @State private var clicks = RowClicks()
    @State private var boxWidth: CGFloat = 0
    @FocusState private var fieldFocused: Bool
    /// Whether this row's TRACK holds keyboard focus. Lifted out of `CentreOriginTrack` so the
    /// whole row can show it.
    @FocusState private var trackFocused: Bool

    /// The click rules live in `InspectorRowChrome.swift` (`RowClicks`), shared with the color
    /// axis rows. The focus indication for THIS row is drawn by the capsule itself, because
    /// the box is the row. The color axis rows wear `RowFocusWash`.


    /// Double-click the number to type one. Enter or clicking away commits and puts it back
    /// to a label, Escape abandons. A value outside the shown range is taken and the track
    /// rescales around it. A value that does not parse is dropped silently, because a
    /// validation error on a slider readout is more interruption than the mistake deserves.
    @ViewBuilder private var readout: some View {
        if let typing {
            TextField("", text: Binding(get: { typing }, set: { self.typing = $0 }))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .focused($fieldFocused)
                .onSubmit { commit() }
                // Escape abandons the typed value AND hands the keyboard back. Without the
                // second half, focus lands on the window and the arrows drive nothing at all.
                .onExitCommand { self.typing = nil; onReleaseFocus() }
                .onChange(of: fieldFocused) { _, focused in if !focused { commit() } }
                .onAppear {
                    // The track must let go first, or focus stays where it was and the field
                    // opens unfocused.
                    trackFocused = false
                    // Deferred by one runloop turn ON PURPOSE. Assigning focus inside
                    // `onAppear` runs before the field is in the responder chain, so the
                    // request is dropped: the field opens with NO caret while
                    // `AXFocusedUIElement` still names the row ABOVE, arrow presses move THAT
                    // row's value, and click-to-type appears to need two clicks.
                    DispatchQueue.main.async { fieldFocused = true }
                }
        } else if isMultiple {
            Text("Multiple")
                .foregroundStyle(.secondary)
        } else {
            // Rounded before display, and the `+ 0` is not noise: it normalizes NEGATIVE ZERO.
            //
            // Shift-arrow steps 0.001, so one press left from rest leaves -0.001, which
            // formats as "-0.00". A fine press need not move the readout, but "-0.00" reads as
            // a bug rather than as a small value.
            //
            // IEEE gives -0.0 + 0.0 = +0.0. The stored value keeps its sign and its precision,
            // and only the label is cleaned up.
            Text((value * 100).rounded() / 100 + 0, format: .number.precision(.fractionLength(2)))
                .foregroundStyle(value == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        }
    }

    private func commit() {
        defer { typing = nil }
        guard let text = typing, let parsed = Double(text.trimmingCharacters(in: .whitespaces)) else { return }
        // Typed values are NOT clamped to the shown range. The number is taken and the TRACK
        // rescales around it, which is what `effectiveRange` does.
        //
        // `storageLimit` is not a cap in disguise. It exists because a non-finite Double
        // reaching a Core Image filter is undefined behavior, and "1e400" parses to infinity.
        // Nobody will ever meet this bound by typing a number they meant.
        guard parsed.isFinite else { return }
        edit(parsed.clamped(to: EnhanceControl.storageLimit))
    }

    /// What the track SPANS right now.
    ///
    /// At rest it is the nominal -1...1. Once a value sits outside
    /// that, the span grows symmetrically to the next whole unit that contains it, so a
    /// typed 1.8 gives a -2...2 track and a typed 5.2 gives -6...6. The fill stays readable
    /// because the track is redrawn around the number rather than the number being pinned to
    /// the end of a track it has outgrown.
    ///
    /// Symmetric on purpose: an asymmetric span would move the center origin off the middle
    /// of the row, and the center is the one thing every row in the panel agrees on.
    ///
    /// An EDIT that grows the span also holds it, so dragging back inside does not snap the
    /// track back under the pointer. `RangeHold` owns that rule.
    private var effectiveRange: ClosedRange<Double> { hold.span(for: value) }

    /// Every edit made from this row goes through here, so the hold sees it.
    private func edit(_ v: Double) {
        hold.edited(to: v)
        onChange(v)
    }

    /// The track: a flat bar whose fill grows from zero, with no thumb. A system `Slider`
    /// cannot draw that: `neutralValue` needs `#available(macOS 26)`, moves where the fill
    /// STARTS and keeps SwiftUI's circular thumb.
    private var track: some View {
        CentreOriginTrack(value: Binding(get: { value }, set: { edit($0) }),
                          range: effectiveRange,
                          neutral: 0,
                          isEnabled: true,
                          onEditingChanged: { began in
                              if began { clicks.pressed(at: value) }
                              onEditing(began)
                          },
                          onReleaseFocus: onReleaseFocus,
                          look: .capsule(ticks: hold.ticks(for: value)),
                          isFocused: $trackFocused,
                          readoutClearance: Self.readoutText + Self.boxInset)
    }

    /// The help hangs on the LEAVES, never on a container. A `.help` on a container
    /// propagates down over its descendants' own help (in the Accessibility tree every
    /// readout reports the ROW's sentence, not its own), and in a grouped `Form` the first
    /// row of a group can claim the whole group's tooltip. Each leaf is its own view with its
    /// own rect and its own AX element, so every leaf names its own control whichever way the
    /// tooltip is resolved. Hovering the row's empty gaps gives no tooltip.
    ///
    /// The text is `SliderHelp`, the same words the two color axis rows carry: the name is
    /// on the row, and the help only says what the clicks do. A control that says what it
    /// does (the three Vignette rows, whose Size and Softness are not self-explaining words)
    /// puts that one sentence first.
    private var rowHelp: String { Self.help(for: control, isMultiple: isMultiple) }

    static func help(for control: EnhanceControl, isMultiple: Bool) -> String {
        let clicks = isMultiple ? SliderHelp.mixed : SliderHelp.single
        return control.help.map { "\($0) \(clicks)" } ?? clicks
    }

    /// A double click on the number opens the field on the value from before the first
    /// click, which had already moved the slider. Anywhere else it resets. The field itself
    /// takes its own clicks, so nothing here fires while it is open.
    private func doubleClicked(at x: CGFloat) {
        guard typing == nil else { return }
        guard RowClicks.onReadout(x, width: boxWidth, readout: Self.readoutColumn + Self.boxInset) else {
            onReset()
            return
        }
        if isMultiple {
            typing = ""
            return
        }
        let before = clicks.valueBeforeClicks ?? value
        if before != value { onChange(before) }
        typing = String(format: "%.2f", before)
    }

    /// Resets THIS control, outside the box on the right. Shown only when there is
    /// something to reset, and still taking its space when hidden so every row's box ends at
    /// the same x.
    private var hasValue: Bool { isMultiple || value != 0 }

    static let symbolColumn: CGFloat = 18
    /// The readout's column, the box's side inset, and how much of that column a number such as
    /// "-2.50" actually covers at the trailing end, which is what the track's edge keeps clear of.
    static let readoutColumn: CGFloat = 58
    static let boxInset: CGFloat = 12
    static let readoutText: CGFloat = 40

    private var resetGlyph: some View {
        Button(action: onReset) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Reset \(control.label)")
        .accessibilityLabel("Reset \(control.label)")
        .opacity(hasValue ? 1 : 0)
        .allowsHitTesting(hasValue)
        .accessibilityHidden(!hasValue)
    }

    /// The box IS the track: the whole width is the drag surface, so the drag stays absolute
    /// across the full row. The symbol, the name and the readout sit on top. Neither the name
    /// nor the number takes hits, so a press on either lands on the track underneath. Only
    /// the open field does.
    ///
    /// The help still hangs on the LEAVES: the track carries the row's sentence and
    /// the readout its own. The overlay is outside the track's `.help`, so the readout's
    /// tooltip is not overridden by it.
    private var box: some View {
        let zero = !isMultiple && value == 0
        return track
            .help(rowHelp)
            .accessibilityLabel(control.label)
            .overlay {
                HStack(spacing: 8) {
                    // The symbol in a fixed column so every name starts at the same x. A
                    // `Label` sizes the icon to the glyph, so the names would wander by a few
                    // points from row to row.
                    HStack(spacing: 8) {
                        Image(systemName: control.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: Self.symbolColumn)
                        Text(control.label)
                            .foregroundStyle(zero ? AnyShapeStyle(.primary.opacity(0.78)) : AnyShapeStyle(.primary))
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    Spacer(minLength: 4)
                    readout
                        .monospacedDigit()
                        .frame(width: Self.readoutColumn, alignment: .trailing)
                        .allowsHitTesting(typing != nil)
                }
                .padding(.horizontal, Self.boxInset)
            }
    }

    var body: some View {
        HStack(spacing: 6) {
            box
                .modifier(WidthReader(width: $boxWidth))
                // The double click, on the box so its location is in the box's own space. It
                // must not fire on the open field, or typing into the readout would reset the
                // control the moment a second click lands in it (`doubleClicked` checks).
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { doubleClicked(at: $0.location.x) })
            resetGlyph
        }
        // A click anywhere outside this row lets a held range go. Watched only while
        // something is held, so idle rows cost nothing.
        .background(ClickAwayMonitor(isActive: hold.isHolding) { hold.release() })
        .onChange(of: frameKey) { _, _ in hold.release() }
        // Focus leaving the row lets go too: Escape, or Tab to another control. Opening the
        // readout's field is not leaving, because `typing` is set before the track lets go.
        .onChange(of: trackFocused) { was, now in
            if was, !now, typing == nil { hold.release() }
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("enhance.\(control.id)")
    }
}
