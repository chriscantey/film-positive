import SwiftUI
import FilmSidecar
import FilmPositiveCore

/// The Tone row's sliders: the four sliders under Tone, and the rules they write by.
///
/// Some people only make a positive and never open Enhance, so Develop carries the
/// lab-level controls. They are there whatever tone is picked: with None they are the
/// controls, and with a preset they show the values the preset sets under the hood.
///
/// So each slider SHOWS the value the frame's tone runs, the preset's own while
/// `toneAdjust` is nil, and moving one writes all four (`ToneSlider.edit`). The track's fill
/// grows from the scale's neutral (`neutral`), so a preset shows on the tracks, and a tick
/// marks the preset's own value. Picking a tone in the Tone control clears the four back to
/// nil (`ToneSlider.pick`).
///
/// Built in the axis rows' idiom (a remembered app-wide fold, the axis rows' row style),
/// and deliberately not by generalizing `ColourAxisRow`, so the two rows can change on
/// their own.
enum ToneSlider: String, CaseIterable, Identifiable, Sendable {
    case exposure
    case contrast
    case black
    case white

    var id: String { rawValue }

    /// The end the track's left moves toward.
    var lowLabel: String {
        switch self {
        case .exposure: return "Darker"
        case .contrast: return "Softer"
        case .black: return "Deeper"
        case .white: return "Dimmer"
        }
    }

    /// The end the track's right moves toward.
    var highLabel: String {
        switch self {
        case .exposure: return "Lighter"
        case .contrast: return "Harder"
        case .black: return "Lifted"
        case .white: return "Brighter"
        }
    }

    /// Both ends, as the axis rows are labeled (`ColourAxis.label`).
    var label: String { "\(lowLabel) \u{2194} \(highLabel)" }
    var accessibilityLabel: String { "\(lowLabel) to \(highLabel)" }

    var symbol: String {
        switch self {
        case .exposure: return "plusminus.circle"
        case .contrast: return "circle.lefthalf.filled"
        case .black: return "moon"
        case .white: return "sun.max"
        }
    }

    /// The row's hover help, one plain sentence.
    var help: String {
        switch self {
        case .exposure: return "Makes the whole picture lighter or darker."
        case .contrast: return "Pulls the darks and lights apart or together."
        case .black: return "Sets how deep the darkest tones go."
        case .white: return "Sets how bright the lightest tones go."
        }
    }

    // MARK: the numbers

    /// What the track spans, in the readout's own unit. Fixed, because each one is the whole
    /// legal range of its value (`ToneAdjust`'s spans) rather than a resting zoom.
    var range: ClosedRange<Double> {
        switch self {
        case .exposure: return ToneAdjust.exposureStops
        case .contrast: return ToneAdjust.contrastUnits
        case .black: return (ToneAdjust.blackRange.lowerBound * 100)...(ToneAdjust.blackRange.upperBound * 100)
        case .white: return (ToneAdjust.whiteRange.lowerBound * 100)...(ToneAdjust.whiteRange.upperBound * 100)
        }
    }

    /// Where the track's DRAWN fill grows from: the scale's own neutral, Exposure 0.00,
    /// Contrast 0.00, Black 0 and White 100, which are None's values.
    ///
    /// Not the preset's value, or an untouched preset would draw no fill and picking Bold
    /// would change the numbers and nothing on the tracks. Drawing only: the stored values,
    /// the lit rule and the double-click reset (the frame's own preset) do not use it.
    var neutral: Double {
        switch self {
        case .exposure, .contrast, .black: return 0
        case .white: return 100
        }
    }

    /// Where a preset's tick sits on this track, so a person sees both where the preset puts
    /// the value and how far they have moved from it. Nil when the preset sits on the
    /// neutral, where the start of the fill already marks it, so None draws no ticks at all.
    func tick(for mode: ToneMode) -> Double? {
        let v = value(in: ToneAdjust.preset(for: mode))
        return readout(v) == readout(neutral) ? nil : v
    }

    /// One arrow press: a tenth of a stop, a twentieth of Bold's contrast, one point.
    /// Shift is a tenth of that, as on every slider in the app.
    var keyStep: Double {
        switch self {
        case .exposure: return 0.1
        case .contrast: return 0.05
        case .black, .white: return 1
        }
    }

    /// The readout value for a frame's four values.
    ///
    /// Exposure in stops, positive lighter, so it reads `-exposure / 0.30` (the stored value
    /// is a density, where positive is darker). Contrast in Bold's own gamma, so Flat reads 0
    /// and Bold 1. Black and white in percent.
    func value(in adjust: ToneAdjust) -> Double {
        switch self {
        case .exposure: return -adjust.exposure / ToneAdjust.densityPerStop
        case .contrast: return ToneAdjust.contrastUnits(adjust.contrast)
        case .black: return adjust.black * 100
        case .white: return adjust.white * 100
        }
    }

    /// Writes ONE value, in the readout's unit, and leaves the other three as they were.
    func setting(_ adjust: ToneAdjust, to value: Double) -> ToneAdjust {
        guard value.isFinite else { return adjust }
        let v = min(max(value, range.lowerBound), range.upperBound)
        var out = adjust
        switch self {
        case .exposure: out.exposure = -v * ToneAdjust.densityPerStop
        case .contrast: out.contrast = ToneAdjust.contrast(units: v)
        case .black: out.black = v / 100
        case .white: out.white = v / 100
        }
        return out
    }

    /// The four values a frame's tone runs: its own, or its preset's while it holds none.
    static func effective(_ develop: DevelopSettings) -> ToneAdjust {
        develop.toneAdjust ?? ToneAdjust.preset(for: develop.tone)
    }

    /// The edit one row makes to one frame. It starts from the frame's OWN effective values,
    /// so across a selection each frame keeps its other three, and `setToneAdjust` stores
    /// the result as nil when it lands back on the frame's preset.
    ///
    /// A sidecar with no develop layer comes back unchanged, as `ColourAxis.edit` does. The
    /// funnel has seeded one by the time an edit runs.
    func edit(_ sidecar: Sidecar, to value: Double) -> Sidecar {
        guard let develop = sidecar.develop else { return sidecar }
        let current = Self.effective(develop)
        let updated = setting(current, to: value)
        guard updated.normalised() != current.normalised() else { return sidecar }
        return SidecarEdits.setToneAdjust(sidecar, updated)
    }

    /// A double-click on the row: this value back to the frame's own preset's, the other
    /// three left where they are.
    func reset(_ sidecar: Sidecar) -> Sidecar {
        guard let develop = sidecar.develop else { return sidecar }
        return edit(sidecar, to: value(in: ToneAdjust.preset(for: develop.tone)))
    }

    /// A pick in the Tone control: that tone, at its own values. Picking the tone a frame
    /// already has clears its adjustment, which is how a person goes back to the preset.
    static func pick(_ sidecar: Sidecar, _ mode: ToneMode) -> Sidecar {
        guard var develop = sidecar.develop,
              develop.tone != mode || develop.toneAdjust != nil else { return sidecar }
        develop.tone = mode
        develop.toneAdjust = nil
        return SidecarEdits.setDevelop(sidecar, develop)
    }

    /// The readout. Two decimals for exposure and contrast; black and white in whole points,
    /// with one decimal only when a fine step left one, so a shifted nudge is never hidden.
    /// The `+ 0` cleans up negative zero, as the other rows do.
    func readout(_ v: Double) -> String {
        switch self {
        case .exposure, .contrast:
            return String(format: "%.2f", (v * 100).rounded() / 100 + 0)
        case .black, .white:
            let tenths = (v * 10).rounded() / 10 + 0
            return tenths == tenths.rounded() ? String(format: "%.0f", tenths) : String(format: "%.1f", tenths)
        }
    }

    /// The undo action name the four rows share, so a drag across them reads as one thing.
    static let actionName = "Tone Adjust"
}

/// The rule for when the four rows are on screen. The Tone title folds them (`DevelopRow`).
enum ToneAdjustRows {
    /// Shown while the remembered fold says so, and only then, edits or not. The lit Tone
    /// title is what says a selected frame carries its own values. Color and mono alike,
    /// and under every tone.
    static func shown(open: Bool) -> Bool { open }
}

/// One tone row: symbol, both end labels, a thumbless track whose fill grows from the
/// scale's neutral with a tick at the preset's value, and the value. The axis rows' idiom
/// (`ColourAxisRow`), double-click reset and click-to-type included.
struct ToneAdjustRow: View {
    let slider: ToneSlider
    let value: Double
    /// The preset's value, where a double-click returns and where the readout dims. The
    /// fill does not grow from it: it grows from `slider.neutral`.
    let origin: Double
    /// Where the preset's tick is drawn, nil for none (`ToneSlider.tick`).
    var tick: Double? = nil
    var isMultiple: Bool = false
    let onChange: (Double) -> Void
    let onEditing: (Bool) -> Void
    let onReset: () -> Void
    let onReleaseFocus: () -> Void

    @State private var typing: String?
    @State private var clicks = RowClicks()
    @State private var rowWidth: CGFloat = 0
    @FocusState private var fieldFocused: Bool
    @FocusState private var trackFocused: Bool

    @ViewBuilder private var readout: some View {
        if let typing {
            TextField("", text: Binding(get: { typing }, set: { self.typing = $0 }))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .focused($fieldFocused)
                .onSubmit { commit() }
                .onExitCommand { self.typing = nil; onReleaseFocus() }
                .onChange(of: fieldFocused) { _, focused in if !focused { commit() } }
                .onAppear {
                    trackFocused = false
                    DispatchQueue.main.async { fieldFocused = true }
                }
        } else if isMultiple {
            Text("Multiple")
                .foregroundStyle(.secondary)
        } else {
            Text(slider.readout(value))
                .foregroundStyle(slider.readout(value) == slider.readout(origin)
                                 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
    }

    private func commit() {
        defer { typing = nil }
        guard let text = typing, let parsed = Double(text.trimmingCharacters(in: .whitespaces)),
              parsed.isFinite else { return }
        // Clamped to the row's span: these are the value's whole legal range, not a zoom.
        onChange(min(max(parsed, slider.range.lowerBound), slider.range.upperBound))
    }

    private var track: some View {
        CentreOriginTrack(value: Binding(get: { value }, set: { onChange($0) }),
                          range: slider.range,
                          neutral: slider.neutral,
                          isEnabled: true,
                          onEditingChanged: { began in
                              if began { clicks.pressed(at: value) }
                              onEditing(began)
                          },
                          onReleaseFocus: onReleaseFocus,
                          keyStep: slider.keyStep,
                          isFocused: $trackFocused,
                          marks: tick.map { [$0] } ?? [])
    }

    private var trackHelp: String { isMultiple ? SliderHelp.mixed : SliderHelp.single }

    private func doubleClicked(at x: CGFloat) {
        guard typing == nil else { return }
        guard RowClicks.onReadout(x, width: rowWidth, readout: ColourAxisRow.readoutColumn) else {
            onReset()
            return
        }
        if isMultiple {
            typing = ""
            return
        }
        let before = clicks.valueBeforeClicks ?? value
        if before != value { onChange(before) }
        typing = slider.readout(before)
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                // The id on the TRACK, the one adjustable element, so Increment and Decrement
                // find it by name.
                track
                    .help(trackHelp)
                    .accessibilityIdentifier("tone.\(slider.id)")
                readout
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: ColourAxisRow.readoutColumn, alignment: .trailing)
                    .allowsHitTesting(typing != nil)
                    .accessibilityIdentifier("tone.\(slider.id).value")
            }
        } label: {
            // One line, always: the label keeps its width and the track gives it up.
            // "Dimmer ↔ Brighter" wrapped to two lines at the 360 pt inspector on the
            // screen check, the pitch problem the axis rows paid for in `ShellLayout`.
            Label(slider.label, systemImage: slider.symbol)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .help(slider.help)
                .accessibilityLabel(slider.accessibilityLabel)
        }
        .contentShape(Rectangle())
        .modifier(WidthReader(width: $rowWidth))
        .modifier(RowFocusWash(isFocused: trackFocused))
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { doubleClicked(at: $0.location.x) })
    }
}
