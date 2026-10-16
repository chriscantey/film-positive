import Foundation

/// What a grid cell is showing. Separated from the view so the layer rules can be
/// asserted in a test rather than read off a screenshot: reset develop must put the cell
/// back to the negative and reset enhance must leave it a positive.
enum FrameCellState: Equatable {
    /// Nothing has been pressed on this frame, so there is no positive and none is coming.
    /// The cell shows the negative thumbnail at full strength with no spinner, because it
    /// is not waiting for anything. This is where a frame sits until the user presses
    /// Positive.
    case negative
    /// A positive is on its way: the frame HAS a develop layer and its first render has
    /// not landed. The cell keeps the negative underneath and puts a spinner over it, so
    /// it never blanks.
    case rendering
    /// Developed, showing the PREVIOUS positive while the new one renders. Distinct from
    /// `.rendering` because the two look completely different to a person: this one is the
    /// picture they were just looking at, and that one is an orange negative. Falling back
    /// to the negative on every settings change would make the frame look reset.
    case restaging
    /// Developed, proxy in hand, current.
    case positive

    /// Takes plain booleans rather than the image itself so the rule stays testable without
    /// constructing a `CGImage`, which is the reason this type is separate from the view.
    static func of(frame: Frame, hasImage: Bool, isStale: Bool = false) -> FrameCellState {
        // A frame with no develop layer is a negative and stays one until the Positive button
        // is pressed. It is never rendered through the in-memory defaults.
        guard frame.isDeveloped else { return .negative }
        guard hasImage else { return .rendering }
        return isStale ? .restaging : .positive
    }

    /// There is a positive to draw, current or not.
    var showsPositive: Bool { self == .positive || self == .restaging }
    /// A render is in flight for this frame.
    var isWorking: Bool { self == .rendering || self == .restaging }
}

/// Grid side conveniences over the model. These add no state: they are ordinary reads and
/// existing model calls, kept here so the shell can bind Select All to one line and so the
/// grid never reaches into the model's internals.
extension AppModel {
    /// Every frame in the folder the sidebar has selected, in display order.
    var framesInView: [Frame] { selectedFolder?.frames ?? [] }

    /// Select all. Bound to command A by the grid toolbar, and the one line the
    /// shell needs if it would rather own the Edit menu item.
    func selectAllInView() { selection = Set(framesInView.map(\.id)) }

    /// The opposite, and the one the shell binds to Command Shift A. Selection, cursor and
    /// anchor clear together or not at all: leaving a cursor behind makes the next arrow
    /// key extend from a cell nothing appears to be on.
    func deselectAllInView() {
        selection = []
        cursor = nil
        anchor = nil
    }

    /// Finder's rule for a right click: act on the selection when the clicked item is part
    /// of it, otherwise make the clicked item the selection first.
    func focusForContextMenu(on id: Frame.ID) {
        if !selection.contains(id) { selection = [id] }
    }

    /// How many of the frames on screen have been developed, for the grid subtitle.
    var developedCountInView: Int { framesInView.filter(\.isDeveloped).count }

    // MARK: keyboard navigation

    /// The navigation state the model holds, as the value type the pure rules take.
    var navigationState: GridNavigation<Frame.ID>.State {
        get { GridNavigation<Frame.ID>.State(selected: selection, anchor: anchor, cursor: cursor) }
        set { selection = newValue.selected; anchor = newValue.anchor; cursor = newValue.cursor }
    }

    /// An arrow key. Returns false when the move is impossible (an empty folder, or an
    /// edge), so the view can leave the key to the system rather than swallowing it.
    ///
    /// In the closeup with several frames selected the arrows walk the SELECTION and
    /// change nothing about it: the point of carrying a multi-selection into the closeup is
    /// to look at each of those frames while the controls keep acting on all of them, and an
    /// arrow that rewrote the selection would undo that on the first keypress. With one frame
    /// selected, or none, it is the walk down the whole roll with the selection following the
    /// cursor.
    @discardableResult
    func navigate(_ move: GridNavigation<Frame.ID>.Move, columns: Int, extend: Bool = false) -> Bool {
        if viewerFrameID != nil, !extend, selection.count > 1 { return walkSelection(move) }
        let order = framesInView.map(\.id)
        guard let next = GridNavigation<Frame.ID>.move(move, order: order, state: navigationState,
                                                       columns: columns, extend: extend) else { return false }
        navigationState = next
        // The viewer always shows one frame, so a move there moves the viewer with it.
        if viewerFrameID != nil {
            viewerFrameID = next.cursor
        } else if let id = next.cursor, let placement = keyboardReveal(for: id, columns: columns) {
            // The keyboard is the path that scrolls, but only when the step leaves the rows
            // on screen: a step inside them leaves the grid where it is. `extend`
            // (shift-arrow) asks too: a range being extended off the bottom of the window is
            // the same problem as a cursor walking off it.
            requestScroll(to: id, placement: placement)
        }
        return true
    }

    /// Whether a keyboard step onto `id` has to move the gallery, and to which edge. Nil
    /// means the frame's row is already on screen.
    ///
    /// Uses the rows wholly on screen (`galleryFullRows`) when the grid has measured them,
    /// else the rows the gallery last reported (`galleryTopFrameID`, `galleryVisibleRows`),
    /// the same arithmetic the closeup's return uses. A nil top is the top of the roll: the
    /// gallery opens there and only reports a top once it has scrolled. Geometry the grid
    /// has not measured yet, or a top that is no longer in the folder, falls back to a
    /// centered scroll, because losing the cursor off the window is worse than one jump.
    func keyboardReveal(for id: Frame.ID, columns: Int) -> ScrollRequest.Placement? {
        let order = framesInView.map(\.id)
        guard let c = order.firstIndex(of: id) else { return nil }
        // The measured rows win when the grid has reported them: they know about a row
        // that is mostly scrolled off, which the top frame alone cannot.
        if columns > 0, let rows = galleryFullRows {
            let r = c / columns
            if rows.contains(r) { return nil }
            return r < rows.lowerBound ? .top : .bottom
        }
        let t: Int
        if let top = galleryTopFrameID {
            guard let i = order.firstIndex(of: top) else { return .center }
            t = i
        } else {
            t = 0
        }
        guard columns > 0, galleryVisibleRows > 0 else { return .center }
        guard GalleryReturn.needsScroll(cursor: c, top: t, columns: columns,
                                        visibleRows: galleryVisibleRows) else { return nil }
        return c / columns < t / columns ? .top : .bottom
    }

    /// The closeup's walk over a multi-selection. Uses the same pure move rules over the
    /// selected frames in display order, then writes back ONLY the shown frame and the
    /// cursor: `selection` and `anchor` are left exactly as they were.
    private func walkSelection(_ move: GridNavigation<Frame.ID>.Move) -> Bool {
        let order = framesInView.filter { selection.contains($0.id) }.map(\.id)
        let state = GridNavigation<Frame.ID>.State(selected: selection, anchor: nil, cursor: viewerFrameID)
        guard let next = GridNavigation<Frame.ID>.move(move, order: order, state: state, columns: 1),
              let id = next.cursor else { return false }
        viewerFrameID = id
        cursor = id
        return true
    }

    /// The frames the closeup's arrows walk: the selection when it holds more than one
    /// frame, the whole folder otherwise. The header counts against this.
    var closeupWalk: [Frame] {
        selection.count > 1 ? framesInView.filter { selection.contains($0.id) } : framesInView
    }

    /// What the closeup's header and window subtitle say about where the user is.
    ///
    /// With several frames selected it names both numbers, because the two facts a person
    /// needs there are different: how many frames the sliders, Reset, Paste, Tone, Auto
    /// Balance, Looks and the orientation buttons are about to act on, and which of them is
    /// on screen. With one frame selected it is the plain position in the roll.
    var closeupPosition: String {
        guard let id = viewerFrameID else { return "" }
        let order = closeupWalk.map(\.id)
        guard let i = order.firstIndex(of: id) else {
            return selection.count > 1 ? "\(selection.count) selected" : ""
        }
        guard selection.count > 1 else { return "\(i + 1) of \(order.count)" }
        return "\(selection.count) selected, showing \(i + 1) of \(order.count)"
    }

    /// Click selection and keyboard navigation share one cursor, so an arrow after a
    /// click continues from the frame that was clicked.
    func selectByClick(_ id: Frame.ID, modifiers: GridSelection<Frame.ID>.Modifiers) {
        let state = GridSelection<Frame.ID>.State(selected: selection, anchor: anchor)
        let next = GridSelection<Frame.ID>.click(id, order: framesInView.map(\.id), state: state, modifiers: modifiers)
        selection = next.selected
        anchor = next.anchor
        cursor = id
        // No click asks the grid to move, plain or modified. The frame just clicked is under
        // the pointer, so it is on screen by definition, and recentering it would jiggle
        // frames already in view. Keyboard navigation is the path that scrolls, in `navigate`.
    }

    /// The frame the content column is showing full size, if any.
    var viewerFrame: Frame? { viewerFrameID.flatMap { id in framesInView.first { $0.id == id } } }

    /// Opens the viewer on the cursor, or on the first selected frame, or on the first
    /// frame in the folder. Does nothing when the folder is empty.
    func openViewer() {
        let order = framesInView
        guard !order.isEmpty else { return }
        openViewer(on: cursor ?? order.first(where: { selection.contains($0.id) })?.id ?? order[0].id)
    }

    /// Opens the closeup on one named frame, which is what a double click means and what
    /// Command K from the grid does.
    ///
    /// Finder's rule, the same one `focusForContextMenu` uses: a frame INSIDE the selection
    /// keeps the whole selection, so three selected frames are still three selected frames
    /// with one of them on screen. A frame OUTSIDE it selects that one frame first, exactly
    /// as the click that landed on it would have.
    ///
    /// Always writing `selection = [id]` would narrow the selection on the way into the
    /// closeup, and a selection-wide Reset would then miss the other frames.
    func openViewer(on id: Frame.ID) {
        guard framesInView.contains(where: { $0.id == id }) else { return }
        // Return pressed with M still held would carry a gallery hold into the closeup.
        showsOriginal = false
        if !selection.contains(id) {
            selection = [id]
            anchor = id
        }
        cursor = id
        if anchor == nil { anchor = id }
        viewerFrameID = id
    }

    /// Done and Escape. The crop rectangle goes with it: it is a mode of the closeup, so
    /// the next frame opened from the grid shows the picture rather than landing in a crop
    /// nobody asked for. Command K is the one key back into it.
    ///
    /// The selection is not touched. Leaving the closeup is not a selection event, so a
    /// person who selected three frames, looked at one and pressed Done is back in the grid
    /// with their three frames still selected.
    func closeViewer() {
        viewerFrameID = nil
        showsCropOverlay = false
        closeupZoom.forgetLayout()
        // Leaving with M held would otherwise strand the grid on the original. The closeup
        // clears it on disappear too; this is the path that does not depend on a view.
        showsOriginal = false
    }

    func toggleViewer() { if viewerFrameID == nil { openViewer() } else { closeViewer() } }
}
