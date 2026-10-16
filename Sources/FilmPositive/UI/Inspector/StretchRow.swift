import SwiftUI
import FilmSidecar
import FilmPositiveCore

/// The Stretch row at the top of Tone's rows, and the rules it writes by.
///
/// The develop pass maps each frame's own densest green to white. A nearly blank negative
/// then has almost nothing stretched across the whole output and comes out milky and grainy.
/// Stretch sets how far that goes: Full (1, the rest) is the frame's own white, Off (0) is
/// the stock's normal white density, and between them the kernel blends geometrically
/// (`DevelopMath.stretchedGreenCeiling`). A frame that already reaches its stock's white is
/// never changed, so the control only darkens a thin frame.
///
/// Manual only. `SidecarEdits.setStretch` is its one writer and nothing automatic calls it.
/// The track runs in percent, and the fill runs from Off at the left edge to the value, as
/// on every other slider: a full bar at Full, half a bar at 50%, none at Off.
enum StretchControl {
    /// The track's span, in percent.
    static let range: ClosedRange<Double> = 0...100
    /// The rest, and where a double-click returns: Full.
    static let full: Double = 100
    /// The track's left end.
    static let off: Double = 0
    /// Where the drawn fill grows from: Off, so the bar reads as a level. Drawing only; the
    /// rest and the reset stay Full.
    static let fillOrigin: Double = off
    static let lowLabel = "Off"
    static let highLabel = "Full"
    static let symbol = "arrow.left.and.right"
    /// One arrow press is one percent; Shift is a tenth of that, as on every slider.
    static let keyStep: Double = 1
    /// The undo action name, the display name itself.
    static var actionName: String { ToneNames.stretch }
    /// The row's label: the name, then both ends.
    static var label: String { "\(ToneNames.stretch) \(lowLabel) \u{2194} \(highLabel)" }
    static var accessibilityLabel: String { "\(ToneNames.stretch), \(lowLabel) to \(highLabel)" }
    /// The row's hover help, in the tone rows' voice: what it does, and what it leaves alone.
    static let help = "Sets how far a thin negative is stretched to reach white. "
        + "It only ever darkens a thin frame and leaves a normal one alone."

    /// A frame's value in percent: its own, or Full while it holds none.
    static func value(_ develop: DevelopSettings) -> Double {
        (develop.stretch.map { min(max($0, 0), 1) } ?? 1) * 100
    }

    /// The readout: `Full` at rest, else a whole percent.
    static func readout(_ percent: Double) -> String {
        isFull(percent) ? highLabel : String(format: "%.0f%%", percent.rounded() + 0)
    }

    /// A value whose whole percent is 100 is Full. The edit stores it as nil and the readout
    /// says Full, so the two never disagree about a value just under the end.
    static func isFull(_ percent: Double) -> Bool {
        percent.rounded() >= full
    }

    /// The edit to one frame: `percent` clamped to the track, Full stored as nil. A frame
    /// already at that value comes back unchanged, so a selection edit touches only the
    /// frames it moves.
    static func edit(_ sidecar: Sidecar, to percent: Double) -> Sidecar {
        guard percent.isFinite, let develop = sidecar.develop else { return sidecar }
        let v = min(max(percent, range.lowerBound), range.upperBound)
        let stored: Double? = isFull(v) ? nil : v / 100
        guard stored != develop.stretch else { return sidecar }
        return SidecarEdits.setStretch(sidecar, stored)
    }

    /// A double-click on the row: back to Full, which removes the attribute.
    static func reset(_ sidecar: Sidecar) -> Sidecar {
        edit(sidecar, to: full)
    }

    /// A typed value: a number of percent, with or without the sign, or the word for Full.
    static func parse(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.caseInsensitiveCompare(highLabel) == .orderedSame { return full }
        if t.caseInsensitiveCompare(lowLabel) == .orderedSame { return range.lowerBound }
        let digits = t.hasSuffix("%") ? String(t.dropLast()).trimmingCharacters(in: .whitespaces) : t
        guard let v = Double(digits), v.isFinite else { return nil }
        return min(max(v, range.lowerBound), range.upperBound)
    }
}

/// The Stretch row: symbol, its name and both ends, a thumbless track whose fill runs from
/// Off at the left edge to the value, and the value. The tone rows' idiom (`ToneAdjustRow`), double-click
/// reset, click-to-type and Multiple included. Built beside it rather than by generalising
/// it, so the rows can change on their own.
struct StretchRow: View {
    /// Percent, 0...100.
    let value: Double
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
            Text(StretchControl.readout(value))
                .foregroundStyle(StretchControl.isFull(value)
                                 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
    }

    private func commit() {
        defer { typing = nil }
        guard let text = typing, let parsed = StretchControl.parse(text) else { return }
        onChange(parsed)
    }

    private var track: some View {
        CentreOriginTrack(value: Binding(get: { value }, set: { onChange($0) }),
                          range: StretchControl.range,
                          neutral: StretchControl.fillOrigin,
                          isEnabled: true,
                          onEditingChanged: { began in
                              if began { clicks.pressed(at: value) }
                              onEditing(began)
                          },
                          onReleaseFocus: onReleaseFocus,
                          keyStep: StretchControl.keyStep,
                          isFocused: $trackFocused)
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
        typing = StretchControl.isFull(before) ? "100" : String(format: "%.0f", before.rounded() + 0)
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                track
                    .help(trackHelp)
                    .accessibilityIdentifier("tone.stretch")
                readout
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: ColourAxisRow.readoutColumn, alignment: .trailing)
                    .allowsHitTesting(typing != nil)
                    .accessibilityIdentifier("tone.stretch.value")
            }
        } label: {
            Label(StretchControl.label, systemImage: StretchControl.symbol)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .help(StretchControl.help)
                .accessibilityLabel(StretchControl.accessibilityLabel)
        }
        .contentShape(Rectangle())
        .modifier(WidthReader(width: $rowWidth))
        .modifier(RowFocusWash(isFocused: trackFocused))
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { doubleClicked(at: $0.location.x) })
    }
}
