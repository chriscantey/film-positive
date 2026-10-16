import SwiftUI
import FilmSidecar
import FilmPositiveCore

/// The two manual color axes as the inspector names them.
///
/// NOT "Warmth" and NOT "Tint", and that is a hard rule rather than a preference. Both of
/// those words are already taken by `EnhanceSettings.warmth` and `.tint`, which are enhance
/// sliders that follow a blackbody locus over the finished positive. These two are a red and
/// blue opponent in DENSITY space applied to the base, with green held exactly, so they are a
/// different operation on a different stage of the pipeline. Two controls sharing a name
/// while doing different things is the fastest way to make a panel unpredictable.
///
/// Not "Yellow" and "Magenta" either, which is the lab's own vocabulary and would be worse
/// here than the enhance collision. A magenta printing filter moves GREEN, and green is the
/// exact channel these hold, so the lab's name for the axis would name the one channel the
/// axis promises not to touch.
///
/// In prose, they are "the warm axis" and "the green axis".
enum ColourAxis: String, CaseIterable, Identifiable, Sendable {
    case warm
    case green

    var id: String { rawValue }

    /// The end a negative value moves toward.
    var lowLabel: String {
        switch self {
        case .warm: return "Cool"
        case .green: return "Green"
        }
    }

    /// The end a positive value moves toward.
    var highLabel: String {
        switch self {
        case .warm: return "Warm"
        case .green: return "Magenta"
        }
    }

    /// Both ends, which is how a center origin control is labeled: the row has no single
    /// name, it has a direction, and naming one end would make the other end read as a
    /// negative amount of it.
    ///
    /// Both words sit in the LABEL COLUMN rather than one at each end of the track, and that
    /// is a width decision with a measurement behind it. An enhance row already spends its
    /// content on a label, a track and a 46 pt readout, so putting the high word between the
    /// track and the readout takes another 45 pt or so out of the TRACK at exactly the width
    /// where a three-column split view overflows rather than compresses.
    ///
    /// The cost is paid in `ShellLayout`, not here. `Cool ↔ Warm` measures 106 pt.
    /// `Green ↔ Magenta` needs 134 pt and wraps to two lines at a 330 pt inspector minimum,
    /// taking that row's pitch to 53 pt against 41 pt everywhere else. So the minimum is 360
    /// and the ideal 370: the row is one line, so the column follows the row.
    var label: String { "\(lowLabel) \u{2194} \(highLabel)" }

    /// Spoken, where the arrow is not a word.
    var accessibilityLabel: String { "\(lowLabel) to \(highLabel)" }

    /// Named for the end the label starts from, so the glyph and the first word agree.
    var symbol: String {
        switch self {
        case .warm: return "flame"
        case .green: return "leaf"
        }
    }

    func value(in axes: ColourAxes) -> Double {
        switch self {
        case .warm: return axes.warm
        case .green: return axes.green
        }
    }

    /// Writes ONE axis and leaves the other exactly as it was.
    ///
    /// That is the whole reason this is a function on the axis rather than two lines at the
    /// call site: `SidecarEdits.setColourAxes` takes the pair, so every writer has to read
    /// the frame's OWN other axis and carry it through. A call site that built a fresh
    /// `ColourAxes(warm:)` would silently zero the green axis of every frame it touched, and
    /// on a single frame at rest that is invisible.
    func setting(_ axes: ColourAxes, to value: Double) -> ColourAxes {
        var out = axes
        // Non-finite is dropped rather than clamped, the same rule `EnhanceControl.setting`
        // uses: a NaN compares false against everything, so it would defeat the no-op guards
        // downstream and reach the kernel as an undefined density.
        guard value.isFinite else { return out }
        let v = value.clamped(to: Self.storageLimit)
        switch self {
        case .warm: out.warm = v
        case .green: out.green = v
        }
        return out
    }

    // MARK: the numbers

    /// The span the track shows AT REST, in printer points, either side of zero.
    ///
    /// Twelve, from the two numbers that bound the useful range. A real color cast in a
    /// scanned frame measures around seven points, so the resting track has to reach past
    /// that comfortably or the common correction lives at the very end of the bar. A lab's
    /// full printer scale runs to about fifty, so a resting track that reached it would spend
    /// four fifths of its width on values nobody types.
    ///
    /// It is a RESTING span and not a limit. A typed value outside it widens the track to
    /// fit, exactly as an enhance row does, so twelve costs nothing but the default zoom.
    static let restingSpan = 12.0

    /// One arrow press: ONE PRINTER POINT.
    ///
    /// The point is the unit a lab quotes and the unit the sidecar stores, so it is the
    /// natural quantum. `ColourAxes.densityPerPoint` is 0.025 logE, which makes a press a
    /// real and visible move on the picture rather than a nudge below the noise.
    static let keyStep = 1.0

    /// The edit one row makes to one frame, EXACTLY as the row makes it.
    ///
    /// It is a function here rather than a closure in the view so it can be asserted without
    /// a window. The view's job is to call it; this is the rule it calls.
    ///
    /// Reading the other axis off THIS sidecar is the load-bearing part. Across a selection
    /// the frames may hold different values on the axis nobody is touching, so a single
    /// `ColourAxes` built once from the summary would flatten them all to the lead frame's
    /// value, or to zero on a Multiple. That failure is invisible on a single frame at rest,
    /// which is why `ColourAxisRowTests` has an explicit anti-test for it.
    ///
    /// A sidecar with no develop layer comes back unchanged, matching `SidecarEdits
    /// .setColourAxes`. In the app that branch is unreachable: `AppModel.apply` seeds the
    /// effective defaults before any edit runs, so the funnel has already built the layer by
    /// the time this sees it.
    func edit(_ sidecar: Sidecar, to value: Double) -> Sidecar {
        guard let develop = sidecar.develop else { return sidecar }
        let updated = setting(develop.colourAxes, to: value)
        guard updated != develop.colourAxes else { return sidecar }
        return SidecarEdits.setColourAxes(sidecar, updated)
    }

    /// Where a typed number stops being a number somebody meant.
    ///
    /// Four times a lab's full scale. It is not the cap on the control, it is the guard that
    /// keeps an absurd density out of the kernel, the same role `EnhanceControl.storageLimit`
    /// plays. Nobody reaches this by typing a value they intended.
    static let storageLimit: ClosedRange<Double> = -200...200
}

/// One color axis row: symbol, both end labels, a thumbless center-origin track, and the
/// value in printer points.
///
/// Deliberately the same row idiom as `EnhanceSliderRow`, down to the double-click reset and
/// the click-to-type readout, because a person who has learned one slider row in this panel
/// has learned all of them. The two pieces of chrome they share live in
/// `InspectorRowChrome.swift` so neither copy can drift.
///
/// Two things differ from an enhance row, and both follow from the unit. The readout shows
/// ONE decimal, because the fine step is a tenth of a point and a two decimal readout would
/// be showing a precision the control cannot produce. And an arrow press steps one whole
/// point rather than 0.01.
struct ColourAxisRow: View {
    let axis: ColourAxis
    let value: Double
    /// The selected frames disagree about THIS axis. They are asked separately, so a
    /// selection that agrees on warm and differs on green says Multiple on one row only.
    var isMultiple: Bool = false
    let onChange: (Double) -> Void
    let onEditing: (Bool) -> Void
    let onReset: () -> Void
    let onReleaseFocus: () -> Void

    @State private var typing: String?
    /// The value before a click run began, and the row's width for the click zones.
    @State private var clicks = RowClicks()
    @State private var rowWidth: CGFloat = 0
    @FocusState private var fieldFocused: Bool
    @FocusState private var trackFocused: Bool

    /// What the track SPANS right now: the resting twelve, grown to the next whole point
    /// that contains the value.
    ///
    /// Symmetric on purpose, the same as an enhance row: an asymmetric span would move the
    /// center origin off the middle of the row, and the center is the one thing every
    /// slider-shaped row in this panel agrees on.
    private var effectiveRange: ClosedRange<Double> {
        let bound = max(ColourAxis.restingSpan, abs(value).rounded(.up))
        return -bound...bound
    }

    /// One decimal, and the `+ 0` normalizes NEGATIVE ZERO.
    ///
    /// Shift-arrow steps 0.1 of a point, so it IS visible here, which is the difference from
    /// an enhance row. What is not visible is a value between zero and minus 0.05, which
    /// formats as "-0.0" and reads as a bug rather than as a small number. The enhance
    /// readout hit exactly this and the fix is the same one: IEEE gives -0.0 + 0.0 = +0.0, so
    /// only the label is cleaned up and the stored value keeps its sign.
    private func displayed(_ v: Double) -> String {
        String(format: "%.1f", (v * 10).rounded() / 10 + 0)
    }

    @ViewBuilder private var readout: some View {
        if let typing {
            TextField("", text: Binding(get: { typing }, set: { self.typing = $0 }))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .focused($fieldFocused)
                .onSubmit { commit() }
                // Escape abandons the typed value AND hands the keyboard back, so focus is not
                // stranded in the row.
                .onExitCommand { self.typing = nil; onReleaseFocus() }
                .onChange(of: fieldFocused) { _, focused in if !focused { commit() } }
                .onAppear {
                    // The track must let go first, or focus stays where it was and the field
                    // opens unfocused. And the assignment is deferred by one runloop turn:
                    // inside `onAppear` the field is not in the responder chain yet, so the
                    // request is dropped and click-to-type appears to need two clicks.
                    trackFocused = false
                    DispatchQueue.main.async { fieldFocused = true }
                }
        } else if isMultiple {
            Text("Multiple")
                .foregroundStyle(.secondary)
        } else {
            Text(displayed(value))
                .foregroundStyle(value == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
    }

    private func commit() {
        defer { typing = nil }
        guard let text = typing, let parsed = Double(text.trimmingCharacters(in: .whitespaces)) else { return }
        // NOT clamped to the resting span. A typed number is the explicit route past the
        // shown bounds and the track rescales around it, which is the rule the enhance rows
        // already established. `storageLimit` is not that cap in disguise: it is there
        // because "1e400" parses to infinity.
        guard parsed.isFinite else { return }
        onChange(parsed.clamped(to: ColourAxis.storageLimit))
    }

    private var track: some View {
        CentreOriginTrack(value: Binding(get: { value }, set: { onChange($0) }),
                          range: effectiveRange,
                          neutral: 0,
                          isEnabled: true,
                          onEditingChanged: { began in
                              if began { clicks.pressed(at: value) }
                              onEditing(began)
                          },
                          onReleaseFocus: onReleaseFocus,
                          keyStep: ColourAxis.keyStep,
                          isFocused: $trackFocused)
    }

    /// Help hangs on the LEAVES, never on the container, or the container's sentence
    /// propagates down over every child's own and the first row of a section claims the
    /// whole section's tooltip rect.
    private var rowHelp: String {
        isMultiple ? SliderHelp.mixed : SliderHelp.single
    }

    /// The readout's column, trailing in the row.
    static let readoutColumn: CGFloat = 46

    /// The same rule as an enhance row: a double click on the number types a value,
    /// anywhere else it resets, and nothing fires while the field is open.
    private func doubleClicked(at x: CGFloat) {
        guard typing == nil else { return }
        guard RowClicks.onReadout(x, width: rowWidth, readout: Self.readoutColumn) else {
            onReset()
            return
        }
        if isMultiple {
            typing = ""
            return
        }
        let before = clicks.valueBeforeClicks ?? value
        if before != value { onChange(before) }
        typing = displayed(before)
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                track
                    .help(rowHelp)
                readout
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: Self.readoutColumn, alignment: .trailing)
                    // A single click on the number does nothing but land on the row.
                    .allowsHitTesting(typing != nil)
            }
        } label: {
            // One line, always, as the tone rows hold theirs. Inside a slider group the row
            // is narrower by the indent, and a label allowed to compress wraps there. The
            // label keeps its width and the track gives it up.
            Label(axis.label, systemImage: axis.symbol)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .help(rowHelp)
                .accessibilityLabel(axis.accessibilityLabel)
        }
        .contentShape(Rectangle())
        .modifier(WidthReader(width: $rowWidth))
        .modifier(RowFocusWash(isFocused: trackFocused))
        // The double click must not fire on the text field, or typing into the readout would
        // reset the control the moment a second click lands in it (`doubleClicked` checks).
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { doubleClicked(at: $0.location.x) })
        .accessibilityIdentifier("colourAxis.\(axis.id)")
    }
}

/// The hover help every slider row carries, the two axis rows here and every Enhance row.
/// The slider's own name is on the row beside it, so the help only
/// says what the clicks do.
enum SliderHelp {
    static let single = "Double-click the number to type, anywhere else to reset."
    static let mixed = "Frames differ. Dragging sets them all."
}
