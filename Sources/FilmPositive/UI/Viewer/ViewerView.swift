import SwiftUI
import CoreGraphics
import FilmSidecar
import FilmPositiveCore

/// The closeup: one frame as large as the window allows, and the editor for it.
/// Opened from the grid with Return or a double click, closed with Done or Escape, and
/// left and right step to the previous and next frame in the folder's order, which is the
/// whole point of it: a gallery you walk through with the keyboard while the inspector
/// follows along.
///
/// It shows the developed positive when there is one, the negative thumbnail while a
/// render is in flight, and the negative alone for an undeveloped frame, which is the same
/// three states the grid cell has and for the same reason: the picture never blanks.
///
/// There is no separate crop tool. The control bar sits under the picture at all times and
/// the Crop toggle swaps the finished picture for the uncropped frame with the rectangle
/// over it. The toggle lives on the model, so it stays on while the arrows walk the roll and
/// crops can be adjusted frame after frame. One Done, and it goes to the grid.
struct ViewerView: View {
    /// Extra top padding in crop mode, on top of the picture's 24: the header capsule ends
    /// 44 points below the pane's top (measured), and a top grip needs its 11 point target
    /// clear of it, so the picture's top edge sits at 24 + 36 = 60, 5 points of air.
    static let cropHeaderClearance: CGFloat = 36

    @Environment(AppModel.self) private var model
    let frame: Frame
    let thumbnails: NegativeThumbnailCache

    @FocusState private var focused: Bool

    /// The crop state lives here rather than inside the overlay, because the control bar
    /// drives it whether the rectangle is showing or not: a quarter turn on a frame you are
    /// only looking at has to write the same geometry, with the frame's existing crop
    /// carried through untouched.
    @State private var editor = CropEditor(geometry: GeometrySettings(),
                                           originalAspect: CropBase.placeholderAspect)
    @State private var base = CropBase()
    @State private var gridOpacity: Double = 0
    @State private var holdKey = OriginalHoldKey()
    @State private var zoomAlias = ZoomKeyAlias()
    @State private var scrollPan = ScrollPan()
    /// The picture's box, inside the padding, which is the viewport the zoom works in.
    @State private var pictureViewport: CGSize = .zero
    /// The full resolution render the closeup draws once it is zoomed past the proxy's own
    /// pixels, with the request it answers so a stale one is never drawn.
    @State private var detail: DetailRender?
    /// A drag's translation at its last tick, so each tick pans by the difference.
    @State private var panLast: CGSize = .zero
    /// The scale a pinch started from.
    @State private var pinchStart: CGFloat?
    @Environment(\.displayScale) private var displayScale

    struct DetailRender {
        var request: RenderRequest
        var image: CGImage
    }
    /// Detect was pressed with the rectangle down. It raised the rectangle, and the base
    /// render that raising it starts consumes this flag at the end of its load. That is the
    /// whole mechanism: Detect is never disabled for the overlay being off, and the
    /// detection still runs against a measured base render rather than a stand-in.
    @State private var pendingDetect = false
    /// The shown frame's geometry when the crop rectangle came up on it, which is what
    /// Escape in crop mode puts back. Nil while the rectangle is down.
    @State private var cropEntry: CropModeKeys.Entry?
    /// The crop bar's angle field is open, so its keys are its own.
    @State private var typingAngle = false

    /// The raw negative the eyedropper aims at, decoded only while the mode is on.
    @State private var pickNegative = PickBaseNegative()

    /// What identifies that picture. Nil outside the mode, which is what releases it.
    private var pickNegativeKey: PickBaseNegative.Key? {
        guard model.isPickingBase else { return nil }
        return PickBaseNegative.Key(url: frame.url,
                                    geometry: PickBaseNegative.geometry(frame.sidecar.geometry))
    }

    private var display: (image: CGImage, isStale: Bool)? { model.renders.displayImage(for: frame) }
    private var state: FrameCellState { FrameCellState.of(frame: frame, hasImage: display != nil, isStale: display?.isStale ?? false) }

    /// Only rendered while the rectangle is up or the eyedropper is armed. A closeup that
    /// is only being looked at must not pay for a second proxy of the same frame.
    ///
    /// The eyedropper renders NOTHING here. It aims at the raw negative,
    /// which comes from `NegativeThumbnail` rather than from the engine, so arming it
    /// releases this render instead of asking for a second kind of it.
    private var baseRequest: RenderRequest? {
        if model.isPickingBase { return nil }
        // The frame's OWN develop layer, not the effective defaults: an undeveloped frame
        // must not render through the defaults for the crop rectangle either, so this
        // is nil there and the closeup draws the negative. The eyedropper above is the
        // deliberate exception, because picking the base IS how you develop a frame.
        return cropBaseRequest(for: frame, wanted: model.showsCropOverlay, develop: frame.sidecar.develop)
    }

    var body: some View {
        VStack(spacing: 0) {
            // The same full width bar the gallery carries. One view, one treatment, both
            // surfaces.
            if model.isPickingBase { PickBaseBar(text: model.pickBaseHeader) }
            picture
                .padding(24)
                // The header floats over the top of the picture. With the rectangle up on a
                // pane that is limited by its height, that would put the whole top edge, all
                // three of its grips and their targets, under the header's capsule, where no
                // press reaches them (measured with the sidebar hidden).
                // In crop mode the picture starts below the header plus one grip target.
                .padding(.top, model.showsCropOverlay ? Self.cropHeaderClearance : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(alignment: .top) { header }
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 10) {
                        // A restage keeps the previous positive with a small spinner in the
                        // corner, so a slider drag does not strobe a progress indicator
                        // across the image. The rectangle has its own loading state. The
                        // same spinner covers the full resolution render a zoom asks for.
                        if !model.showsCropOverlay, state == .restaging || loadingDetail {
                            ProgressView().controlSize(.small)
                        }
                        // Where the gallery keeps its thumbnail size slider.
                        if model.canZoomCloseup { zoomBar }
                    }
                    .padding(12)
                }
            Divider()
            CropControlBar(editor: $editor, isMeasured: base.isLoaded,
                           commit: commit, detect: detectAgain, canDetect: canDetect,
                           gridOpacity: $gridOpacity, returnFocus: { focused = true },
                           typingChanged: { typingAngle = $0 })
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        // A click on the rectangle, a header button or empty chrome can move key focus and
        // nothing else would re-assert it; the drag's end and every frame change do.
        .onChange(of: frame.id) { _, _ in focused = true }
        // Return in the folder list, or a control letting go, while the closeup is up:
        // the keyboard comes here, the closeup being where the gallery's keys live now.
        .onChange(of: model.focusGridRequest) { _, _ in
            focused = false
            DispatchQueue.main.async { focused = true }
        }
        .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
        // Hold M to see the original, release to come back. Caught by a local monitor
        // rather than `onKeyPress`, so it works whatever holds focus, a dragged slider
        // included. Repeats are swallowed: a held key sends one about every 30 ms, and a
        // repeat nobody handles reaches the system beep.
        .onAppear { holdKey.install { phase in hold(phase) } }
        .onAppear {
            zoomAlias.install {
                guard model.canZoomCloseup else { return false }
                model.zoomCloseupIn()
                return true
            }
            // Two fingers pan while zoomed and the pointer is over the picture.
            scrollPan.install { d in
                guard model.canZoomCloseup, !model.closeupZoom.isFit,
                      model.closeupPointer != nil else { return false }
                model.closeupZoom.pan(by: d)
                return true
            }
        }
        // Never stuck on: a release lost to a window switch, a frame change or leaving the
        // closeup all put the picture back.
        .onDisappear {
            holdKey.remove(); zoomAlias.remove(); scrollPan.remove()
            model.showsOriginal = false; model.endPickingBase()
            model.closeupZoom.forgetLayout(); model.closeupPointer = nil
        }
        // Original, Export and Done, and nothing else. Crop is not a place you go, so it is
        // a toggle in the bar and on Command K rather than a button that opens something.
        .toolbar {
            ToolbarItemGroup {
                // Press and hold, not a toggle: the picture comes back the moment the mouse
                // goes up, which is what makes it a comparison rather than a mode you can
                // forget you are in. A drag gesture of zero distance rather than a button
                // action, because a button only tells you about the click that completed.
                // A before-and-after split, which is what a press-and-hold peek IS.
                // `photo.on.rectangle` is the vocabulary macOS uses for a photo LIBRARY, so it
                // would read as "back to the gallery" two controls away from the Done button
                // that actually does that.
                //
                // The name resolves through `NSImage(systemSymbolName:)` on macOS 26.6.2.
                // `sparkles.slash` does NOT exist and would ship as a blank.
                //
                // Contrast uses `circle.lefthalf.filled`, which is also a half-filled glyph.
                // Different base shape (rectangle against circle) and different surfaces, the
                // closeup toolbar against an inspector row, so they are never adjacent. Worth
                // knowing before a third half-filled symbol is added anywhere near either.
                Button {} label: { Label("Original", systemImage: "rectangle.lefthalf.inset.filled") }
                    .help("Hold to see the original without Enhance (M)")
                    .simultaneousGesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in model.showsOriginal = true }
                        .onEnded { _ in model.showsOriginal = false })
                Button { model.showsExportSheet = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(!frame.isDeveloped)
                    .help(frame.isDeveloped ? "Export this frame" : "Develop first")
                Button("Done") { model.closeViewer() }
                    .help("Back to the grid (escape)")
            }
        }
        .navigationTitle(frame.stem)
        .navigationSubtitle(position)
        .task(id: baseRequest) { await loadBase() }
        // Keyed on the picture's identity, so it decodes once per frame and orientation and
        // is dropped the moment the mode ends or the arrows walk to another frame.
        .task(id: pickNegativeKey) { await loadPickNegative() }
        .task(id: detailRequest) { await loadDetail() }
        // What the zoom measures against. Nil whenever the finished picture is not what is
        // on screen, which greys the zoom items and puts the zoom back to fit.
        .onChange(of: zoomLayout, initial: true) { _, layout in
            if let layout { model.closeupZoom.update(layout: layout) } else { model.closeupZoom.forgetLayout() }
        }
        // A different frame: adopt its geometry at once, so the control bar is editing THIS
        // frame before (or without) the base render the rectangle needs, and drop the last
        // frame's render rather than drawing the rectangle over it.
        .onChange(of: frame.id, initial: true) { _, _ in
            base = CropBase()
            pendingDetect = false
            model.showsOriginal = false
            // A frame step goes back to fit: the next frame is a different picture,
            // and the place you were looking at in the last one means nothing in it.
            model.closeupZoom.reset()
            detail = nil
            adoptGeometry()
            noteCropEntry()
        }
        // The rectangle went away before the render it was waiting for landed, so the
        // detection it was going to run has nothing to show and is dropped.
        .onChange(of: model.showsCropOverlay) { _, shown in
            if !shown { pendingDetect = false }
            noteCropEntry()
        }
        // An undo, a redo or the inspector changed the geometry: adopt it, unless a drag is
        // in flight and would be fighting for the same state.
        .onChange(of: frame.sidecar.geometry) { _, _ in
            guard editor.session == nil else { return }
            adoptGeometry()
        }
    }

    // MARK: the picture

    @ViewBuilder
    private var picture: some View {
        if model.isPickingBase {
            // The eyedropper wins over the rectangle: both want the whole uncropped frame
            // and would be drawing over each other. `beginPickingBase` lowers the
            // rectangle, and this is the belt to that braces.
            PickBasePane(frame: frame, negative: pickNegative)
        } else if model.showsCropOverlay {
            CropPane(frame: frame, editor: $editor, base: base, gridOpacity: $gridOpacity,
                     commit: commit, dragEnded: { focused = true })
        } else {
            positive
        }
    }

    /// The shared right-click menu, on the picture and not on the crop pane: a right click
    /// inside the rectangle belongs to the rectangle.
    @ViewBuilder
    private var positive: some View {
        positiveImage
            .contextMenu { FrameContextMenu(frame: frame, site: .closeup) }
    }

    @ViewBuilder
    private var positiveImage: some View {
        ZStack {
            // Fills the picture's box, which is what the zoom measures and what the pointer
            // and the gestures are read over. Clear, so it draws nothing.
            Color.clear
                .onGeometryChange(for: CGSize.self) { $0.size } action: { pictureViewport = $0 }
            if state.showsPositive, let display {
                positiveLayer(display.image)
            } else if let negative = thumbnails.thumbnail(for: frame.url, geometry: frame.sidecar.geometry ?? GeometrySettings()) {
                Image(decorative: negative, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .opacity(state == .rendering ? 0.45 : 1)
                    .blur(radius: state == .rendering ? 2 : 0)
            } else if let failure = thumbnails.failure(for: frame.url) {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.title)
                    Text(failure).font(.callout).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding()
            }
            // Only the never-rendered case gets the big spinner over the whole picture.
            if state == .rendering { ProgressView().controlSize(.large) }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): model.closeupPointer = p
            case .ended: model.closeupPointer = nil
            }
        }
        // Drag pans, only while zoomed, so at fit a press on the picture is what it was.
        .gesture(panGesture, including: model.closeupZoom.isFit ? .subviews : .all)
        .simultaneousGesture(pinchGesture, including: model.canZoomCloseup ? .all : .subviews)
    }

    // MARK: zoom

    /// Fit draws exactly what the closeup always drew. Zoomed, the picture is drawn at its
    /// scaled size inside an overlay, so its size never feeds back into the pane's layout,
    /// and clipped to the picture's box.
    @ViewBuilder
    private func positiveLayer(_ proxy: CGImage) -> some View {
        if let size = model.closeupZoom.displaySize, !model.closeupZoom.isFit {
            Color.clear
                .overlay {
                    Image(decorative: detailImage ?? proxy, scale: 1)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .offset(model.closeupZoom.offset)
                }
                .clipped()
        } else {
            Image(decorative: proxy, scale: 1).resizable().scaledToFit()
        }
    }

    /// The zoom's measurements, or nil when the finished picture is not on screen. The
    /// frame's full resolution comes from the proxy's size and the scale it was rendered
    /// at, so a slider drag's quarter size preview reads as the same frame, not a smaller one.
    private var zoomLayout: CloseupZoom.Layout? {
        guard !model.showsCropOverlay, !model.isPickingBase, state.showsPositive, let display,
              pictureViewport.width > 0, pictureViewport.height > 0 else { return nil }
        let perSide: CGFloat
        switch model.renders.entry(for: frame.id)?.request.scale {
        case .preview?: perSide = 4
        case .full?: perSide = 1
        default: perSide = 2
        }
        return CloseupZoom.Layout(viewport: pictureViewport,
                                  imagePixels: CGSize(width: CGFloat(display.image.width) * perSide,
                                                      height: CGFloat(display.image.height) * perSide),
                                  backingScale: displayScale)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                model.closeupZoom.pan(by: CGSize(width: v.translation.width - panLast.width,
                                                 height: v.translation.height - panLast.height))
                panLast = v.translation
            }
            .onEnded { _ in panLast = .zero }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let start = pinchStart ?? model.closeupZoom.effectiveScale ?? 1
                pinchStart = start
                model.closeupZoom.set(scale: start * v.magnification, anchor: v.startLocation)
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// Fit at the left end, 100 percent at the right, snapping onto both. The gallery's
    /// size slider in the same corner, so the closeup's reads as the same control.
    private var zoomBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "minus.magnifyingglass").imageScale(.small).foregroundStyle(.secondary).frame(width: 14)
            Slider(value: Binding(get: { model.closeupZoom.sliderValue },
                                  set: { model.closeupZoom.setSlider($0) }),
                   in: 0...1,
                   // The arrows belong to the roll, so the closeup takes the keyboard back
                   // the moment the slider is let go.
                   onEditingChanged: { editing in if !editing { focused = true } })
                .frame(width: 100)
                .disabled(!model.closeupZoom.sliderEnabled)
                .help("Zoom. Left fits the frame, right is 100 percent")
            Image(systemName: "plus.magnifyingglass").imageScale(.small).foregroundStyle(.secondary).frame(width: 14)
        }
        .modifier(GalleryPill())
        .accessibilityLabel("Zoom")
    }

    /// A full resolution render, asked for only once the zoom enlarges the proxy.
    private var detailRequest: RenderRequest? {
        guard model.canZoomCloseup, model.closeupZoom.needsDetail else { return nil }
        return model.renders.request(for: frame, scale: .full)
    }

    /// The full render when it answers the current state, otherwise nil and the proxy is
    /// drawn enlarged until it lands.
    private var detailImage: CGImage? {
        guard let detail, detail.request == detailRequest else { return nil }
        return detail.image
    }

    private var loadingDetail: Bool { detailRequest != nil && detailImage == nil }

    /// Waits a quarter second first, so a slider drag or a run of ⌘+ presses asks for one
    /// full render at the end rather than one per tick. Zooming back to fit drops it, which
    /// is what releases the memory.
    private func loadDetail() async {
        guard let req = detailRequest else { detail = nil; return }
        if detail?.request == req { return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        do {
            let result = try await model.renders.service.render(req)
            guard !Task.isCancelled else { return }
            let image = try Exporter.cgImage(result.frame, tagged: ExportColorSpace.sRGB.cgColorSpace)
            detail = DetailRender(request: req, image: image)
        } catch {
            // The enlarged proxy stays on screen, which is a softer picture, not a wrong one.
        }
    }

    /// The closeup header's content height, pinned so nothing inside it can change the bar's
    /// height by appearing.
    ///
    /// The Original badge is `.caption` with 3 pt of padding above and below inside a
    /// Capsule, in a row whose other content is `.headline` and `.subheadline`. Measured with
    /// `NSHostingView.fittingSize` on macOS 26.6.2: the row is 16.0 without the badge and
    /// 19.0 with it. So the badge appearing would grow the row by 3 pt and everything in it
    /// would re-center downward by half of that, a visible jiggle (off a screen capture, the
    /// text centroid steps 75.26 to 76.40 px and back, with no animation).
    ///
    /// Pinned at the WITH-badge height on purpose. Pinning at 16 would squeeze the badge. The
    /// visible cost is that the bar is 3 pt taller at rest.
    ///
    /// A fixed height rather than trimming the badge's padding to match: trimming moves the
    /// same collision onto whatever is added to this bar next.
    static let headerContentHeight: CGFloat = 19

    private var header: some View {
        HStack(spacing: 12) {
            // Through `closeupStep`, not `navigate`: while the eyedropper is on, the arrows
            // walk the whole roll and leave the selection alone, so the frame being sampled
            // can sit outside the frames being written.
            Button { model.closeupStep(.left) } label: { Image(systemName: "chevron.left") }
                .help("Previous frame (left arrow)")
            Button { model.closeupStep(.right) } label: { Image(systemName: "chevron.right") }
                .help("Next frame (right arrow)")
            Text(frame.name).font(.headline).lineLimit(1).truncationMode(.middle)
            // What the pick is about to do is on the bar above the picture now, so the
            // header keeps saying where in the roll you are in every mode.
            Text(position).font(.subheadline).foregroundStyle(.secondary)
            // Unambiguous while held: the picture on screen is not the one the sidecar
            // describes, and nothing else on screen would say so.
            if model.showsOriginal {
                Text("Original")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(.white)
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        // The constraint that holds: no child may change this row's height, whatever is
        // added to it later.
        .frame(height: Self.headerContentHeight)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
    }

    /// "3 selected, showing 1 of 3" with several frames selected, "7 of 39" with one. The
    /// model owns the text so a test can assert it without a window.
    private var position: String { model.closeupPosition }

    // MARK: the crop state

    /// Rebuild the editor from what the sidecar actually holds. With no base render the
    /// aspect is a stand-in, which is safe: a quarter turn, a flip, the straighten angle and
    /// Reset never read it, and the two controls that would are disabled until it lands.
    private func adoptGeometry() {
        let adopted = CropEditor(geometry: frame.sidecar.geometry ?? GeometrySettings(),
                                 originalAspect: base.originalAspect ?? editor.originalAspect)
        if adopted.geometry != editor.geometry || adopted.originalAspect != editor.originalAspect {
            editor = adopted
        }
    }

    /// The negative the pick pane shows. The decode is a half size LibRaw read plus a
    /// reduction, hundreds of milliseconds, so it goes off the main actor and only the
    /// small bitmap comes back.
    private func loadPickNegative() async {
        guard let key = pickNegativeKey else { pickNegative = PickBaseNegative(); return }
        pickNegative = PickBaseNegative()
        let made = await Task.detached(priority: .userInitiated) { () -> Result<ThumbnailBitmap, Error> in
            do { return .success(try PickBaseNegative.make(key)) } catch { return .failure(error) }
        }.value
        guard !Task.isCancelled else { return }
        switch made {
        case .success(let bitmap):
            pickNegative = PickBaseNegative(image: NegativeThumbnail.image(bitmap),
                                            pixels: CGSize(width: bitmap.width, height: bitmap.height))
        case .failure(let error):
            pickNegative = PickBaseNegative(error: error.localizedDescription)
        }
    }

    private func loadBase() async {
        guard let req = baseRequest else { return }
        do {
            let result = try await model.renders.service.render(req)
            // The request belonged to a frame or a mode that has since gone: another load
            // owns `base` and `editor` now.
            guard !Task.isCancelled else { return }
            let f = result.frame
            let img = try Exporter.cgImage(f, tagged: ExportColorSpace.sRGB.cgColorSpace)
            let displayAspect = CGFloat(f.width) / CGFloat(max(f.height, 1))
            // The EDITOR's geometry, not the sidecar's. They agree except while a control is
            // mid-edit, and the one that is mid-edit when this lands is the straighten
            // slider: its first grab raises the rectangle, which starts this render, so the
            // render lands under the drag. Rebuilt from the sidecar it would put the stored
            // angle back under the pointer and the first drag would go nowhere. The editor was
            // adopted from the sidecar when the frame came up and on every undo since.
            let g = editor.geometry
            let turn = QuarterTurn(degrees: g.rotate) ?? .none
            let originalAspect = turn.swapsAxes ? 1 / displayAspect : displayAspect
            // Nothing detects on its own. Raising the rectangle on an uncropped frame
            // shows the whole frame with the box at its edges, and it stays there until
            // the user asks, with Detect Crop over the selection or Detect in the crop bar.
            var e = CropEditor(geometry: g, originalAspect: originalAspect)
            base = CropBase(image: img, decoded: f, originalAspect: originalAspect, error: nil)
            // Detect pressed with the rectangle down raised it and left this behind. The
            // frame is measured now, so run the same detection the button runs and commit
            // it through the same path.
            let wanted = pendingDetect
            pendingDetect = false
            if wanted, let found = detection(on: f) {
                e.seed(found)
                editor = e
                commitGeometry(e.geometry, actionName: "Detect Crop")
            } else {
                editor = e
            }
        } catch {
            base.error = "\(error)"
        }
    }

    /// The one write path: every change goes through `model.apply` with a
    /// `SidecarEdits` transform, which is what registers undo and schedules the save.
    private func commit(_ actionName: String) {
        commitGeometry(editor.geometry, actionName: actionName)
    }

    /// Named separately so the end of a load can commit the geometry it just built without
    /// reading it back out of the editor it is in the middle of replacing.
    private func commitGeometry(_ geometry: GeometrySettings, actionName: String) {
        model.apply({ SidecarEdits.setGeometry($0, geometry) }, to: frame.id, actionName: actionName)
    }

    /// Detect belongs to the crop overlay, so it raises the overlay when it is down rather
    /// than sitting disabled behind it.
    private var canDetect: Bool {
        // The detector reads the DEVELOPED frame, so there is nothing to read on a frame
        // nobody has pressed Positive on. Same gate the grid's Detect Crop carries.
        guard frame.isDeveloped else { return false }
        // With the rectangle down there is nothing in flight and nothing to wait for: the
        // press starts the render itself. With it up, a base render still loading is the
        // one state where there is genuinely nothing to measure yet.
        return model.showsCropOverlay ? base.isLoaded : true
    }

    private func detectAgain() {
        guard model.showsCropOverlay else {
            // Raise the rectangle and detect at the end of the base render that raising it
            // starts. A detection with nothing on screen would be invisible.
            pendingDetect = true
            model.toggleCropOverlay()
            if !model.showsCropOverlay { pendingDetect = false }
            return
        }
        guard let f = base.decoded, let found = detection(on: f) else { return }
        editor.seed(found)
        commit("Detect Crop")
    }

    /// What the detector makes of a decoded base render, already through the folder's
    /// learned scale. Nil when it found nothing worth seeding.
    private func detection(on decoded: DecodedFrame) -> CropEditor.Detection? {
        let g = frame.sidecar.geometry ?? GeometrySettings()
        let negative = (model.renders.service as? CPURenderService).flatMap { try? $0.negativeArm(for: frame.url, geometry: g) }
        let raw = AutoCrop.detect(in: decoded, expecting: model.expectedFilmSize, negative: negative)
        return model.applyLearnedScale(raw, folder: frame.url.deletingLastPathComponent())
    }

    // MARK: crop mode keys

    /// Remembers the shown frame's geometry the first time the rectangle is up on it, and
    /// forgets it when the rectangle goes down. A step to another frame with the rectangle
    /// still up takes a new snapshot, so Escape only ever restores the frame on screen.
    private func noteCropEntry() {
        guard model.showsCropOverlay else { cropEntry = nil; return }
        if cropEntry?.frameID != frame.id {
            cropEntry = CropModeKeys.Entry(frameID: frame.id, geometry: frame.sidecar.geometry)
        }
    }

    private func leaveCropMode(_ action: CropModeKeys.Action) {
        if action == .cancel, let entry = cropEntry,
           let restored = entry.restoring(frame.sidecar.geometry, on: frame.id) {
            // One undo step, and the geometry observer adopts it into the editor.
            model.apply({ SidecarEdits.setGeometry($0, restored) }, to: frame.id, actionName: "Cancel Crop")
        }
        if model.showsCropOverlay { model.toggleCropOverlay() }
        focused = true
    }

    // MARK: keys

    /// M down shows the original, M up puts it back, and every repeat in between is
    /// handled and does nothing, so holding the key is one press and one release however
    /// long it is held, and silent.
    private func hold(_ phase: KeyPress.Phases) -> Bool {
        guard editor.session == nil else { return false }
        switch Self.originalHold(phase) {
        case .show: model.showsOriginal = true
        case .hide: model.showsOriginal = false
        case .swallow: break
        case .notOurs: return false
        }
        return true
    }

    enum OriginalHold: Equatable { case show, hide, swallow, notOurs }

    /// What one phase of the M key does. Pure so the repeat rule is testable.
    static func originalHold(_ phase: KeyPress.Phases) -> OriginalHold {
        if phase == .down { return .show }
        if phase == .up { return .hide }
        if phase == .repeat { return .swallow }
        return .notOurs
    }

    /// Left and right step frames, up and down do the same so a hand on either pair works,
    /// Home and End jump to the first and last, Escape goes back to the grid. A drag in
    /// flight is left alone. Everything else is handed to the system.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // A drag in flight owns the geometry, and an open angle field owns the keys: SwiftUI
        // offers this handler the keys of every focused view under it, the field included.
        guard editor.session == nil, !typingAngle else { return .ignored }
        // With the rectangle up, Return keeps the crop and Escape puts it back, and
        // both put the rectangle away without leaving the closeup.
        if let action = CropModeKeys.action(for: press.key, showsCrop: model.showsCropOverlay && !model.isPickingBase,
                                            dragging: editor.session != nil) {
            leaveCropMode(action)
            return .handled
        }
        let move: GridNavigation<Frame.ID>.Move
        switch press.key {
        case .leftArrow, .upArrow: move = .left
        case .rightArrow, .downArrow: move = .right
        case .home: move = .first
        case .end: move = .last
        case .escape:
            // A bulk wand run started from the closeup stops first, as in the grid,
            // and the closeup stays open.
            if model.enhanceRunning { model.stopRun(); return .handled }
            // Escape leaves the eyedropper before it leaves the closeup, so one press
            // cancels the tool rather than throwing the user back to the grid.
            if model.isPickingBase { model.endPickingBase() } else { model.closeViewer() }
            return .handled
        case .space:
            // Space goes back to the grid, the other half of the grid's Space.
            let a = SpaceToggle.action(phase: press.phase, inCloseup: true, pickingBase: model.isPickingBase)
            if a == .close { model.closeViewer() }
            return a == .notOurs ? .ignored : .handled
        default: return .ignored
        }
        // One column: in a closeup every step is one frame, whatever the grid's layout is.
        return model.closeupStep(move) ? .handled : .ignored
    }
}
