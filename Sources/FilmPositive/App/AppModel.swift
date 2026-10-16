import Foundation
import SwiftUI
import Observation
import FilmSidecar
import FilmPositiveCore

/// What one `apply` costs, split into its four steps, so the apply breakdown reports a
/// measurement instead of an inference. Collected always (four timestamps per edit is
/// nothing) and printed only by the bench.
@MainActor
enum ApplyTrace {
    static var mutateMS: [Double] = []
    static var invalidateMS: [Double] = []
    static var saveMS: [Double] = []
    static var undoMS: [Double] = []

    /// A long session makes a lot of edits, so the window is bounded: four doubles per
    /// edit would otherwise grow for as long as the app is open, which is a measurement
    /// that costs more than the thing it measures.
    static let window = 512

    static func record(mutate t0: UInt64, _ t1: UInt64, invalidate t2: UInt64, save t3: UInt64, undo t4: UInt64) {
        append(&mutateMS, Double(t1 &- t0) / 1e6)
        append(&invalidateMS, Double(t2 &- t1) / 1e6)
        append(&saveMS, Double(t3 &- t2) / 1e6)
        append(&undoMS, Double(t4 &- t3) / 1e6)
    }

    private static func append(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > window { a.removeFirst(a.count - window) }
    }

    static func reset() { mutateMS = []; invalidateMS = []; saveMS = []; undoMS = [] }

    static var summary: String {
        func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
        return String(format: "sidecar mutation %.1f ms, invalidate %.1f ms, schedule save %.1f ms, undo register %.1f ms (n=%d)",
                      mean(mutateMS), mean(invalidateMS), mean(saveMS), mean(undoMS), mutateMS.count)
    }
}

/// The state model: folders as independent sessions, frames, the sidecar struct per frame
/// as the single source of truth, every edit a value-type diff applied through ONE app-wide
/// `UndoManager`, sidecars written back debounced, nothing per image in the app container.
///
/// Views call `apply(_:to:)` with a `SidecarEdits` transform and never mutate a frame's
/// sidecar directly. That is what makes undo, redo, the debounced save and the re-render
/// fall out of one path.
@MainActor
@Observable
final class AppModel {
    // MARK: state

    private(set) var folders: [FolderSession] = []

    /// What each folder has taught us about how big its frames are.
    ///
    /// Autocrop's built fallback comes out about 24 percent too large in area, consistently,
    /// and the folder already holds the correction: the frames whose edges were genuinely
    /// measured. Keyed by folder because an operator works a stack of the same film on the
    /// same stand, so a roll's own frames are a far better prior than any single-frame guess.
    /// Measured across a set of 114 trip frames this takes area error from 16.7% to 5.6%.
    ///
    /// Deliberately in memory only. A scale learned under one camera height is wrong the
    /// moment the rig moves, and a stale number persisted across sessions would be worse than
    /// no number, because nothing in a later run would contradict it.
    var frameScales: [URL: FrameScale] = [:]

    /// Autocrop for one frame, with the folder's learned scale applied and then extended.
    ///
    /// The two halves have to happen in this order: refine against what the folder knew
    /// BEFORE this frame, then learn from the raw result. Learning first would let a frame
    /// correct itself against itself.
    func applyLearnedScale(_ result: AutoCrop.Result?, folder: URL) -> CropEditor.Detection? {
        var scale = frameScales[folder] ?? FrameScale()
        guard let raw = result else { return nil }
        let refined = scale.refined(raw)
        scale.learn(from: raw)
        frameScales[folder] = scale
        // Only a route that MEASURED the frame may teach the session its format, the same rule
        // `CropPlanner` applies internally: a built box's shape came from the expectation, so
        // reading it back would be learning our own assumption.
        if raw.route == .plannerDetected, let size = raw.size { expectedFilmSize = size }
        return CropEditor.Detection(route: refined.route, angle: refined.angle, size: refined.size,
                                    rect: refined.rect, isFrameEdge: refined.isFrameEdge,
                                    unboundedEdges: refined.unboundedEdges,
                                    suggestedMargin: refined.route == .coarse
                                        ? CropEditor.seedMargin : -prefs.autoCropInset / 100)
    }

    /// The format this session believes it is looking at, learned from confident detections.
    /// 35mm to start. A confident detection of anything else replaces it, which is how
    /// changing film mid session keeps working without being told.
    var expectedFilmSize: FilmSize? = FilmSize.seedCatalog.first { $0.name == "35mm" }
    /// Opening or switching a folder is what snapshots the develop defaults, so
    /// "per folder session" is a property of this one assignment rather than a convention
    /// every call site has to keep. A preference changed while a folder is open reaches the
    /// frames the next time a folder is opened, and until then the picture on screen and the
    /// value that would be written stay the same thing.
    ///
    /// The navigation reset lives here for the same reason. The grid is not mounted while
    /// the closeup is up, so a reset in the grid would let a folder chosen from the closeup
    /// keep the old folder's `viewerFrameID`, and every click in the new grid would leave
    /// `selectedFrames` empty.
    var selectedFolderID: FolderSession.ID? {
        didSet {
            // A rename changes the id of the folder on screen without leaving it, so the
            // gallery, its selection and the develop defaults stay as they are.
            if followingRename { rememberSelectedFolder(oldValue); return }
            snapshotDevelopDefaults()
            rememberSelectedFolder(oldValue)
            if selectedFolderID != oldValue { leaveFolderNavigation() }
        }
    }
    /// True only while `renameFolder` moves the selection to the folder's new id.
    @ObservationIgnored var followingRename = false
    /// The folder whose sidebar row shows the name field, or nil.
    var renamingFolderID: FolderSession.ID?
    /// Goes up by one on each refused name, so the open field shakes once per refusal.
    var renameRefusals = 0
    var selection: Set<Frame.ID> = [] { didSet { if selection != oldValue { pasteNote = nil } } }
    /// An explicit request to bring a frame into view. NOT the fact that the cursor moved.
    ///
    /// A `cursor` change is a STATE observation and cannot tell what caused it. Keyboard
    /// navigation needs a scroll, or the selection walks off the bottom of the window, but a
    /// command-click would then center a frame that is already on screen under the pointer.
    /// So scrolling is something a caller ASKS for at the moment it knows the intent, and a
    /// cursor change on its own asks for nothing.
    ///
    /// The serial is why this is a struct rather than a bare `Frame.ID?`: two consecutive
    /// requests for the SAME frame have to be two events, and an id compared by equality
    /// would silently collapse them into one.
    ///
    /// A plain click asks for nothing either. A frame under the pointer is on screen by
    /// definition.
    struct ScrollRequest: Equatable {
        let id: Frame.ID
        let serial: Int
        var placement: Placement = .center

        /// Where the frame lands. A keyboard step past an edge brings the row in at THAT
        /// edge, one row of travel, the way Finder does; centering would jump half a window
        /// for a one-row step. Center is for a frame that has no nearby edge to come in at:
        /// a duplicate, or a step taken before the grid has measured itself.
        enum Placement: Equatable { case center, top, bottom }
    }
    private(set) var scrollRequest: ScrollRequest?
    @ObservationIgnored private var scrollSerial = 0

    /// Ask the grid to bring a frame into view. Called where the intent is known, never
    /// from a setter.
    func requestScroll(to id: Frame.ID, placement: ScrollRequest.Placement = .center) {
        scrollSerial += 1
        scrollRequest = ScrollRequest(id: id, serial: scrollSerial, placement: placement)
    }

    /// Bumped when a control hands the keyboard back. The grid watches it and takes focus.
    ///
    /// Clearing a control's own `FocusState` is NOT enough: focus goes to the window,
    /// `GridView`'s `focusable()` never receives it, and the arrow keys reach nothing at all.
    ///
    /// A counter rather than a flag, for the same reason `ScrollRequest` carries a serial: two
    /// consecutive releases are two events, and a Bool would collapse them into one.
    private(set) var focusGridRequest = 0

    /// Hand the keyboard back to the gallery. Called where a control knows it is done with it.
    func returnFocusToGrid() {
        sidebarHasKeyboard = false
        focusGridRequest += 1
    }

    /// The folder list holds the keyboard, because a folder was just chosen there by a
    /// click or an arrow. While it does, a folder change must NOT pull focus into the gallery,
    /// or the arrows could not walk the folder list. Cleared when the gallery takes focus by
    /// any route, and by Return and Escape in the list. Not observed: only the gallery's
    /// focus rule reads it.
    @ObservationIgnored var sidebarHasKeyboard = false

    /// A folder chosen IN the sidebar, by a click or the arrow keys. The one path the list's
    /// selection binding writes through, so the gallery can tell it from a folder chosen by
    /// anything else (added, dropped, restored), which still takes the gallery's focus.
    func selectFolderFromSidebar(_ id: FolderSession.ID?) {
        sidebarHasKeyboard = true
        if selectedFolderID != id { selectedFolderID = id }
    }

    /// Escape in the folder list. The list lets go and nothing else takes the keyboard.
    func releaseSidebarKeyboard() { sidebarHasKeyboard = false }

    /// The list's own focus, as SwiftUI reports it. A click on the row that is ALREADY selected
    /// focuses the list without calling the selection setter, so `selectFolderFromSidebar` alone
    /// would leave the flag false there, and Command Backspace would trash the grid's frames
    /// while the list held the keyboard. Losing focus by any route clears it.
    func sidebarFocusChanged(_ focused: Bool) { sidebarHasKeyboard = focused }
    var prefs = Preferences.load()
    /// The last engine error, shown by the window as an alert with the complete text.
    var lastError: String?
    /// One readable line in the window's bottom banner, shown and then gone on its own.
    ///
    /// Non-modal on purpose, and the distinction is not cosmetic. An alert asks a question,
    /// and a folder that vanished while the app was running poses none: the deed is done
    /// outside the app, there is nothing to decide, and the only useful thing is to say so
    /// once.
    var notice: String?
    /// Whether a remembered folder is still there, and if not, why. Injected so the two
    /// branches that must NEVER prune, an unmounted volume and an unresolvable bookmark,
    /// are provable without a drive to eject.
    @ObservationIgnored var folderVerdict: (Data, URL?) -> FolderVerdict = { FolderOnDisk.verdict(bookmark: $0, knownURL: $1) }
    /// Bookmarks for folders that are not reachable right now: an unplugged drive, a share
    /// that is not mounted. They have no session in `folders`, so `persistFolders` has to
    /// write them back explicitly or any save at all would forget a drive that is merely
    /// asleep.
    @ObservationIgnored private var offlineBookmarks: [Data] = []
    /// When the last sweep ran, for the debounce in `sweepFoldersIfIdle`.
    @ObservationIgnored private var lastSweep: Date?
    /// One quiet line under the inspector's first section after a paste that could not
    /// carry everything it was asked for. Non-modal on purpose: the paste DID do the
    /// enhance and crop half, so an alert would overstate it.
    ///
    /// Cleared by the next selection change, because the note is about what just happened
    /// to THESE frames and a stale one would be about frames the user has left behind.
    var pasteNote: String?
    var addFolderRequested = false
    /// The closeup draws the UNCROPPED frame with the crop rectangle over it instead of the
    /// finished picture. A view mode of the closeup rather than a tool of its own, which is
    /// why it lives here and not in a view: it has to survive arrowing from one frame to the
    /// next so a crop pass over a roll is one pass.
    var showsCropOverlay = false
    /// Zoom and pan in the closeup. Fit whenever the closeup opens, steps to another
    /// frame, or shows anything other than the finished picture.
    var closeupZoom = CloseupZoom()
    /// The pointer over the closeup's picture, in the picture's own points, or nil. Not
    /// observed: it changes on every mouse move and only the zoom keys read it.
    @ObservationIgnored var closeupPointer: CGPoint?
    /// The Help menu's keyboard shortcuts sheet. Read-only and bound to nothing, which is
    /// why it is deliberately absent from the sweep guard in `sweepFoldersIfIdle`: that
    /// guard exists because a sheet addressing a FOLDER must not have the folder pruned
    /// from under it, and this one addresses no folder.
    var showsShortcuts = false
    /// The Export sheet, over the selection.
    var showsExportSheet = false
    /// The Detect Crop sheet, over the selection. On the model rather than in a view
    /// because the button that opens it is in the inspector's Frame section and the sheet
    /// is mounted once in `ContentView`, the same shape Export has.
    var showsAutoCropSheet = false
    /// The eyedropper is armed and the closeup is in Pick Base mode.
    ///
    /// A mode of the closeup, like the crop rectangle, and on the model for the same
    /// reason: it has to survive arrowing from one frame to the next, because the whole
    /// point of it is that the frame you SAMPLE need not be a frame you are editing.
    ///
    /// The target set is a snapshot of the selection taken when the mode is armed
    /// (`pickBaseTargets`), and in this mode the arrows walk the roll WITHOUT touching the
    /// selection (`walkRollForPickBase`).
    var isPickingBase = false
    /// The last base a pick wrote, for Reuse Last Base. SESSION memory, never persisted:
    /// a measurement belongs to the frame it came off and the roll it was on,
    /// so carrying it across launches would be asserting something about the next roll.
    var lastPickedBase: BaseRatios?
    /// The three channel means the pick actually measured, kept beside the ratios so Reuse
    /// Last Base writes the IDENTICAL `BaseSettings` rather than a reconstructed one.
    var lastPickedMeasured: [Int]?
    /// One line under the inspector after a pick: the ratios that were written, or the
    /// reason a pick was refused. Same non-modal shape as `pasteNote`, and cleared by the
    /// next pick or by leaving the mode.
    var pickBaseNote: String?
    /// Hold to see the original, with enhancements off.
    ///
    /// Transient by construction: it is never read from or written to a sidecar, it takes
    /// no undo entry, and the closeup clears it on frame change and on disappear so a
    /// keyboard release lost to a window switch cannot leave it stuck on. Writing it points
    /// the render coordinator at a different request for the same frame, which is the whole
    /// mechanism.
    /// One meaning, not a mode: the Enhance layer at `.identity`. A Look is a named slider
    /// set written into that same layer, so this takes a Look off with it and there is
    /// nothing else to decide.
    var showsOriginal = false {
        didSet {
            guard showsOriginal != oldValue else { return }
            // A release ends the hold wherever it began, so a gallery scope never outlives
            // the M that set it and the closeup's next hold covers its frame.
            if !showsOriginal { originalScope = nil }
            renders.showsOriginal = showsOriginal
        }
    }
    /// The frames a gallery hold covers, nil for all of them. Written only by
    /// `holdOriginalInGallery` and cleared by the release above.
    private(set) var originalScope: Set<Frame.ID>? {
        didSet { renders.originalScope = originalScope }
    }

    /// Hold M on the gallery. The selected frames show their originals, or every
    /// frame when nothing is selected, the same "Finder acts on the selection" rule the
    /// grid's other verbs follow. An undeveloped frame has no Enhance to take off, so it
    /// asks for no render either way.
    func holdOriginalInGallery() {
        originalScope = selection.isEmpty ? nil : selection
        showsOriginal = true
    }
    /// Bulk Detect Crop progress: the frame under the detector right now and the count, so
    /// the grid can mark each cell as it is worked and the sheet can count.
    var autoCropping: Frame.ID?
    var autoCropProgress: (done: Int, total: Int)?
    /// A bulk wand or Neutralize run: the frame being read right now, so its cell
    /// carries the same corner spinner as bulk crop, and whether a run is going, so the
    /// button shows a spinner and cannot start a second one. Set only for more than one
    /// frame, since one frame reads in well under a second.
    var enhanceReading: Frame.ID?
    var enhanceRunning = false
    /// Whether the run going now is the Color wand's, so the stop sits in the slot of
    /// the wand that was clicked. Cleared with `enhanceRunning`.
    var colorRunning = false
    /// Set by `stopRun`, read by both wands (`runWand`) and Detect Crop (`runCrop`) between
    /// frames, and cleared when the run returns.
    var stopRequested = false
    /// Keyboard navigation, shared by the grid and the viewer so the two never disagree
    /// about where the user is. `cursor` is the focused frame the arrows
    /// move, `anchor` is where a shift extend ranges from, and `viewerFrameID` names the
    /// frame the content column is showing full size, nil for the grid.
    var cursor: Frame.ID?
    var anchor: Frame.ID?
    var viewerFrameID: Frame.ID?
    /// The frame at the top of the gallery, kept here rather than in the grid so it
    /// survives the grid being rebuilt when the closeup closes.
    var galleryTopFrameID: Frame.ID?
    /// How many whole rows the gallery showed last, for deciding on return whether the
    /// frame the closeup ended on is already in view.
    var galleryVisibleRows = 0
    /// The rows wholly on screen right now, updated as the gallery scrolls. Keyboard steps
    /// scroll only when they leave these. Ignored by observation: it changes on every
    /// scroll tick and no view draws from it.
    @ObservationIgnored var galleryFullRows: ClosedRange<Int>?
    /// A Finder drag is over the window, so the Folders panel shows where it will land.
    var isDropTargeted = false
    /// Each folder's Finder color tag, as last read off the disk. A cache of the
    /// folder's own tag and never persisted: the disk is the store, so Finder and the
    /// sidebar always agree. Read at launch, on add, on every return to the app, and after
    /// a set from the sidebar's menu.
    var folderColours: [FolderSession.ID: FolderColour] = [:]

    let renders: RenderCoordinator
    let undoManager = UndoManager()
    /// The Edit menu's "Undo Straighten", observable where `undoManager` is not.
    let undoTitles = UndoTitleMirror()
    /// True only while `restoreFolders` picks the launch folder.
    @ObservationIgnored var restoringFolders = false
    /// Move to Trash's file trasher. A test swaps in a scratch folder so it never
    /// touches the real Trash.
    @ObservationIgnored var trashFile: (URL) throws -> URL = TrashPlan.systemTrash
    private let store = SidecarStore()
    private var pendingSaves: [Frame.ID: Task<Void, Never>] = [:]

    /// `folderVerdict` is an init parameter and not only a settable property because
    /// `restoreFolders` runs HERE: the launch prune is one of the three places the rule has
    /// to hold, so a test that cannot reach it before it runs cannot prove it.
    init(service: any RenderService, folderVerdict: ((Data, URL?) -> FolderVerdict)? = nil) {
        renders = RenderCoordinator(service: service)
        undoManager.levelsOfUndo = 200
        undoTitles.watch(undoManager)
        if let folderVerdict { self.folderVerdict = folderVerdict }
        // A frame deleted in Finder reaches the banner, not the alert.
        renders.onFileVanished = { [weak self] sentence in self?.notice = sentence }
        // Before `restoreFolders`, because a model with no folder at all still renders: a
        // test builds frames directly and the defaults have to be there for them.
        snapshotDevelopDefaults()
        restoreFolders()
    }

    /// The real engine, or a service that reports why it could not start.
    static func live() -> AppModel {
        let profiles = (try? ProfileLibrary.bundled()) ?? nil
        if let profiles { return AppModel(service: CPURenderService(profiles: profiles)) }
        return AppModel(service: FailingRenderService(message: "bundled profiles are missing"))
    }

    // MARK: folders

    var selectedFolder: FolderSession? { folders.first { $0.id == selectedFolderID } }

    func presentAddFolder() { addFolderRequested = true }

    /// Nothing survives a folder change: a different roll is a different gallery.
    func clearNavigation() {
        selection = []
        cursor = nil
        anchor = nil
        viewerFrameID = nil
        galleryTopFrameID = nil
        galleryFullRows = nil
    }

    /// A folder change. The closeup goes the way Done takes it, crop overlay and zoom with
    /// it, so the next closeup opens on the picture; then the navigation clears.
    private func leaveFolderNavigation() {
        if viewerFrameID != nil { closeViewer() }
        clearNavigation()
    }

    /// `select: false` is Move to Folder's: a destination joins the list without taking the
    /// screen away from the roll the person is sorting.
    @discardableResult
    func addFolder(_ url: URL, select: Bool = true) -> FolderSession? {
        // By standardized path, not URL equality: a folder dragged from Finder and the same
        // folder from the open panel can differ by a trailing slash, and would be added twice.
        let path = url.standardizedFileURL.path
        if let existing = folders.first(where: { $0.url.standardizedFileURL.path == path }) {
            if select { selectedFolderID = existing.id }
            return existing
        }
        do {
            let bookmark = try Self.folderBookmark(for: url)
            _ = url.startAccessingSecurityScopedResource()
            let frames = try FolderSession.scan(url)
            let session = FolderSession(url: url, bookmark: bookmark, frames: frames)
            folders.append(session)
            if select { selectedFolderID = session.id }
            persistFolders()
            folderColours[session.id] = FolderColour.read(url)
            return session
        } catch {
            // `localizedDescription`, not the whole error. This is the other place in the
            // folder UI a raw `NSCocoaErrorDomain` string could reach a modal, and the
            // sentence a person can act on is the only part of it that helps.
            lastError = "Could not add \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    /// The bookmark a folder is remembered by. A security-scoped bookmark needs the sandbox
    /// entitlement, which the unbundled dev build lacks (NSCocoaErrorDomain 256), so it
    /// falls back to a plain bookmark there.
    nonisolated static func folderBookmark(for url: URL) throws -> Data {
        try (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? url.bookmarkData(includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Removes the session only. Nothing on disk is touched. Undoable.
    func removeFolder(_ id: FolderSession.ID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let removed = folders[index]
        folders.remove(at: index)
        if selectedFolderID == id { selectedFolderID = folders.first?.id }
        selection.subtract(removed.frames.map(\.id))
        persistFolders()
        undoManager.registerUndo(withTarget: self) { model in
            model.folders.insert(removed, at: min(index, model.folders.count))
            model.persistFolders()
            model.undoManager.registerUndo(withTarget: model) { m in m.removeFolder(removed.id) }
        }
        undoManager.setActionName("Remove Folder")
    }

    /// Drag to reorder in the sidebar. The order is the list's own order, which is what
    /// `persistFolders` saves, so it survives a relaunch with nothing new stored. Undoable
    /// as one step, by putting the previous order back.
    func moveFolders(from source: IndexSet, to destination: Int) {
        let before = folders.map(\.id)
        folders.move(fromOffsets: source, toOffset: destination)
        guard folders.map(\.id) != before else { return }
        persistFolders()
        registerFolderOrderUndo(restoring: before)
    }

    private func registerFolderOrderUndo(restoring order: [FolderSession.ID]) {
        let current = folders.map(\.id)
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            model.folders.sort { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
            model.persistFolders()
            model.registerFolderOrderUndo(restoring: current)
        }
        undoManager.setActionName("Move Folder")
        undoManager.endUndoGrouping()
    }

    /// Re-reads a folder from disk (a sidecar deleted outside the app shows the frame as
    /// undeveloped again), and first decides whether it is still a folder at all.
    ///
    /// It tells "this folder is gone" from "reading it failed", so Refresh on a folder
    /// deleted in Finder prunes it with a sentence in the banner rather than showing
    /// `NSCocoaErrorDomain Code=260` in a modal alert.
    func rescan(_ id: FolderSession.ID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let session = folders[index]
        switch folderVerdict(session.bookmark, session.url) {
        case .gone(let why):
            prune(at: index)
            notice = Self.goneNotice([session.name], why: why)
        case .offline:
            // Asked for directly, so answer directly. The background sweep stays silent in
            // this case; a user who just pressed Refresh is owed a reason nothing happened.
            notice = "\(session.name) is on a drive that is not connected. Kept in the list."
        case .live(let url, let refreshed):
            if let refreshed { folders[index].bookmark = refreshed; persistFolders() }
            guard url.standardizedFileURL.path == session.url.standardizedFileURL.path else {
                // Followed the folder to a new place. The session cannot move with it,
                // because `FolderSession.ID` IS its URL and every selection, render and
                // undo entry is keyed on that. The bookmark now points at the new path, so
                // the next launch opens it there.
                notice = "\(session.name) has moved. It will open from its new place next time."
                return
            }
            do { folders[index].frames = try FolderSession.scan(url) }
            catch { lastError = "Could not read \(session.name): \(error.localizedDescription)" }
        }
    }

    /// Drops a folder that is gone from disk. Deliberately NOT `removeFolder`: that one is
    /// undoable, and an undo here would put back a folder that does not exist.
    ///
    /// Order matters, and not for tidiness. Removing the row is NOT what makes the Trash
    /// case safe: a debounced sidecar write still queued for one of these frames would land
    /// in the Trash copy and die when the Trash is emptied. The writes are canceled and the
    /// security scope released BEFORE the list is shortened and persisted, so nothing is
    /// still holding a folder the app has stopped believing in.
    private func prune(at index: Int) {
        let removed = folders[index]
        for id in removed.frames.map(\.id) {
            pendingSaves[id]?.cancel()
            pendingSaves[id] = nil
        }
        removed.url.stopAccessingSecurityScopedResource()
        folders.remove(at: index)
        selection.subtract(removed.frames.map(\.id))
        if selectedFolderID == removed.id {
            selectedFolderID = folders.first?.id
            // The same thing a folder change already does. Called here rather than left to
            // `GridView`'s `onChange` so the model is correct with no view mounted, which
            // is what the tests read.
            clearNavigation()
        }
        persistFolders()
    }

    /// One pass over the folder list, run when the app comes forward.
    ///
    /// A resolve and a `fileExists` per folder, which is nothing for a list this size. No
    /// FSEvents, no watcher, no timer: the moment the user looks at the window is the only
    /// moment the list has to be right, and that moment has a notification already.
    ///
    /// Two gates before it runs at all. `didBecomeActive` fires at launch too, so without a
    /// debounce it doubles up with `restoreFolders` and can fire twice in a second. And a
    /// sheet on screen is bound to a folder id: pulling that folder out from under it leaves
    /// a sheet addressing something that no longer exists.
    @discardableResult
    func sweepFoldersIfIdle(now: Date = Date()) -> [String] {
        guard !showsExportSheet, !showsAutoCropSheet else { return [] }
        if let last = lastSweep, now.timeIntervalSince(last) < 2 { return [] }
        lastSweep = now
        return sweepFolders()
    }

    @discardableResult
    func sweepFolders() -> [String] {
        var gone: [(id: FolderSession.ID, name: String, why: FolderVerdict.Gone)] = []
        var refreshedAny = false
        for session in folders {
            switch folderVerdict(session.bookmark, session.url) {
            case .gone(let why):
                gone.append((session.id, session.name, why))
            case .offline:
                // Silent. A drive that is asleep is not news, and a banner every time the
                // app comes forward would train the user to ignore the one that matters.
                break
            case .live(_, let refreshed):
                guard let refreshed, let index = folders.firstIndex(where: { $0.id == session.id }) else { break }
                folders[index].bookmark = refreshed
                refreshedAny = true
            }
        }
        for entry in gone {
            guard let index = folders.firstIndex(where: { $0.id == entry.id }) else { continue }
            prune(at: index)
        }
        if gone.isEmpty {
            if refreshedAny { persistFolders() }
            return []
        }
        notice = Self.goneNotice(gone.map(\.name), why: gone.allSatisfy { $0.why == .trashed } ? .trashed : .deleted)
        return gone.map(\.name)
    }

    /// The sentence the banner shows. The user reads this, so it names the folder and says what
    /// was done about it, in that order.
    static func goneNotice(_ names: [String], why: FolderVerdict.Gone) -> String {
        // Both numbers spelled out rather than derived. A substring swap looked tidy and was
        // wrong: "is" sits inside "disk", so turning it plural produced "no longer on darek".
        let singular = why == .trashed ? "is in the Trash" : "is no longer on disk"
        let plural = why == .trashed ? "are in the Trash" : "are no longer on disk"
        switch names.count {
        case 1: return "\(names[0]) \(singular). Removed from the list."
        case 2: return "\(names[0]) and \(names[1]) \(plural). Removed from the list."
        default: return "\(names.count) folders \(plural). Removed from the list."
        }
    }

    func persistFolders() {
        // The offline bookmarks are the load-bearing half. Without them a save while one
        // drive is unplugged writes a list that no longer mentions it, and that folder is
        // gone for good with nothing on screen to explain it.
        prefs.folderBookmarks = folders.map(\.bookmark) + offlineBookmarks
        prefs.save()
    }

    private func restoreFolders() {
        var changed = false
        offlineBookmarks = []
        for data in prefs.folderBookmarks {
            switch folderVerdict(data, nil) {
            case .offline:
                // Unreachable right now: an unmounted volume, or a bookmark that will not
                // resolve. Keep it for the next launch and create no session. This branch
                // is why `persistFolders` writes `offlineBookmarks` back, so a save keeps an
                // offline folder and a gone folder can still be forgotten.
                offlineBookmarks.append(data)
            case .gone:
                // Deleted, or resolved into a Trash. Dropped without a word: at launch there
                // is no "while you were working" to report.
                changed = true
            case .live(let url, let refreshed):
                _ = url.startAccessingSecurityScopedResource()
                guard let frames = try? FolderSession.scan(url) else { offlineBookmarks.append(data); continue }
                if refreshed != nil { changed = true }
                folders.append(FolderSession(url: url, bookmark: refreshed ?? data, frames: frames))
            }
        }
        // The folder that was selected when the app quit, not the first in the list.
        restoringFolders = true
        selectedFolderID = Self.folderToReopen(folders.map(\.url), remembered: prefs.lastFolderPath)
        restoringFolders = false
        if changed { persistFolders() }
        refreshFolderColours()
    }

    // MARK: frames and edits

    func frame(_ id: Frame.ID) -> Frame? {
        for f in folders { if let fr = f.frames.first(where: { $0.id == id }) { return fr } }
        return nil
    }

    /// The frames a control acts on. In the grid, the selection. In the closeup, the SHOWN
    /// frame alone, whatever else is selected. `selection` itself stays whole through the
    /// closeup, so the arrow walk and the "3 selected, showing 2 of 3" header still read it,
    /// and back in the grid every control acts on it again.
    var selectedFrames: [Frame] {
        if let shown = viewerFrameID {
            return (selectedFolder?.frames ?? []).filter { $0.id == shown }
        }
        return (selectedFolder?.frames ?? []).filter { selection.contains($0.id) }
    }

    /// The single edit path. `edit` is a `SidecarEdits` transform (or any pure function
    /// of the sidecar). Registers the inverse for undo, schedules the debounced save, and
    /// invalidates the cached render.
    ///
    /// `seedsDefaults: false` is for an edit that is never a statement about the positive,
    /// the Metadata rows today. The funnel cannot tell such an edit apart from the Positive
    /// button when it happens to change nothing (a film name written over frames that
    /// already carry it), and would read that no-op as "process this negative". The caller
    /// knows what its edit means, so the caller says.
    func apply(_ edit: (Sidecar) -> Sidecar, to id: Frame.ID, actionName: String, seedsDefaults: Bool = true) {
        guard let (fi, xi) = locate(id) else { return }
        let before = folders[fi].frames[xi].sidecar
        let after = seedsDefaults ? commitDefaultsThen(edit, on: before) : edit(before)
        guard after != before else { return }
        setSidecar(after, at: fi, xi, actionName: actionName, previous: before)
    }

    /// The defaults-commit rule, in the funnel rather than at the call sites.
    ///
    /// A frame with no develop layer is rendered through `DevelopDefaults`, so what the
    /// user sees is a positive. The first edit of any kind therefore has to write that
    /// develop layer down alongside the edit, or the file would say "no positive" about a
    /// picture that plainly is one, and the next launch would show a different frame.
    ///
    /// It lives here and not in the twenty controls that call `apply` because a rule kept
    /// at call sites is a rule a new call site forgets. `SidecarEditCommitTests` walks every
    /// entry point in `SidecarEdits` and every selection action on this model, so a new one
    /// with no row fails rather than silently opting out.
    ///
    /// The seeded sidecar is handed to the SAME closure the caller passed, which is what
    /// makes it one undo step: `setSidecar` registers one inverse for the pair.
    ///
    /// ONE exception, and it is the reason this is not a two-line function. `resetDevelop`
    /// on an undeveloped frame must stay a no-op. Seeding it would create the develop layer
    /// and the edit would immediately clear it, so the frame would end where it started
    /// while a full sidecar write went to disk. The tell is that the edit returns a sidecar
    /// with no develop layer even though it was given one: that is a reset, and a reset gets
    /// the original.
    private func commitDefaultsThen(_ edit: (Sidecar) -> Sidecar, on before: Sidecar) -> Sidecar {
        guard before.develop == nil, let defaults = renders.defaults.develop(for: before) else {
            return edit(before)
        }
        var seeded = before
        seeded.develop = defaults
        let after = edit(seeded)
        if after.develop == nil { return edit(before) }

        // The second exception: a GEOMETRY-only edit on a negative writes geometry and
        // nothing else. Rotating a frame you have not processed yet is not a statement about
        // its film or its tone, and frames stay negatives until the Positive
        // button is pressed, so seeding here would silently process a frame on a keypress
        // that said nothing except "this one is sideways". Geometry is the one layer that
        // means the same thing on a negative as on a positive.
        //
        // Decided by looking at what the edit DID rather than by running it a second time
        // against the unseeded sidecar. Nearly every edit closure in the app opens with
        // `guard var develop = sidecar.develop else { return sidecar }`, so a speculative
        // call on a frame with no develop layer is at best a no-op it has to be told to
        // ignore and at worst a second invocation of a closure nobody wrote to be idempotent.
        // One call, then a comparison. `after.geometry != seeded.geometry` is required: an
        // edit that changes NOTHING also "differs in geometry alone", and that is exactly the
        // Positive button, whose whole job is to write the defaults it is already showing.
        // Without this clause `developSelection` would write nothing.
        //
        // The capture block (camera and film names, the inspector's Metadata rows) joins
        // geometry here for the same reason: correcting what a frame was shot on is not a
        // decision about its positive, so it must not process a negative either. The frame
        // keeps no develop layer, and the corrected film name is what a later press of
        // Positive resolves to a stock, which is the only moment a name ever picks a stock.
        // Reset Enhance on a negative that holds a dormant enhance layer (one Reset
        // Positive left behind) clears that layer and leaves the frame a negative. Clearing
        // settings nobody can see is not a request for a positive. Only a CLEAR qualifies:
        // an edit that sets enhance values still commits the positive.
        // The Color Auto record is part of that layer.
        if before.enhance != nil || before.look != nil || before.colorAuto != nil,
           after.enhance == nil, after.look == nil, after.colorAuto == nil,
           onlyEnhanceDiffers(after, from: seeded) {
            var plain = before
            plain.enhance = nil
            plain.look = nil
            plain.colorAuto = nil
            return plain
        }

        let touchedNegativeSafeLayer = after.geometry != seeded.geometry || after.capture != seeded.capture
        if touchedNegativeSafeLayer, onlyNegativeSafeLayersDiffer(after, from: seeded) {
            var plain = before
            plain.geometry = after.geometry
            plain.capture = after.capture
            return plain
        }
        return after
    }

    private func onlyEnhanceDiffers(_ after: Sidecar, from before: Sidecar) -> Bool {
        var probe = after
        probe.enhance = before.enhance
        probe.look = before.look
        probe.colorAuto = before.colorAuto
        return probe == before
    }

    /// Whether two sidecars differ in `geometry` and `capture` alone. Written as "equal once
    /// those are held equal" rather than as a field-by-field comparison, so a sidecar field
    /// added later is covered by default instead of being silently exempt.
    private func onlyNegativeSafeLayersDiffer(_ after: Sidecar, from before: Sidecar) -> Bool {
        var probe = after
        probe.geometry = before.geometry
        probe.capture = before.capture
        return probe == before
    }

    /// What this frame renders through right now: its own develop layer, or the session's
    /// snapshotted defaults. The render coordinator answers the same question with the same
    /// value, which is the point of there being one of these.
    func effectiveDevelop(for frame: Frame) -> DevelopSettings? {
        renders.defaults.develop(for: frame.sidecar)
    }

    /// Snapshots the defaults for a folder session. Called when a folder is opened or
    /// selected, never per read: a preference change mid-session must not be able to make a
    /// committed frame differ from the one that was on screen when the user reached for the
    /// control.
    func snapshotDevelopDefaults() {
        renders.defaults = DevelopDefaults(profiles: renders.profiles)
    }

    private func setSidecar(_ value: Sidecar, at fi: Int, _ xi: Int, actionName: String, previous: Sidecar) {
        let id = folders[fi].frames[xi].id
        // These four stamps measure the interval between a slider edit and the render task
        // starting. The mutation stamp is the interesting one: writing the sidecar
        // into `folders` notifies every observer of that one array synchronously.
        let t0 = DispatchTime.now().uptimeNanoseconds
        folders[fi].frames[xi].sidecar = value
        let t1 = DispatchTime.now().uptimeNanoseconds
        renders.invalidate(id)
        let t2 = DispatchTime.now().uptimeNanoseconds
        scheduleSave(id)
        let t3 = DispatchTime.now().uptimeNanoseconds
        undoManager.registerUndo(withTarget: self) { model in
            guard let (fi2, xi2) = model.locate(id) else { return }
            let current = model.folders[fi2].frames[xi2].sidecar
            model.setSidecar(previous, at: fi2, xi2, actionName: actionName, previous: current)
        }
        undoManager.setActionName(actionName)
        ApplyTrace.record(mutate: t0, t1, invalidate: t2, save: t3, undo: DispatchTime.now().uptimeNanoseconds)
    }

    /// The selection-wide edit path. Applies one
    /// transform to every selected frame as ONE undo step, so a stock change over forty
    /// frames is one Command Z rather than forty.
    ///
    /// The grouping is explicit rather than left to `groupsByEvent`. Event grouping would
    /// in fact produce one group here on a live run loop, and it produces one group in a
    /// test for the unrelated reason that a test has no event loop at all, which means a
    /// test could never tell the two apart. An explicit balanced group holds the property
    /// in both places, and it nests safely inside a drag's open group because it opens and
    /// closes inside a single call.
    ///
    /// `predicate` exists for the develop controls: a stock belongs to a develop layer, so
    /// writing one to a frame that has none would have to invent the rest of that layer.
    /// Those controls pass `\.isDeveloped` and the section says how many frames it skipped.
    func applyToSelection(_ edit: (Sidecar) -> Sidecar,
                          actionName: String,
                          where predicate: (Frame) -> Bool = { _ in true },
                          seedsDefaults: Bool = true) {
        applyToFrames(selectedFrames.filter(predicate).map(\.id), edit, actionName: actionName, seedsDefaults: seedsDefaults)
    }

    /// `applyToSelection` over a named set of frames rather than the live selection. The
    /// Metadata rows are the caller: a name typed into a field belongs to the frames that
    /// were selected when the typing began, and a click on another frame changes the
    /// selection before the field lets go.
    func applyToFrames(_ ids: [Frame.ID], _ edit: (Sidecar) -> Sidecar,
                       actionName: String, seedsDefaults: Bool = true) {
        let targets = ids.compactMap { frame($0) }
        guard !targets.isEmpty else { return }
        // Grouped even for a single frame. Two reasons: the shape of one edit should not
        // depend on how many frames happened to be selected, and `groupsByEvent` is false
        // for the whole of a slider drag, where an ungrouped registration is not merely
        // untidy, it throws.
        undoManager.beginUndoGrouping()
        for frame in targets { apply(edit, to: frame.id, actionName: actionName, seedsDefaults: seedsDefaults) }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    /// ONE undo step for a run whose frames were written one at a time with undo registration
    /// off (`runWand`): undoing it sets every listed frame back to the sidecar given for
    /// it, the one it held when the run began. Each restore goes through `setSidecar`, the path
    /// every edit takes (render invalidated, save scheduled), and registers that frame's redo
    /// there, so one Redo writes the whole run back and Undo after a batch behaves exactly as
    /// Undo after one frame. A frame that already holds its pre-run sidecar is left alone.
    ///
    /// The group opens and closes inside this call, so it balances whatever `groupsByEvent`
    /// says and nests safely inside a drag's open group, the same as `applyToFrames`.
    func registerRunUndo(restoring preRun: [(Frame.ID, Sidecar)], actionName: String) {
        guard !preRun.isEmpty else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            for (id, value) in preRun {
                guard let (fi, xi) = model.locate(id) else { continue }
                let current = model.folders[fi].frames[xi].sidecar
                guard current != value else { continue }
                model.setSidecar(value, at: fi, xi, actionName: actionName, previous: current)
            }
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    /// What every control in the inspector reads. One pass over the selection.
    var selectionSummary: SelectionSummary {
        let frames = selectedFrames
        return SelectionSummary(frames.map(\.sidecar), effective: frames.map { effectiveDevelop(for: $0) })
    }

    /// The Base row's Adjust. Shows or hides the two color axis rows and remembers
    /// it, app-wide. A preference and nothing else: no sidecar is written and no undo step
    /// is registered, because nothing about any frame changed.
    func toggleColourAxes() {
        prefs.showsColourAxes.toggle()
        prefs.save()
    }

    /// A press on an inspector title: folds or unfolds that part, app-wide and
    /// remembered. A preference, like Adjust above, so no sidecar and no undo step.
    func toggleSection(_ section: InspectorSection) {
        prefs.sectionFold.toggle(section)
        prefs.save()
    }

    /// The View menu's Show Histogram (Command Y): the Histogram section's fold, read and
    /// written.
    var histogramOpen: Bool {
        get { prefs.sectionFold.isOpen(.histogram) }
        set { if newValue != histogramOpen { toggleSection(.histogram) } }
    }

    /// The Tone row's Adjust. Shows or hides the four tone rows and remembers it,
    /// app-wide, the same kind of preference as the Base row's Adjust above.
    func toggleToneAdjust() {
        prefs.showsToneAdjust.toggle()
        prefs.save()
    }

    /// A press on a Develop row's title: the Base or Tone title toggles that row's
    /// remembered fold. A preference only.
    func toggleDevelopRow(_ row: DevelopRow) {
        switch row {
        case .base: toggleColourAxes()
        case .tone: toggleToneAdjust()
        }
    }

    private func locate(_ id: Frame.ID) -> (Int, Int)? {
        for (fi, f) in folders.enumerated() { if let xi = f.frames.firstIndex(where: { $0.id == id }) { return (fi, xi) } }
        return nil
    }

    /// Debounced, no-op-free write of `<base>.xmp`.
    private func scheduleSave(_ id: Frame.ID) {
        pendingSaves[id]?.cancel()
        pendingSaves[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self, let frame = self.frame(id) else { return }
            do { try self.store.save(frame.sidecar.withLiveFields, for: frame.url) } catch { self.lastError = "Could not write \(frame.name)'s sidecar: \(error)" }
        }
    }

    /// Writes a frame's sidecar NOW and drops the debounced write queued for it.
    ///
    /// Duplicate is the caller. The copy has to carry the edits the user just made, and
    /// for 400 ms after a slider move those live only in memory, so a duplicate taken in
    /// that window would otherwise write the new sidecar from live state and leave the
    /// ORIGINAL's file a version behind.
    ///
    /// Returns without writing when nothing is queued, so duplicating a frame nobody has
    /// edited does not conjure a sidecar file beside it.
    func flushPendingSave(_ id: Frame.ID) {
        guard let pending = pendingSaves[id] else { return }
        pending.cancel()
        pendingSaves[id] = nil
        guard let frame = frame(id) else { return }
        do { try store.save(frame.sidecar.withLiveFields, for: frame.url) } catch { lastError = "Could not write \(frame.name)'s sidecar: \(error)" }
    }

    /// Writes a sidecar for a file that is not a frame in any folder yet, through the same
    /// store every other write goes through (never a byte copy of the old file: the copy
    /// must carry unsaved edits, and its `source` names its own image).
    func writeSidecar(_ sidecar: Sidecar, for url: URL) throws {
        try store.save(sidecar.withLiveFields, for: url)
    }

    /// Puts a file this session just created into the folder, right after the frame it came
    /// from, rather than where a rescan would sort it. Duplicate is the only caller: a copy
    /// belongs beside its original where the user can see the pair, and `-2` does not
    /// reliably sort next to its base name under `localizedStandardCompare`.
    ///
    /// Lives here rather than in the extension because `folders` is `private(set)`: the
    /// array that holds every frame is only mutated in this file.
    func insertFrame(_ frame: Frame, after id: Frame.ID) {
        guard let (fi, xi) = locate(id) else { return }
        folders[fi].frames.insert(frame, at: xi + 1)
    }

    /// The listed folder at this path, if any. By standardized path, as `addFolder` dedupes.
    func listedFolder(at url: URL) -> FolderSession? {
        let path = url.standardizedFileURL.path
        return folders.first { $0.url.standardizedFileURL.path == path }
    }

    /// Takes frames whose files have left their folder out of the model: no queued write,
    /// no render in flight, and nothing on screen still pointing at them. Move to Folder is
    /// the caller, after the files are already gone.
    func dropFrames(_ ids: Set<Frame.ID>) {
        for id in ids {
            pendingSaves[id]?.cancel()
            pendingSaves[id] = nil
            renders.invalidate(id)
        }
        for i in folders.indices { folders[i].frames.removeAll { ids.contains($0.id) } }
        selection.subtract(ids)
        if let c = cursor, ids.contains(c) { cursor = nil }
        if let a = anchor, ids.contains(a) { anchor = nil }
        if let v = viewerFrameID, ids.contains(v) { viewerFrameID = nil }
        if let t = galleryTopFrameID, ids.contains(t) { galleryTopFrameID = nil }
    }

    /// Puts frames that just arrived in a listed folder into it, in the folder's own name
    /// order, carrying their in-memory state. Not a rescan: a rescan re-reads every sidecar
    /// in the folder and would drop an edit to one of ITS frames still inside the 400 ms
    /// save window.
    func placeFrames(_ arrived: [Frame], in folderID: FolderSession.ID) {
        guard let fi = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let incoming = Set(arrived.map(\.id))
        var frames = folders[fi].frames.filter { !incoming.contains($0.id) } + arrived
        frames.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        folders[fi].frames = frames
    }

    /// Puts a session in place of the one at `index`, for a rename that changes its path.
    func replaceFolder(at index: Int, with session: FolderSession) {
        folders[index] = session
    }

    /// Drops a folder from the list with no undo of its own, for an undo that is taking
    /// back the move which added it.
    func forgetFolder(_ id: FolderSession.ID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        prune(at: index)
    }

    // MARK: develop commands

    /// Writes the defaults down for every undeveloped frame in the selection: the Positive
    /// button, Command D, the Positive menu item, the toolbar button and the context menu
    /// all run exactly this, with no sheet in front of any of them.
    ///
    /// It commits the value the frame was ALREADY being rendered through, so the picture
    /// does not change when it is pressed. That is the whole point: pressing Positive says
    /// "keep this", not "compute something new".
    func developSelection() {
        let targets = selectedFrames.filter { !$0.isDeveloped }
        guard !targets.isEmpty else { return }
        undoManager.beginUndoGrouping()
        for f in targets {
            guard let develop = renders.defaults.initial(for: f.sidecar) else { continue }
            apply({ SidecarEdits.setDevelop($0, develop) }, to: f.id, actionName: "Develop")
        }
        // "Undo Develop": what it writes is the Develop section's layer.
        undoManager.setActionName("Develop")
        undoManager.endUndoGrouping()
    }
    /// Gallery-level autocrop, over one or more selected frames.
    ///
    /// It runs the SAME path the crop tool runs, deliberately: render at proxy with the
    /// frame's orientation but no crop, `AutoCrop.detect`, `applyLearnedScale` so the
    /// folder's learned frame scale is both applied and extended, then `CropEditor.seed`.
    /// Reimplementing any of that here is how the grid and the editor would come to
    /// disagree about where the film edge is.
    ///
    /// It OVERWRITES an existing crop, because that is what every other selection-level
    /// action in this app does, and the whole run is one undo step.
    @MainActor
    func autoCropSelection(aspect: CropAspect = .original) async {
        let expected = expectedFilmSize
        await runCrop(selectedFrames.filter { $0.isDeveloped }) { frame in
            await self.detectCrop(frame, aspect: aspect, expected: expected)
        }
    }

    /// The one entry point for Stop: the wands' spinner, the Detect Crop sheet's
    /// Stop, and Escape all call this. It asks the run going now to end at its next check,
    /// which both loops make before a frame is read and again before its result is written.
    /// A frame whose read is under way finishes reading and is not written, so nothing
    /// changes after the press, and the run's one undo step covers exactly the frames that
    /// landed before it. With no run going it does nothing, so a stray press cannot end the
    /// next run before it starts.
    func stopRun() {
        guard enhanceRunning || autoCropProgress != nil else { return }
        stopRequested = true
    }

    /// Detect Crop's loop (`autoCropSelection`), frame by frame. `find` returns the geometry
    /// to write for one frame, or nil to leave it alone. It is a parameter so a test can stand
    /// in for the render and the detector, which the test rolls cannot run, and look at the
    /// model between frames, the same seam as the wands' `runWand`.
    @MainActor
    func runCrop(_ targets: [Frame], find: (Frame) async -> GeometrySettings?) async {
        guard !targets.isEmpty else { return }
        autoCropProgress = (0, targets.count)
        // One group around the whole run, closed after the last frame, so every crop lands
        // on the grid the moment it is found and Command Z still undoes the run.
        //
        // `groupsByEvent` goes off for the duration, which is what makes holding a group
        // open across an await safe. Left on, `UndoManager` closes a group of its own at
        // the end of the first pass of the run loop, the nesting never balances again, and
        // undo is dead for every other control afterwards.
        //
        // The group opens at the FIRST write, not before the first frame, because
        // `UndoManager` keeps a group that closes empty as a step of its own: a run stopped
        // before anything landed, or one where no frame was found, would leave a "Detect
        // Crop" that undoes nothing and sits over the step the user meant to reach. A run
        // with nothing written never opens one.
        let groupsByEvent = undoManager.groupsByEvent
        var grouped = false
        defer {
            if grouped {
                undoManager.setActionName("Detect Crop")
                undoManager.endUndoGrouping()
                undoManager.groupsByEvent = groupsByEvent
            }
            autoCropping = nil
            autoCropProgress = nil
            stopRequested = false
        }
        for (i, frame) in targets.enumerated() {
            // Stop is checked before a frame is read and again before its crop is
            // written, never in between, so a frame is written whole or not at all, and the
            // group closes in the `defer` as on a normal finish.
            if stopRequested { break }
            autoCropping = frame.id
            autoCropProgress = (i, targets.count)
            let found = await find(frame)
            if stopRequested { break }
            guard let geometry = found else { continue }
            if !grouped {
                undoManager.groupsByEvent = false
                undoManager.beginUndoGrouping()
                grouped = true
            }
            // Written here rather than collected, so this cell re-renders while the
            // detector moves on to the next one.
            apply({ SidecarEdits.setGeometry($0, geometry) }, to: frame.id, actionName: "Detect Crop")
        }
    }

    /// One frame of Detect Crop: the geometry the crop tool would seed for it, or nil when it
    /// has no develop, will not render, or the detector finds nothing.
    @MainActor
    private func detectCrop(_ frame: Frame, aspect: CropAspect, expected: FilmSize?) async -> GeometrySettings? {
        guard let develop = frame.sidecar.develop else { return nil }
        let g = frame.sidecar.geometry ?? GeometrySettings()
        let request = RenderRequest(
            imageURL: frame.url, develop: develop,
            geometry: GeometrySettings(rotate: g.rotate, flip: g.flip, straightenDegrees: 0, crop: nil),
            enhance: frame.sidecar.enhance ?? .identity, scale: .proxy)
        guard let result = try? await renders.service.render(request) else { return nil }
        let f = result.frame
        let displayAspect = CGFloat(f.width) / CGFloat(max(f.height, 1))
        let turn = QuarterTurn(degrees: g.rotate) ?? .none
        let originalAspect = turn.swapsAxes ? 1 / displayAspect : displayAspect
        // The negative arm: the same cached proxy decode,
        // encoded and oriented like the developed frame, so the perforation rung reads
        // the rebate and the sprocket holes where they actually are. Built inside the
        // detached task because the encode is a pixel loop.
        let service = renders.service
        let url = frame.url
        let raw = await Task.detached(priority: .userInitiated, operation: {
            let negative = (service as? CPURenderService).flatMap { try? $0.negativeArm(for: url, geometry: g) }
            return AutoCrop.detect(in: f, expecting: expected, negative: negative)
        }).value
        guard let found = applyLearnedScale(raw, folder: frame.url.deletingLastPathComponent()) else { return nil }
        var editor = CropEditor(geometry: g, originalAspect: originalAspect)
        editor.aspect = aspect
        editor.seed(found)
        return editor.geometry
    }

    func resetDevelopSelection() { applyToSelection(SidecarEdits.resetDevelop, actionName: "Reset Develop") }

    /// Reset Crop, the third of the three resets. Clears the whole
    /// geometry layer: crop, straighten, rotate and flip.
    ///
    /// Wider than the Reset button in the closeup's crop bar, which clears the crop and
    /// the angle and deliberately leaves the frame's orientation alone because the user is
    /// standing in the editor looking at it. From the grid there is no such context, and a
    /// reset that left a frame turned would leave nothing to undo it with.
    ///
    /// Goes through `applyToSelection` like the other two, so it covers the whole selection
    /// and lands as ONE undo step named "Reset Crop".
    func resetCropSelection() {
        applyToSelection({ SidecarEdits.setGeometry($0, GeometrySettings()) }, actionName: "Reset Crop")
    }

    // MARK: the closeup's crop overlay

    /// Command K, and the Crop button in the closeup's control bar.
    ///
    /// In the closeup it shows or hides the rectangle over the frame on screen. From the
    /// grid it opens the closeup on the cursor, or on the first selected positive frame,
    /// with the rectangle already up, which is how a crop pass over a roll starts.
    ///
    /// The gate is the one the separate crop tool had: a rectangle drawn over a negative
    /// is a crop of a different picture, so with nothing positive this does nothing.
    ///
    /// Raising the rectangle is not a selection event. A crop
    /// rectangle is per frame and the editor still edits the frame on screen alone, but
    /// that is a fact about what the DRAG writes, not a reason to throw away the other
    /// selected frames: Reset Crop over the selection is still selection wide, and the
    /// header says how many frames it is about to reach. From the grid it goes in through
    /// `openViewer(on:)`, so the inside and outside rule is the one place it lives.
    func toggleCropOverlay() {
        if showsCropOverlay { showsCropOverlay = false; return }
        if let v = viewerFrameID {
            guard frame(v)?.isDeveloped == true else { return }
            cursor = v
            showsCropOverlay = true
            return
        }
        guard let id = cropOverlayEntry else { return }
        openViewer(on: id)
        showsCropOverlay = true
    }

    /// Whether Command K has anything to do. Turning the rectangle OFF is always allowed,
    /// so the menu item and the button never trap the user inside it.
    var canToggleCropOverlay: Bool {
        if showsCropOverlay { return true }
        if let v = viewerFrameID { return frame(v)?.isDeveloped == true }
        return cropOverlayEntry != nil
    }

    /// The frame Command K opens the closeup on from the grid: the cursor when it is
    /// positive, otherwise the first positive frame of the selection.
    private var cropOverlayEntry: Frame.ID? {
        let order = framesInView
        if let c = cursor, order.first(where: { $0.id == c })?.isDeveloped == true { return c }
        return order.first { selection.contains($0.id) && $0.isDeveloped }?.id
    }

    // MARK: export

    /// The positive frames of the selection, in folder order. Undeveloped frames are
    /// skipped and the sheet names how many, the same contract Detect Crop uses.
    ///
    /// Building the targets is the model's job, because it reads the model. Exporting them
    /// is not: `BatchExport.run` in Core owns the loop and its one-frame-in-flight
    /// guarantee, and the sheet drives it.
    var exportTargets: [ExportTarget] {
        selectedFrames.compactMap { f in
            guard let develop = f.sidecar.develop else { return nil }
            return ExportTarget(url: f.url, stem: f.stem, develop: develop,
                                geometry: f.sidecar.geometry ?? GeometrySettings(),
                                enhance: f.sidecar.enhance ?? .identity,
                                lookID: f.sidecar.look, capture: f.sidecar.capture)
        }
    }

    /// A folder picked in the Export sheet, honored for the rest of this run of the app
    /// and never written to disk. Set only by an explicit pick, so exporting to the default
    /// does not quietly pin it.
    var sessionExportFolder: URL? = nil

    /// Where the Export sheet opens, in priority order: a folder picked in the sheet this
    /// session, then the folder Settings names if the setting is "Always this folder",
    /// then a Positives folder inside the folder being worked in.
    ///
    /// The default follows the folder you are in unless you change it within one open
    /// session. So the sheet's own pick is in memory and dies with the process, and the only
    /// destination that persists is the one chosen in Settings.
    ///
    /// Both stored destinations are honored only while they exist, so a folder the user
    /// has since deleted falls back rather than being handed to the exporter.
    ///
    /// Read what that check does NOT buy, because the obvious claim for it is false. An
    /// unmounted volume often leaves a stub directory at its mount point, so `fileExists`
    /// says yes and the export lands on the boot disk at a path that disappears the moment
    /// the real drive mounts over it. Catching that needs the volume's own resource values,
    /// not this. It is written down here rather than fixed because the fix is a build of
    /// its own and a comment claiming protection we do not have is worse than the gap.
    ///
    /// A plain path is enough only because this app is not sandboxed: it ships hardened
    /// runtime with no entitlements, and there is no `.entitlements` file in the tree. The
    /// day `com.apple.security.app-sandbox` is added, every stored folder outside the
    /// container needs a security-scoped bookmark the way `folderBookmarks` already does,
    /// and this field is the one that will fail silently on the second launch.
    var defaultExportFolder: URL? {
        if let u = sessionExportFolder, FileManager.default.fileExists(atPath: u.path) { return u }
        if prefs.exportDestination == .fixedFolder,
           let p = prefs.exportFolder, FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return selectedFolder?.url.appendingPathComponent("Positives", isDirectory: true)
    }

    func resetEnhanceSelection() { applyToSelection(SidecarEdits.resetEnhance, actionName: "Reset Enhance") }
}

/// Where exports go, as a setting rather than as something inferred from the last pick.
/// Two modes and no third: one that follows the folder you are
/// working in, one that names a single place for everything.
enum ExportDestination: String, CaseIterable, Sendable {
    /// A Positives folder inside whatever folder is open, created on export if missing.
    case positivesInFolder
    /// One folder chosen in Settings, for every export from every folder.
    case fixedFolder
}

/// App preferences: folder bookmarks, the last export choices, the inspector's folds.
/// Export mode, format and color space are preferences, never sidecar fields.
struct Preferences: Codable {
    var folderBookmarks: [Data] = []
    var exportMode = "neutral"
    var exportFormat = "heic"
    var exportColorSpace = "sRGB"
    /// Which of the two export destinations is in force, as a raw value.
    ///
    /// Optional, and ABSENT deliberately means `positivesInFolder`. That is the whole
    /// migration: an older preferences file can carry a saved `exportFolder` that was never
    /// a deliberate "always this folder" choice, so it is not read as one. The saved path
    /// is kept below, so choosing "Always this folder" arrives pre-filled with the last
    /// place they exported to.
    var exportDestinationMode: String? = nil
    /// The destination in force, over the storage above.
    var exportDestination: ExportDestination {
        get { exportDestinationMode.flatMap(ExportDestination.init(rawValue:)) ?? .positivesInFolder }
        set { exportDestinationMode = newValue.rawValue }
    }
    /// The one folder "Always this folder" writes to, as a path. Written only from
    /// Settings; the Export sheet's own pick lives in memory on `AppModel` instead.
    /// Optional for the same decode reason as the fields below it.
    var exportFolder: String? = nil
    /// The oldest histogram switch. Still written, so a blob an older build reads back
    /// decodes (a missing non-optional field resets every preference), and never read: an
    /// older blob carries `true` whether or not anyone chose it.
    ///
    /// The later switches beside it, `histogramShown` and `metadataShown`, are gone as
    /// fields: Histogram and Metadata fold from their titles, in `inspectorFold`. A blob that
    /// still carries them decodes and drops them, and an older build reading a newer blob
    /// finds them missing, which it reads as off (they were optional there).
    var showHistogram = true
    /// The folder selected last, by standardized path, so a relaunch reopens it.
    /// Optional for the decode reason below.
    var lastFolderPath: String? = nil
    /// The Base row's Adjust, which shows the two color axis rows.
    /// App-wide, remembered, closed until someone opens it. Optional for the decode reason
    /// below, so nil reads as closed. This alone decides whether the rows show
    /// (`PositiveRows.axesShown`), and the lit Base title says when a closed row holds an edit.
    var colourAxesOpen: Bool? = nil
    var showsColourAxes: Bool {
        get { colourAxesOpen ?? false }
        set { colourAxesOpen = newValue }
    }
    /// The inspector parts folded from their title, in `SectionFold.stored` form. App-wide
    /// and remembered, like the Adjust above. Optional for the decode reason below, so nil
    /// reads as the rolled-up default.
    ///
    /// A NEW key, on purpose. The older `closedSections` key, a closed set where nil meant
    /// all open, is not read, so an upgrade starts at the rolled-up default whatever an
    /// earlier build stored. Nor are the old Histogram and Metadata switches.
    var inspectorFold: [String: Bool]? = nil
    var sectionFold: SectionFold {
        get { SectionFold(stored: inspectorFold) }
        set { inspectorFold = newValue.stored }
    }
    /// The Metadata rows' history dropdowns, most recent first. Optional for the decode
    /// reason above.
    var cameraHistory: [String]? = nil
    var filmHistory: [String]? = nil
    var takenHistory: [String]? = nil
    /// Shipped look ids the user has deleted from the row. Reset Presets clears it.
    /// Optional on purpose: a non-optional field fails to decode against every preferences
    /// blob written before it existed, and load() would turn that into a silent reset of
    /// everything.
    var hiddenLookIDs: Set<String>? = nil
    /// The Tone row's Adjust, which shows the four tone rows. App-wide, remembered,
    /// closed until someone opens it, nil read as closed for the decode reason above. This
    /// alone decides whether the rows show (`ToneAdjustRows.shown`).
    var toneAdjustOpen: Bool? = nil
    var showsToneAdjust: Bool {
        get { toneAdjustOpen ?? false }
        set { toneAdjustOpen = newValue }
    }

    /// How far inside the detected film edge the autocrop box is pulled, in percent.
    ///
    /// Where the film edge IS is a measurement and belongs to the detector. How far in from
    /// it you like to sit is a preference, and a set of 114 hand-kept crops varies in exactly
    /// that amount, which is why nothing measured can settle it.
    ///
    /// One percent by default, and the sign is inward. Positive numbers shrink the box, which
    /// reads the way the setting is worded rather than the way `CropBox.expanded` is.
    ///
    /// Optional for the same reason as `hiddenLookIDs` above: a non-optional field fails to
    /// decode against every preferences blob written before it existed, and `load()` turns
    /// that into a silent reset of everything.
    var autoCropInsetPercent: Double? = nil

    /// The setting with its default applied, clamped to something that cannot destroy a crop.
    var autoCropInset: Double {
        min(max(autoCropInsetPercent ?? 1.0, 0), 10)
    }

    static let key = "FilmPositive.preferences"
    /// Where the preferences are kept. The app keeps them in the standard defaults. A test
    /// process gets a private in-memory store, because every `swift test` process on a Mac
    /// shares ONE defaults domain, `com.apple.dt.xctest.tool`. Two test runs at once read
    /// each other's folder bookmarks through cfprefsd, and no `setUp` in either process can
    /// stop that. Tests that touch preferences install a fresh store per test on top of this.
    static var store: PreferencesStore = NSClassFromString("XCTestCase") == nil
        ? UserDefaults.standard : InMemoryPreferences()
    static func load() -> Preferences {
        guard let d = store.data(forKey: key), let p = try? JSONDecoder().decode(Preferences.self, from: d) else { return Preferences() }
        return p
    }
    func save() { if let d = try? JSONEncoder().encode(self) { Self.store.set(d, forKey: Self.key) } }
}

/// The three calls `Preferences` makes on the defaults, so a test can keep them in memory.
protocol PreferencesStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: PreferencesStore {}

/// A store that lives and dies with its owner and is seen by no other process.
final class InMemoryPreferences: PreferencesStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

/// Stands in when the engine cannot start. Every render surfaces the reason.
struct FailingRenderService: RenderService {
    let message: String
    func render(_ request: RenderRequest) async throws -> RenderResult { throw RenderError.engineUnavailable(message) }
}
