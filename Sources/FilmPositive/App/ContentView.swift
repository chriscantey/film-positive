import SwiftUI
import AppKit
import Combine
import FilmPositiveCore

/// The three column minimums and the window minimum they add up to. Side columns never
/// clip: both sidebars have minimum widths, the center column compresses, and the window
/// minimum equals the sum.
///
/// Measured through the Accessibility tree, in the closeup, at a 1100 pt window
/// minimum. The finding that shapes every number here: `NavigationSplitView` does NOT
/// compress a column that will not fit. It overflows the window instead, centered, so BOTH
/// side columns clip at once. The split group reported x=363 w=1194 inside a window at
/// x=410 w=1100, hanging 47 pt off each edge, and the inspector column at x=1257 w=300 ran
/// to 1557 against a window right edge of 1510. Inside it the enhance readouts (x=1481
/// w=46) were cut at 1510 and the base eyedropper (x=1512 w=14) was entirely off screen.
///
/// So the window minimum cannot be a number somebody liked: it has to be the sum of what
/// the columns actually take, or the overflow comes straight back.
enum ShellLayout {
    /// The sidebar never compresses toward its stated minimum on its own. Measured at 240 pt
    /// of content in a 248 pt column at every window width, ideal and minimum alike, in both
    /// the grid and the closeup. So its minimum IS its ideal: a `min: 200` would under-state
    /// the sum by 40 pt, which is 40 pt of guaranteed clip. The user can still widen it to
    /// `sidebarMax` by dragging.
    static let sidebarMin: CGFloat = 240
    static let sidebarIdeal: CGFloat = 240
    static let sidebarMax: CGFloat = 320

    /// What the closeup's crop control bar needs. This is the center column's real floor,
    /// not a guess: the bar's roomy controls span 781 pt, which inside a 645 pt column hung
    /// 68 pt off each side of it. `CropControlBar` carries a compact layout that lives
    /// inside this number, and the bar takes its roomy layout back whenever there is space.
    static let contentMin: CGFloat = 560
    static let contentIdeal: CGFloat = 800

    /// The widest one-line row sets this. A row is one line, so the minimum follows the ROW
    /// rather than the row being squeezed to fit the minimum.
    ///
    /// The column spends 62 pt around its content (a 300 pt column held 238 pt of rows).
    /// The widest row is the Green axis row. Its label `Green ↔ Magenta` needs 134 pt on
    /// one line, and at 330 it came back 82 x 32, two lines breaking as `Green ↔` /
    /// `Magenta`. Nothing clipped, but the row's pitch went to 53 pt against 41 pt for every
    /// other row in the panel, which reads as an uneven gap rather than as a defect.
    /// Measured on screen by sweeping the column: it wraps at 355 and under, one line at
    /// 360 and over.
    ///
    /// The ideal matters as much as the minimum. A default width inside the wrapping band
    /// makes the wrap the ordinary appearance on first open. So 360 holds the row and 370
    /// gives the default 10 pt of slack.
    ///
    /// The cost is 30 pt on the whole window's minimum over a 330 pt column. Flanking the
    /// track with its end words instead spends about 45 pt of TRACK at this column width,
    /// and the track is the thing a person drags.
    static let inspectorMin: CGFloat = 360
    static let inspectorIdeal: CGFloat = 370
    static let inspectorMax: CGFloat = 420

    /// One divider between each pair of columns. The AX tree reported 0 pt and 1 pt for the
    /// two splitters, so 1 pt each is the conservative bound: it spends a point of slack and
    /// can never under-provision.
    static let dividerWidth: CGFloat = 1
    static let dividerCount: CGFloat = 2

    /// The split view insets its leading column by 8 pt (sidebar content at x=371 inside a
    /// split group at x=363). No column declares that width and the window still pays for it.
    static let splitInset: CGFloat = 8

    /// The window minimum, derived. Nothing may hardcode it.
    static var windowMinWidth: CGFloat {
        sidebarMin + contentMin + inspectorMin + dividerWidth * dividerCount + splitInset
    }

    static let windowMinHeight: CGFloat = 700
}

/// The one window: sidebar, grid, inspector, always three columns. The arms are separate
/// files under UI/: Sidebar, Grid, Inspector (with the Looks row and the histogram), Crop.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    /// One negative cache for the window, shared by the grid and the viewer so stepping
    /// through frames with the arrow keys never decodes the same negative twice.
    @State private var thumbnails = NegativeThumbnailCache()

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: ShellLayout.sidebarMin,
                                                ideal: ShellLayout.sidebarIdeal,
                                                max: ShellLayout.sidebarMax)
        } content: {
            Group {
                // Two states, not three. The closeup IS the crop editor: the control bar
                // lives under the picture whether the rectangle is showing or not, and one
                // Done goes back to the grid.
                if let f = model.viewerFrame {
                    ViewerView(frame: f, thumbnails: thumbnails)
                } else {
                    GridView(thumbnails: thumbnails)
                }
            }
            .navigationSplitViewColumnWidth(min: ShellLayout.contentMin, ideal: ShellLayout.contentIdeal)
            // The Export sheet is mounted here rather than on the grid so File > Export
            // (Command E) reaches it from the closeup too.
            .sheet(isPresented: $model.showsExportSheet) { ExportSheet() }
            // Unconditional: the sheet opens every time Detect Crop is pressed, including on
            // frames that are already cropped, so a group can be redone. Mounted here rather
            // than on the inspector so it survives the inspector redrawing under a selection
            // change while the sheet is up.
            .sheet(isPresented: $model.showsAutoCropSheet) { AutoCropSheet() }
            .sheet(isPresented: $model.showsShortcuts) { KeyboardShortcutsSheet() }
        } detail: {
            InspectorView()
                .navigationSplitViewColumnWidth(min: ShellLayout.inspectorMin,
                                                ideal: ShellLayout.inspectorIdeal,
                                                max: ShellLayout.inspectorMax)
        }
        .navigationSplitViewStyle(.balanced)
        // The whole window takes a Finder drag: a folder is added, a file adds the folder it
        // is in. The Folders panel highlights while a drag is over the window.
        .onDrop(of: [.fileURL], isTargeted: $model.isDropTargeted) { providers in
            model.addDropped(providers)
            return true
        }
        .fileImporter(isPresented: $model.addFolderRequested, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.addFolder(url) }
        }
        // The list has to be right the moment the user looks at the window, and this is that
        // moment. One resolve and one `fileExists` per folder: no FSEvents, no watcher, no
        // timer. Deliberately here rather than in `AppModel.init` so the observer's life is
        // the window's and a unit test never has an activation fired at it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.sweepFoldersIfIdle()
            // A color set in Finder while the app was in the background shows now.
            model.refreshFolderColours()
        }
        // Things that vanished get one line at the bottom of the window, not an alert.
        .overlay(alignment: .bottom) { NoticeBanner() }
        // Any engine failure reaches the user with the complete error text.
        .alert("Film Positive", isPresented: Binding(get: { model.lastError != nil || model.renders.lastError != nil },
                                                    set: { if !$0 { model.lastError = nil; model.renders.lastError = nil } })) {
            Button("OK") { model.lastError = nil; model.renders.lastError = nil }
        } message: {
            Text(model.lastError ?? model.renders.lastError ?? "")
        }
    }
}
