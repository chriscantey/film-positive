import SwiftUI
import AppKit
import FilmSidecar

/// The middle column: every frame of the selected folder in its current state, a negative
/// before develop and the positive after, with Finder selection and Develop acting on the
/// selection alone.
struct GridView: View {
    @Environment(AppModel.self) private var model

    /// Cell width in points. A view preference, kept out of the sidecar and out of
    /// `Preferences` so nothing per image is involved.
    @AppStorage("FilmPositive.grid.cellWidth") private var cellWidth: Double = 200
    /// Owned by the window and shared with the viewer, so stepping from the grid into the
    /// viewer never decodes the same negative twice.
    let thumbnails: NegativeThumbnailCache
    /// The grid takes key focus so the arrow keys reach it. A SwiftUI grid has
    /// no first responder of its own, which is why Command A lives on the Edit menu's
    /// Select All item rather than on a control in this view.
    @FocusState private var focused: Bool
    /// Content width, so a row step moves by the number of columns actually drawn.
    @State private var contentWidth: Double = 0
    @State private var holdKey = OriginalHoldKey()
    /// Height of the scroll view, so the empty-space deselect target reaches the bottom of
    /// the window even when the grid holds two rows.
    @State private var viewportHeight: CGFloat = 0
    /// The one loupe's state while the eyedropper is armed over the grid.
    /// Owned here rather than per cell so the magnifier is never clipped by a thumbnail.
    @State private var pickHover = GalleryPickHover()
    /// The scroll content's size, so the loupe can be kept inside it.
    @State private var contentSize: CGSize = .zero
    /// How far the gallery is scrolled down, read from the content's frame in the
    /// ScrollView's own space.
    @State private var scrollOffset: Double = 0
    private static let minCell: Double = 110
    private static let maxCell: Double = 420
    private static let spacing: Double = 16
    private static let padding: Double = 16
    /// The scroll content's coordinate space, which the loupe is positioned in.
    static let gridSpace = "grid"
    static let scrollSpace = "gallery.scroll"

    /// Leaving the gallery pick mode from the grid: the loupe goes with it.
    private func leavePickMode() {
        model.endPickingBase()
        pickHover.clear()
    }

    var body: some View {
        Group {
            if let folder = model.selectedFolder {
                grid(folder)
                    .navigationTitle(folder.name)
                    .navigationSubtitle(subtitle(folder))
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focused)
                    // Not while the folder list holds the keyboard: coming back from
                    // the closeup after a folder click must not take the arrows off the list.
                    .onAppear { if SidebarFocus.galleryTakesFocus(sidebarHasKeyboard: model.sidebarHasKeyboard) { focused = true } }
                    // The gallery took the keyboard by any route, a click included, so the
                    // folder list no longer holds it.
                    .onChange(of: focused) { _, now in if now { model.sidebarHasKeyboard = false } }
                    // A control handed the keyboard back. Clearing its own focus only sends
                    // focus to the window, where the arrow keys reach nothing, so the grid has
                    // to take it rather than wait to inherit it.
                    //
                    // FALSE FIRST, then true on the next runloop turn, and both halves are
                    // needed. `focused` is this view's own `FocusState` and SwiftUI does
                    // not reliably write it back to false when a control in the inspector
                    // takes the keyboard, so a bare `focused = true` assigns true to something
                    // already true, requests no responder change, and does nothing at all.
                    // Measured: Escape released the track, focus landed on the AXWindow, and
                    // the arrows drove neither the slider nor the gallery.
                    //
                    // Same shape as the readout field's focus: a focus assignment that is
                    // dropped because nothing about it is a change.
                    .onChange(of: model.focusGridRequest) { _, _ in
                        focused = false
                        DispatchQueue.main.async { focused = true }
                    }
                    .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
                    // Hold M, as in the closeup, over the selection. The same local
                    // monitor, so a slider holding focus does not swallow it.
                    .onAppear { holdKey.install { phase in holdOriginal(phase) } }
                    .onDisappear { holdKey.remove(); model.showsOriginal = false }
            } else {
                if model.folders.isEmpty {
                    // The ONE empty state of an empty window, and the only one that carries
                    // a verb. The sidebar and the inspector say nothing, because three
                    // placeholders at three heights read as clutter. The button is inside it
                    // so the thing to do and the place it is described are the same object.
                    ContentUnavailableView {
                        Label("Add a Folder of Scans", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("Raw scans from your camera, one folder per roll.")
                    } actions: {
                        Button("Add Folder…") { model.presentAddFolder() }
                    }
                } else {
                    ContentUnavailableView("No Folder Selected", systemImage: "photo.on.rectangle.angled",
                                           description: Text("Choose one in the sidebar."))
                }
            }
        }
        .toolbar { toolbar }
        .onChange(of: model.selectedFolderID) { _, _ in
            // A different roll is a different selection. The model clears it inside the
            // folder change itself, because this view is not mounted while the closeup is
            // up and a clear that lived here would never run from there.
            // A folder chosen in the sidebar leaves the keyboard there, so the arrows
            // walk the folder list the way Finder's sidebar does. A folder chosen any other
            // way (added, dropped) still hands the keyboard to the gallery.
            if SidebarFocus.galleryTakesFocus(sidebarHasKeyboard: model.sidebarHasKeyboard) { focused = true }
        }
    }

    /// The closeup's hold rule, pointed at the gallery.
    private func holdOriginal(_ phase: KeyPress.Phases) -> Bool {
        switch ViewerView.originalHold(phase) {
        case .show: model.holdOriginalInGallery()
        case .hide: model.showsOriginal = false
        case .swallow: break
        case .notOurs: return false
        }
        return true
    }

    /// Arrow keys, Home and End move the selection, and Return opens the viewer.
    /// Anything else is handed back to the system, so type-ahead and menu keys still work.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let extend = press.modifiers.contains(.shift)
        let columns = GridNavigation<Frame.ID>.columns(width: contentWidth, cellWidth: cellWidth,
                                                       spacing: Self.spacing, padding: Self.padding)
        let move: GridNavigation<Frame.ID>.Move
        switch press.key {
        case .leftArrow: move = .left
        case .rightArrow: move = .right
        case .upArrow: move = .up
        case .downArrow: move = .down
        case .home: move = .first
        case .end: move = .last
        // One screen of rows, the rows wholly on screen now.
        case .pageUp: move = .pageUp(rows: model.galleryVisibleRows)
        case .pageDown: move = .pageDown(rows: model.galleryVisibleRows)
        case .return: model.openViewer(); return .handled
        case .space:
            // Space opens the closeup, as Return does. `SpaceToggle` owns the repeat rule.
            let a = SpaceToggle.action(phase: press.phase, inCloseup: false, pickingBase: false)
            if a == .open { model.openViewer() }
            return a == .notOurs ? .ignored : .handled
        // Escape is the standard deselect on macOS, and it works wherever the grid has
        // focus. Command Shift A does the same from the menu for people who look there.
        case .escape:
            // A bulk wand run goes first. Escape stops it (`stopRun`) and does
            // nothing else, so the selection the run is working through stays selected.
            if model.enhanceRunning { model.stopRun(); return .handled }
            // The eyedropper goes before the selection does, so one press cancels a pick
            // that was armed by accident without also throwing away the frames it was
            // about to write to.
            if model.isPickingBaseInGallery { leavePickMode(); return .handled }
            guard !model.selection.isEmpty else { return .ignored }
            deselectAll()
            return .handled
        default: return .ignored
        }
        return model.navigate(move, columns: columns, extend: extend) ? .handled : .ignored
    }

    /// Rows that fit whole in the viewport, from the measured content height. Kept on the
    /// model so the rebuilt grid knows what the old one showed.
    private func noteVisibleRows(_ folder: FolderSession) {
        let columns = GridNavigation<Frame.ID>.columns(width: contentWidth, cellWidth: cellWidth,
                                                       spacing: Self.spacing, padding: Self.padding)
        let rows = GalleryReturn.visibleRows(
            viewport: viewportHeight, content: contentSize.height,
            frames: folder.frames.count, columns: columns,
            padding: Self.padding, spacing: Self.spacing)
        // Both are written only on a change: this runs on every scroll tick.
        if model.galleryVisibleRows != rows { model.galleryVisibleRows = rows }
        let full = GalleryReturn.fullyVisibleRows(
            offset: scrollOffset, viewport: viewportHeight, content: contentSize.height,
            frames: folder.frames.count, columns: columns,
            padding: Self.padding, spacing: Self.spacing)
        if model.galleryFullRows != full { model.galleryFullRows = full }
    }

    /// Arrowing inside the closeup moves the cursor, so the frame the user comes back on may
    /// not be in the rows the gallery reopens on. Only then does the gallery move, centering
    /// it.
    private func revealCursorAfterCloseup(_ folder: FolderSession, scroller: ScrollViewProxy) {
        guard let cursor = model.cursor, let top = model.galleryTopFrameID,
              let c = folder.frames.firstIndex(where: { $0.id == cursor }),
              let t = folder.frames.firstIndex(where: { $0.id == top }) else { return }
        let columns = GridNavigation<Frame.ID>.columns(width: contentWidth, cellWidth: cellWidth,
                                                       spacing: Self.spacing, padding: Self.padding)
        guard GalleryReturn.needsScroll(cursor: c, top: t, columns: columns,
                                        visibleRows: model.galleryVisibleRows) else { return }
        DispatchQueue.main.async { scroller.scrollTo(cursor, anchor: .center) }
    }

    /// One owner for clearing, in the model, so the menu item and the three gestures here
    /// cannot drift apart.
    private func deselectAll() { model.deselectAllInView() }

    private func subtitle(_ folder: FolderSession) -> String {
        Self.subtitle(frames: folder.frames.count, selected: model.selection.count)
    }

    /// The positive count lives in the pill at the top left of the gallery, so the window
    /// subtitle carries only the selection, and nothing when nothing is selected. An empty
    /// folder still says so, which is not a count.
    static func subtitle(frames: Int, selected: Int) -> String {
        guard frames > 0 else { return "No raw files" }
        return selected == 0 ? "" : "\(selected) selected"
    }

    private func grid(_ folder: FolderSession) -> some View {
        @Bindable var model = model
        return ScrollViewReader { scroller in
            ScrollView {
                // The deselect target has to live INSIDE the ScrollView, behind the grid.
                // A ScrollView consumes taps across its whole area, so a target behind the
                // ScrollView itself never gets the click. Filling to the viewport height means
                // the space BELOW the last row works too, not just the gaps between cells.
                ZStack(alignment: .top) {
                    Color(nsColor: .textBackgroundColor)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if model.isPickingBaseInGallery { leavePickMode() } else { deselectAll() }
                        }
                        .frame(minHeight: viewportHeight)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: cellWidth), spacing: Self.spacing)],
                          alignment: .leading, spacing: Self.spacing) {
                    ForEach(folder.frames) { frame in
                        FrameCell(frame: frame, thumbnails: thumbnails,
                                  isSelected: model.selection.contains(frame.id),
                                  isCursor: model.cursor == frame.id,
                                  pickHover: pickHover)
                            .id(frame.id)
                            .contentShape(Rectangle())
                            // While the eyedropper is armed over the grid the cell's own
                            // click handlers are OFF, all of them. A pick and a selection
                            // change are two different meanings for one click, and the
                            // mode decides which is in force: the cell's own overlay owns
                            // the click, and it samples rather than selects.
                            .onTapGesture(count: 2) {
                                guard !model.isPickingBaseInGallery else { return }
                                model.openViewer(on: frame.id)
                            }
                            .onTapGesture {
                                guard !model.isPickingBaseInGallery else { return }
                                click(frame.id)
                            }
                            .contextMenu { FrameContextMenu(frame: frame) }
                    }
                }
                .scrollTargetLayout()
                .padding(Self.padding)
                .background(GeometryReader { geo in
                    Color.clear.onAppear { contentWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in contentWidth = w }
                })
                }
                .background(GeometryReader { geo in
                    Color.clear.onAppear { contentSize = geo.size }
                        .onChange(of: geo.size) { _, size in contentSize = size; noteVisibleRows(folder) }
                        .onChange(of: geo.frame(in: .named(Self.scrollSpace)).minY, initial: true) { _, y in
                            scrollOffset = -y
                            noteVisibleRows(folder)
                        }
                })
                // ONE loupe, over the whole scroll content. A per cell magnifier would be
                // clipped by its own thumbnail and painted over by the next row.
                .overlay(alignment: .topLeading) {
                    if model.isPickingBaseInGallery {
                        GalleryPickLoupe(hover: pickHover, thumbnails: thumbnails,
                                         content: contentSize)
                    }
                }
                .coordinateSpace(.named(Self.gridSpace))
            }
            .coordinateSpace(.named(Self.scrollSpace))
            .background(GeometryReader { geo in
                Color.clear.onAppear { viewportHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, h in viewportHeight = h; noteVisibleRows(folder) }
            })
            // The gallery keeps its place across the closeup. Leaving the closeup rebuilds
            // this ScrollView, which would otherwise land at the top every time. The frame
            // at the top lives on the model, so the rebuilt view opens on the same rows.
            .scrollPosition(id: $model.galleryTopFrameID, anchor: .top)
            .onAppear { revealCursorAfterCloseup(folder, scroller: scroller) }
            // Keyed on an explicit REQUEST, not on the cursor. Keyboard navigation asks for
            // this when a step leaves the rows on screen, and duplicating asks to show the
            // result. No click ever does, so the grid stays where the user put it.
            .onChange(of: model.scrollRequest) { _, request in
                guard let request else { return }
                let anchor: UnitPoint = switch request.placement {
                case .center: .center
                case .top: .top
                case .bottom: .bottom
                }
                withAnimation(.easeOut(duration: 0.12)) { scroller.scrollTo(request.id, anchor: anchor) }
            }
        }
        .overlay {
            if folder.frames.isEmpty {
                ContentUnavailableView("No Raw Files", systemImage: "film",
                                       description: Text("\(folder.name) holds no raw files at its top level."))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // There is no pick pane in the grid, so this line is the only thing that says
            // the next click will measure film rather than select a frame, and how many
            // frames it is about to write.
            // This column only, not the window and not the split view.
            if model.isPickingBaseInGallery {
                PickBaseBar(text: model.pickBaseHeader)
            } else if !folder.frames.isEmpty {
                // Where the roll stands, top left of the gallery. The window subtitle
                // carries it too, but the inspector's title wins that slot whenever a frame
                // is selected, which is nearly always.
                HStack {
                    Text(Self.positiveCount(folder))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .modifier(GalleryPill())
                        .accessibilityIdentifier("gallery.count")
                    Spacer()
                }
                .padding(.leading, Self.padding)
                .padding(.vertical, 6)
            }
        }
        // Bottom right of the gallery column, in a transparent strip of its own: no rule, no
        // bar, and nothing across the sidebar's foot. A control inside the title row cannot be
        // clicked: that strip is the window's drag region.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                zoomBar
            }
            .padding(.trailing, Self.padding)
            .padding(.vertical, 6)
        }
    }

    /// One group at the top right of the window, the same place the closeup view keeps its
    /// own bar. The thumbnail size slider sits in the column itself, see `zoomBar`.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // The size slider is not a toolbar item. `.automatic` lands past the inspector
        // divider on macOS 26 and `.principal` centers it in the window, and neither is in
        // the gallery column. It sits in a strip at the column's bottom right instead, see
        // the bottom inset in `grid(_:)`.
        ToolbarItemGroup(placement: .primaryAction) {
            // Export is the only item here. Select All is an Edit menu item and Positive is
            // the prominent button in the inspector, so the bar carries the one action that
            // leaves the app rather than several that edit inside it.
            //
            // Export acts over the selection. Select All then Export is how a whole roll
            // goes out.
            //
            // The inspector carries a second Export button at its bottom right, the same
            // view, so the two cannot disagree about what they do.
            ExportButton(place: .toolbar)
        }
    }

    /// Thumbnail size. Both glyphs get the same fixed box because `photo` and `photo.fill`
    /// differ in intrinsic width, which would leave the capsule with uneven margins.
    private var zoomBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo").imageScale(.small).foregroundStyle(.secondary).frame(width: 14)
            Slider(value: $cellWidth, in: Self.minCell...Self.maxCell)
                .frame(width: 100)
                .help("Thumbnail size")
            Image(systemName: "photo.fill").imageScale(.small).foregroundStyle(.secondary).frame(width: 14)
        }
        .modifier(GalleryPill())
        .accessibilityLabel("Thumbnail size")
    }

    /// "12 of 36 developed", or "All developed", the words the sidebar row uses.
    static func positiveCount(_ folder: FolderSession) -> String {
        let developed = folder.frames.filter(\.isDeveloped).count
        return developed == folder.frames.count ? "All developed" : "\(developed) of \(folder.frames.count) developed"
    }

    /// One click, resolved through the pure selection rules. The modifier state comes from
    /// AppKit rather than from a stack of modifier qualified tap gestures, because that is
    /// the OS's own answer and it cannot disagree with what the user is holding.
    private func click(_ id: Frame.ID) {
        model.selectByClick(id, modifiers: Self.modifiersNow())
        focused = true
    }

    private static func modifiersNow() -> GridSelection<Frame.ID>.Modifiers {
        let flags = NSEvent.modifierFlags
        var modifiers: GridSelection<Frame.ID>.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}

/// One frame. The negative thumbnail is the base layer in every state, so developing or
/// resetting never leaves an empty rectangle and the change from negative to positive is
/// the whole animation.
struct FrameCell: View {
    @Environment(AppModel.self) private var model
    let frame: Frame
    let thumbnails: NegativeThumbnailCache
    let isSelected: Bool
    /// The keyboard cursor. It is drawn even when the frame is one of many selected, so a
    /// shift extend shows which end the next arrow moves.
    var isCursor: Bool = false
    /// The grid's one loupe. Nil outside the grid.
    var pickHover: GalleryPickHover?

    /// Whether this cell is currently an eyedropper target.
    private var picking: Bool { pickHover != nil && model.isPickingBaseInGallery }

    /// The geometry the pick works in, and therefore the geometry the cell DRAWS in while
    /// the mode is on: turn and mirror, no crop and no straighten. A cropped positive is a
    /// picture of the part of the frame the film base is not in, so sampling one would aim
    /// at a region the picture no longer contains.
    private var pickGeometry: GeometrySettings { GalleryPick.pickGeometry(frame.sidecar.geometry) }

    private var display: (image: CGImage, isStale: Bool)? { model.renders.displayImage(for: frame) }
    private var state: FrameCellState { FrameCellState.of(frame: frame, hasImage: display != nil, isStale: display?.isStale ?? false) }

    var body: some View {
        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                picture
                if state.isWorking {
                    ProgressView().controlSize(.small)
                }
                if picking, let pickHover {
                    // The hover and the click both live on one overlay that fills the
                    // picture box, so the point they read and the box the loupe is
                    // positioned against are the same rectangle by construction.
                    GeometryReader { proxy in
                        pickSurface(proxy: proxy, hover: pickHover)
                    }
                }
                // Bulk crop detection is on this frame right now. A small spinner in the
                // corner rather than a dimmed overlay with a word on it: the crop itself
                // lands on the cell the moment it is found, so the picture underneath is the
                // thing to watch and the spinner only says which one is being worked.
                // A bulk wand or Neutralize run marks the frame it is reading the same way.
                if model.autoCropping == frame.id || model.enhanceReading == frame.id {
                    ProgressView()
                        .controlSize(.small)
                        .padding(5)
                        .background(.regularMaterial, in: Circle())
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .aspectRatio(3 / 2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isCursor ? Color.primary.opacity(0.7) : Color.clear, lineWidth: 1)
                    .padding(1.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)

            Text(frame.stem)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
        // No tooltip while the gallery eyedropper is on: the loupe already names the
        // ratios, and the file name would pop up beside it after the hover delay. An empty
        // help string is no tooltip at all.
        .help(model.isPickingBaseInGallery ? "" : frame.name)
        .accessibilityLabel("\(frame.name), \(frame.isDeveloped ? "developed" : "not yet developed")")
    }

    /// The hover and click surface, in the picture box's own coordinates.
    private func pickSurface(proxy: GeometryProxy, hover: GalleryPickHover) -> some View {
        let box = proxy.size
        let image = thumbnails.thumbnail(for: frame.url, geometry: pickGeometry)
        let aspect = image.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1.5
        let pixels = image.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: 3, height: 2)
        return Color.clear
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p):
                    guard let point = GalleryPick.displayPoint(p, box: box, aspect: aspect) else {
                        hover.left(frame.id)
                        return
                    }
                    hover.moved(to: .init(frame: frame.id, url: frame.url, stem: frame.stem,
                                          geometry: pickGeometry,
                                          box: proxy.frame(in: .named(GridView.gridSpace)),
                                          aspect: aspect, pixels: pixels, point: point),
                                service: model.renders.service)
                case .ended:
                    hover.left(frame.id)
                }
            }
            // A spatial tap, because the click has to carry WHERE it landed. A plain tap
            // gesture carries no location and would have to reuse the last hover, which is
            // a different event and can be stale.
            .gesture(SpatialTapGesture().onEnded { value in
                guard let point = GalleryPick.displayPoint(value.location, box: box,
                                                           aspect: aspect) else { return }
                let geometry = pickGeometry
                let url = frame.url
                Task { await model.pickFromGallery(url: url, geometry: geometry, at: point) }
            })
            .onDisappear { hover.left(frame.id) }
    }

    @ViewBuilder
    private var picture: some View {
        if picking {
            // The NEGATIVE, even on a frame that is already positive: the base is measured
            // off the film, and the loupe has to magnify the same picture the sample reads.
            if let negative = thumbnails.thumbnail(for: frame.url, geometry: pickGeometry) {
                Image(decorative: negative, scale: 1).resizable().scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
        } else if state.showsPositive, let display {
            // A stale positive is drawn at full strength, not dimmed. Dimming it would be
            // the same mistake as showing the negative, one notch quieter: the frame is
            // correct, it is one edit behind, and the spinner already says so.
            Image(decorative: display.image, scale: 1).resizable().scaledToFit()
        } else if let negative = thumbnails.thumbnail(for: frame.url, geometry: frame.sidecar.geometry ?? GeometrySettings()) {
            Image(decorative: negative, scale: 1)
                .resizable()
                .scaledToFit()
                .opacity(state == .rendering ? 0.45 : 1)
        } else if let failure = thumbnails.failure(for: frame.url) {
            VStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle").font(.title3)
                Text(failure).font(.caption2).lineLimit(3).multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .padding(6)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

/// The shaded capsule the gallery's two floating pieces sit on, the size slider and the
/// positive count. The material the window title sits on, so both read as chrome over the
/// thumbnails rather than as part of them.
struct GalleryPill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
    }
}
