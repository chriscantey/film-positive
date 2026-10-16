import SwiftUI
import CoreGraphics
import FilmSidecar
import FilmPositiveCore

/// The crop half of the closeup.
///
/// There is no separate crop tool. `ViewerView` is the one closeup editor: it owns the
/// `CropEditor`, the control bar under the picture is always there, and the Crop toggle
/// swaps the picture for the rectangle without changing view.
///
/// This file holds the three pieces that belong to cropping rather than to the closeup:
/// the base render the rectangle is drawn over, the pane that draws it and feeds it
/// gestures, and the control bar. All the arithmetic stays in `CropEditor`, which is a
/// plain type with tests.

/// The uncropped, unstraightened render the crop rectangle is drawn over, plus what was
/// measured from it. Empty until the rectangle is switched on for a frame: a closeup that
/// is only being looked at never pays for a second render of the same picture.
struct CropBase {
    var image: CGImage?
    var decoded: DecodedFrame?
    /// Width over height of the RAW ORIGINAL frame, measured from the render. Nil until
    /// then, which is why `CropEditor` has to be built with a stand-in first.
    var originalAspect: CGFloat?
    var error: String?

    /// What the editor is built with before anything has been measured. Nothing that
    /// depends on it is reachable while `originalAspect` is nil: the rectangle is not on
    /// screen, and the two controls that would bake a wrong ratio in (the aspect list and
    /// Detect) are disabled. A quarter turn and a flip are aspect-free by construction, so
    /// they stay live and keep an existing crop exactly where it was.
    static let placeholderAspect: CGFloat = 1.5

    var isLoaded: Bool { decoded != nil }
}

/// What the crop rectangle is drawn over: the frame with the crop removed AND the
/// straighten removed.
///
/// Straighten is a view rotation here rather than a re-render: `Straighten.apply` keeps
/// the frame's dimensions, so the straightened picture occupies exactly the same box, and
/// turning the box on screen puts every pixel where the engine will put it. That keeps a
/// straightening drag at display rate instead of one full proxy render per degree.
///
/// Nil when the rectangle is off, which is what stops `.task(id:)` from rendering it.
func cropBaseRequest(for frame: Frame, wanted: Bool, develop effective: DevelopSettings?) -> RenderRequest? {
    guard wanted, let develop = effective else { return nil }
    let g = frame.sidecar.geometry ?? GeometrySettings()
    return RenderRequest(imageURL: frame.url, develop: develop,
                         geometry: GeometrySettings(rotate: g.rotate, flip: g.flip, straightenDegrees: 0, crop: nil),
                         enhance: frame.sidecar.enhance ?? .identity, scale: .proxy)
}

/// The picture with the rectangle over it: eight grips, a dimmed surround, a rule-of-thirds
/// grid that fades in while a straightening drag runs, and a rotate band outside the grips.
///
/// No background of its own: the viewer's own `textBackgroundColor` shows through.
struct CropPane: View {
    let frame: Frame
    @Binding var editor: CropEditor
    let base: CropBase
    @Binding var gridOpacity: Double
    /// The one write path: `model.apply` with a `SidecarEdits` transform.
    let commit: (String) -> Void
    /// A drag can move key focus off the closeup; its end puts it back.
    let dragEnded: () -> Void

    /// Grip target and rotate band, in points, converted to normalized per pane size.
    static let gripPoints: CGFloat = 11
    static let bandPoints: CGFloat = 26

    /// Where presses are taken from, in pane points: the picture grown by one grip target
    /// on every side, so a grip on the picture's edge is whole. The content shape below is
    /// this rectangle, and `CropGripReachTests` holds every grip's target inside it.
    static func hitArea(box: CGSize) -> CGRect {
        CGRect(origin: .zero, size: box).insetBy(dx: -gripPoints, dy: -gripPoints)
    }

    var body: some View {
        GeometryReader { geo in
            let box = fittedBox(in: geo.size)
            ZStack {
                if let image = base.image {
                    ZStack {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: box.width, height: box.height)
                            // The engine turns the picture clockwise for a positive angle
                            // and keeps the frame's dimensions, so the preview does the
                            // same and clips to the same box.
                            // Display degrees: the base image already has the mirror in
                            // it, so a mirrored frame leans the other way from its stored
                            // angle. See CropEditor.displayDegrees.
                            .rotationEffect(.degrees(editor.displayDegrees))
                            .frame(width: box.width, height: box.height)
                            .clipped()
                        CropOverlay(editor: editor, box: box, gridOpacity: gridOpacity)
                            .frame(width: box.width, height: box.height)
                            // Grown by the grip target on every side. With the crop at
                            // full frame every grip sits on the picture's edge, and a hit
                            // area the size of the picture would leave the outer half of each
                            // side grip and three quarters of each corner grip dead. What a
                            // press out here may do is decided in `CropEditor.begin`, which
                            // lets it take a grip and nothing else.
                            .contentShape(Rectangle().inset(by: -Self.gripPoints))
                            .gesture(dragGesture(box: box))
                    }
                    .frame(width: box.width, height: box.height)
                }
                if let error = base.error {
                    Text(error).font(.callout).foregroundStyle(.orange).padding()
                } else if base.image == nil && frame.sidecar.develop == nil {
                    ContentUnavailableView("No Positive Yet", systemImage: "film",
                                           description: Text("Develop this frame before cropping it."))
                } else if base.image == nil {
                    ProgressView()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func fittedBox(in size: CGSize) -> CGSize {
        let a = max(editor.displayAspect, 0.0001)
        var w = size.width, h = size.width / a
        if h > size.height { h = size.height; w = h * a }
        return CGSize(width: max(w, 1), height: max(h, 1))
    }

    private func dragGesture(box: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let p = CGPoint(x: value.location.x / box.width, y: value.location.y / box.height)
                if editor.session == nil {
                    editor.begin(at: p,
                                 tolerance: CGSize(width: Self.gripPoints / box.width, height: Self.gripPoints / box.height),
                                 rotateBand: CGSize(width: Self.bandPoints / box.width, height: Self.bandPoints / box.height))
                    if editor.isStraightening { showGrid() }
                }
                editor.drag(to: p)
            }
            .onEnded { _ in
                let straightening = editor.isStraightening
                let dragged = editor.isDragging
                editor.end()
                if dragged { commit(straightening ? "Straighten" : "Crop") }
                if straightening { hideGrid() }
                dragEnded()
            }
    }

    private func showGrid() { withAnimation(.easeIn(duration: 0.12)) { gridOpacity = 1 } }
    private func hideGrid() { withAnimation(.easeOut(duration: 0.45)) { gridOpacity = 0 } }
}

/// The bar under the picture. Always on screen in the closeup, whether the rectangle is
/// showing or not, because a quarter turn and a flip are things you want on a frame you are
/// only looking at.
struct CropControlBar: View {
    @Environment(AppModel.self) private var model
    @Binding var editor: CropEditor
    /// The base render has landed, so the frame's own shape is known. The aspect list
    /// needs that; nothing else in the bar does.
    let isMeasured: Bool
    let commit: (String) -> Void
    let detect: () -> Void
    /// Detect is NOT gated on the rectangle being up, because pressing it raises the
    /// rectangle itself. The caller gates it on a frame with a positive to measure and on
    /// the base render not being in flight, which are the only two states with nothing to
    /// find an edge in.
    let canDetect: Bool
    /// The thirds grid belongs to the pane, so the slider here asks for it through the
    /// same animation the pane's rotate band uses.
    @Binding var gridOpacity: Double
    /// Puts the keyboard back on the closeup, so the arrows walk the roll again after the
    /// straighten slider or its typed angle is done with (the zoom slider does the same).
    var returnFocus: () -> Void = {}
    /// Whether the angle field is open. The closeup's own key handler sits ABOVE this bar
    /// and SwiftUI offers it the field's keys too, so without this Return in the field would
    /// also put the crop rectangle away, and Escape would cancel the crop.
    var typingChanged: (Bool) -> Void = { _ in }

    /// The typed angle while the degrees readout is a field. Nil means it is a label.
    @State private var typingDegrees: String?
    @FocusState private var degreesFieldFocused: Bool

    /// There is no `AnyLabelStyle`, so the choice between a word and an icon on Detect and
    /// Reset has to be a branch over two concrete styles rather than a ternary over one.
    private struct BarLabel: ViewModifier {
        let compact: Bool
        @ViewBuilder func body(content: Content) -> some View {
            if compact { content.labelStyle(.iconOnly) } else { content.labelStyle(.titleOnly) }
        }
    }

    /// Two layouts, and `ViewThatFits` takes the roomy one whenever the center column can
    /// hold it. This is what lets `ShellLayout.contentMin` be 560 rather than the 790 the
    /// roomy bar alone would demand, and a 790 pt center column would push the window
    /// minimum to about 1340.
    ///
    /// Measured: the roomy bar's controls spanned 781 pt, from the Crop toggle at x=543 to
    /// the right edge of Reset at 1324, inside a center column running 611 to 1256. It hung
    /// 68 pt off each side and the toggle sat over the sidebar.
    ///
    /// The compact bar keeps every control and every tooltip. What it gives up is wording
    /// and air: Detect and Reset go to their icons (the rest of the bar is already
    /// `.iconOnly`), the three dividers go, the spacing halves, and the straighten slider
    /// and the aspect menu take their smaller minimums.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
        }
    }

    @ViewBuilder private func bar(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 14) {
            Toggle(isOn: Binding(get: { model.showsCropOverlay }, set: { _ in model.toggleCropOverlay() })) {
                Label("Crop", systemImage: "crop")
            }
            .toggleStyle(.button)
            .disabled(!model.canToggleCropOverlay)
            .help("Show the crop box (⌘K).")

            // Detect sits with the Crop toggle rather than out at the right, because it is
            // a crop action and nothing else, and its place makes that clear.
            //
            // It is a `Label` rather than a bare title so the compact bar can show the icon
            // alone: the bar's own `.labelStyle(.iconOnly)` has no purchase on a string.
            Button { detect() } label: {
                Label("Detect", systemImage: "viewfinder")
            }
            .modifier(BarLabel(compact: compact))
            .help("Find the film edge on this frame")
            .disabled(!canDetect)

            if !compact { Divider().frame(height: 18) }

            Button { editor.rotateCounterClockwise(); commit("Rotate Left") } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            .help("Turn the picture a quarter turn counter clockwise")
            Button { editor.rotateClockwise(); commit("Rotate Right") } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
            .help("Turn the picture a quarter turn clockwise")
            Button { editor.toggleFlip(); commit("Flip") } label: {
                Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .help("Flip the picture, for film scanned from the back.")

            if !compact { Divider().frame(height: 18) }

            // The ratio list, with Original chosen by default.
            Picker("Aspect", selection: Binding(
                get: { editor.aspect },
                set: { editor.setAspect($0); commit("Aspect Ratio") }
            )) {
                ForEach(CropAspect.allCases) { a in Text(a.name).tag(a) }
            }
            .labelsHidden()
            .frame(width: compact ? 92 : 120)
            .disabled(!isMeasured)
            .help("Lock the crop to a shape. Turn on the crop box first.")

            if !compact { Divider().frame(height: 18) }

            HStack(spacing: 6) {
                Image(systemName: "angle")
                Slider(value: straightenBinding, in: -FineRotation.limitDegrees...FineRotation.limitDegrees) { editing in
                    // The live turn and the thirds grid draw in the crop overlay, so
                    // the first touch shows the rectangle rather than moving a number alone.
                    if editing && !model.showsCropOverlay { model.toggleCropOverlay() }
                    if editing { showGrid() } else { hideGrid(); commit("Straighten"); returnFocus() }
                }
                .frame(minWidth: compact ? 56 : 130)
                // Double-click resets the angle to 0, as every inspector slider does. The
                // slider is AppKit underneath and swallows a tap gesture, so a monitor sees it.
                .background(DoubleClickMonitor { resetStraighten() })
                .help("Straighten. Double-click to reset.")
                degreesReadout
                    .monospacedDigit()
                    .frame(width: compact ? 42 : 52, alignment: .trailing)
            }

            Spacer(minLength: 8)

            Button {
                editor.clearCrop()
                editor.setDegrees(0)
                commit("Reset Crop")
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .modifier(BarLabel(compact: compact))
            .help("Clear the crop and the straighten angle")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func showGrid() { withAnimation(.easeIn(duration: 0.12)) { gridOpacity = 1 } }
    private func hideGrid() { withAnimation(.easeOut(duration: 0.45)) { gridOpacity = 0 } }

    /// The angle, and a field to type one into on a double click, the way the inspector's
    /// readouts do. Return or clicking away commits, Escape abandons, and a value that
    /// does not parse is dropped silently. Past 45 degrees either way it is held at 45.
    @ViewBuilder private var degreesReadout: some View {
        if let typingDegrees {
            // The setter only writes while the field is open. Closing the field makes the
            // TextField end editing, and ending editing pushes its text back through this
            // binding, which would re-open the value a moment after Escape cleared it: a
            // stderr trace reads `abandon typing=7` and then, 53 ms later, `commit typing=7`.
            // So a write after close is dropped.
            TextField("", text: Binding(get: { typingDegrees },
                                        set: { if self.typingDegrees != nil { self.typingDegrees = $0 } }))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .focused($degreesFieldFocused)
                .onSubmit { commitTypedDegrees() }
                .onExitCommand { abandonTypedDegrees() }
                // Escape abandons, as on the inspector's readouts. Caught ahead of dispatch,
                // because on screen the focus-loss commit ran first and took the typed value
                // (see `EscapeKeyMonitor`).
                .background(EscapeKeyMonitor { abandonTypedDegrees() })
                .onChange(of: degreesFieldFocused) { _, focused in if !focused { commitTypedDegrees() } }
                // One runloop turn late, or the field opens without a caret (see the
                // inspector readout's note on the same assignment).
                .onAppear { DispatchQueue.main.async { degreesFieldFocused = true } }
        } else {
            Text(degreesLabel)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    typingChanged(true)
                    typingDegrees = String(format: "%.2f", shownDegrees)
                }
                .help("Double-click to type an angle")
        }
    }

    private var shownDegrees: Double {
        FineRotation.isNegligible(editor.displayDegrees) ? 0 : editor.displayDegrees
    }

    private func commitTypedDegrees() {
        guard let text = typingDegrees else { return }
        typingDegrees = nil
        endTyping()
        defer { returnFocus() }
        guard let typed = CropModeKeys.parseDegrees(text) else { return }
        let before = editor.degrees
        editor.setDisplayDegrees(typed)
        if editor.degrees != before { commit("Straighten") }
    }

    private func abandonTypedDegrees() {
        guard typingDegrees != nil else { return }
        typingDegrees = nil
        endTyping()
        returnFocus()
    }

    /// One runloop turn late, so the keypress that closed the field (Return or Escape) is
    /// still seen as the field's by the closeup's handler, whichever of the two runs first.
    private func endTyping() { DispatchQueue.main.async { typingChanged(false) } }

    private func resetStraighten() {
        if typingDegrees != nil { typingDegrees = nil; endTyping() }
        editor.setDegrees(0)
        commit("Straighten")
        returnFocus()
    }

    private var straightenBinding: Binding<Double> {
        Binding(get: { editor.displayDegrees }, set: { editor.setDisplayDegrees($0) })
    }

    private var degreesLabel: String { Self.degreesText(editor.displayDegrees) }

    /// The angle readout, and the reason it is a function over a named `Double` instead of
    /// a ternary written inside the `String(format:)` call.
    ///
    /// `String(format:)` takes `CVarArg...`, so in `cond ? 0 : someDouble` both branches are
    /// coerced to that existential independently and the literal `0` is free to stay a
    /// `Swift.Int`. Every layout where the angle is negligible, which is every frame nobody
    /// has straightened, would then hand Foundation one Int against a `%.2f` and log a fault:
    /// String(format:locale:arguments:): Provided argument types ["Swift.Int"] (with
    /// inferred specifiers ["%lld"]) do not match the format string's specifiers. Seventeen
    /// a session. The straighten slider never fires it, because dragging makes the angle
    /// non-negligible. Opening the closeup, Command K, Reset and Flip all rebuild this bar
    /// with the angle at zero.
    ///
    /// Naming the type fixes it by construction: a `Double` cannot hold the Int.
    static func degreesText(_ degrees: Double) -> String {
        let shown: Double = FineRotation.isNegligible(degrees) ? 0 : degrees
        return String(format: "%.2f\u{00B0}", shown)
    }
}

// MARK: - the overlay

/// The rectangle, the dimmed surround, the eight grips and the rule-of-thirds grid.
/// Pure drawing over a box of `box` points: everything it needs is in the editor.
struct CropOverlay: View {
    let editor: CropEditor
    let box: CGSize
    let gridOpacity: Double

    private var rect: CGRect {
        let r = editor.displayRect
        return CGRect(x: r.minX * box.width, y: r.minY * box.height,
                      width: r.width * box.width, height: r.height * box.height)
    }

    /// The eight grips, in points, straight off `CropBox.handlePositions` so the drawing
    /// and the hit test can never disagree about where a grip is.
    private var gripCentres: [(CropBox.Handle, CGPoint)] {
        CropBox.handlePositions(in: editor.displayRect)
            .map { ($0.0, CGPoint(x: $0.1.x * box.width, y: $0.1.y * box.height)) }
    }

    var body: some View {
        ZStack {
            // Everything outside the crop, dimmed, drawn as one even-odd path so the
            // inside stays completely untinted.
            Path { p in
                p.addRect(CGRect(origin: .zero, size: box))
                p.addRect(rect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

            Rectangle()
                .path(in: rect)
                .stroke(Color.white.opacity(0.9), lineWidth: 1)

            thirds.opacity(gridOpacity)

            ForEach(gripCentres, id: \.0) { grip in
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 9, height: 9)
                    .shadow(radius: 1)
                    .position(grip.1)
            }
        }
        .allowsHitTesting(true)
    }

    /// Two lines each way inside the crop. Opacity is animated by the caller, so this
    /// fades in while a straightening drag runs and out when it ends.
    private var thirds: some View {
        Path { p in
            for i in 1...2 {
                let f = CGFloat(i) / 3
                let x = rect.minX + rect.width * f
                p.move(to: CGPoint(x: x, y: rect.minY))
                p.addLine(to: CGPoint(x: x, y: rect.maxY))
                let y = rect.minY + rect.height * f
                p.move(to: CGPoint(x: rect.minX, y: y))
                p.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.7), lineWidth: 0.75)
    }
}
