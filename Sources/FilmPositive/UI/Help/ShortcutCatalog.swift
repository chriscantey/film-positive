import AppKit
import Foundation

/// Everything the keyboard and the pointer can do, as DATA.
///
/// One source, two readers. `KeyboardShortcutsSheet` renders it and
/// `ShortcutCatalogTests` checks it against the menu commands the app actually defines. A
/// hand-maintained shortcuts panel is wrong within about three builds, because somebody adds
/// a shortcut and forgets the doc, and every shortcuts panel in every app dies that way. Here
/// that is a build failure instead.
///
/// ORDERED SO WHAT NOTHING TEACHES COMES FIRST. Select all and shift and command select are
/// common to every app. Photo editing and the shortcuts that show and hide a preview are
/// what people need to be told.
///
/// So the slider gestures lead and the universal menu commands sit last, in a group named for
/// what they are. They are LISTED rather than omitted, and that is a deliberate engineering
/// choice as much as an editorial one: a panel that skipped them would need the drift test to
/// carry an allowlist of justified omissions, and an allowlist is simply a second thing that
/// goes stale. A complete panel makes the test a plain superset check with nothing to rot.
enum ShortcutCatalog {

    /// One line of the panel. `menuCommands` is the join to the drift test: it holds the
    /// literal `Button` or `Toggle` labels from the Commands block that this row covers, so
    /// renaming a command or changing its key fails the test rather than quietly disagreeing
    /// with the menu. A pure gesture has none, because no menu defines it.
    struct Row: Equatable, Sendable {
        var keys: String
        var what: String
        var menuCommands: [String] = []

        init(_ keys: String, _ what: String, menu: [String] = []) {
            self.keys = keys; self.what = what; self.menuCommands = menu
        }
    }

    struct Group: Equatable, Sendable {
        var title: String
        var rows: [Row]
    }

    static let groups: [Group] = [
        Group(title: "Sliders", rows: [
            Row("Double-click", "Reset that control to zero"),
            Row("Click the number", "Type a value. Past the end widens the track"),
            Row("Drag", "The value jumps to the pointer and follows it"),
            Row("⇧ drag", "Fine. A tenth of the speed, from where you started"),
            Row("⌥ drag", "Opens the range. The same track covers twice as much"),
            Row("← →", "A hundredth. One printer point on a color axis"),
            Row("⇧ ← →", "Fine. A tenth of a step"),
            Row("⌥ ← →", "Opens the range, so a step can go past the shown end"),
            Row("⎋", "Hand the keyboard back to the roll"),
        ]),
        Group(title: "A frame up close", rows: [
            Row("⌘↩", "Open the frame, and go back to the roll",
                menu: ["Open Frame", "Back to Grid"]),
            Row("Space", "Open the frame, and go back to the roll"),
            Row("Hold M", "As it was, without Enhance. Let go to put it back"),
            Row("← →", "Previous and next frame. Up and down do the same"),
            Row("Home  End", "First and last frame"),
            Row("⎋", "Back to the roll. Puts an armed eyedropper away"),
            Row("⌘K", "Show the crop rectangle", menu: ["Show Crop Overlay"]),
            Row("↩ in crop", "Keep the crop and put the rectangle away"),
            Row("⎋ in crop", "Put this frame's crop and angle back, and close it"),
            Row("Double-click", "Straighten back to 0, or on the angle, type one"),
            Row("⌘+  ⌘-", "Zoom in and out, around the pointer. ⌘= zooms in too",
                menu: ["Zoom In", "Zoom Out"]),
            Row("⌘0", "Fit the frame to the window", menu: ["Zoom to Fit"]),
            Row("⌘1", "Actual size, one pixel for one pixel", menu: ["Actual Size"]),
            Row("Drag", "Move around a zoomed frame"),
            Row("Pinch", "Zoom, around your fingers"),
            Row("Two fingers", "Move around a zoomed frame on a trackpad"),
            Row("⌘Y", "Show the histogram", menu: ["Show Histogram"]),
        ]),
        Group(title: "The roll", rows: [
            Row("Double-click", "Open a frame"),
            Row("⌘ click", "Add one frame to the selection, or remove it"),
            Row("⇧ click", "Select everything between here and the last one"),
            Row("← →", "Move the cursor"),
            Row("⇧ ← →", "Extend the selection"),
            Row("Page Up  Down", "Move the cursor a screen of rows"),
            Row("Hold M", "The selection without Enhance. Let go to put it back"),
        ]),
        Group(title: "Folders", rows: [
            Row("↑ ↓", "After a click, walk the folders"),
            Row("↩", "From the folders into the roll"),
            Row("⎋", "Let go of the folders"),
            Row("Right-click", "Give a folder a Finder color"),
        ]),
        Group(title: "Developing", rows: [
            Row("⌘D", "Develop the selection", menu: ["Develop"]),
            Row("⌘R", "Reset Enhance, and leave Develop alone", menu: ["Reset Enhance"]),
            Row("⇧⌘R", "Reset Develop to the film's defaults", menu: ["Reset Develop"]),
            // The Button's literal label is "All", because it is one item inside a Copy
            // Settings submenu. The test matches the label, not the path to it.
            Row("⌘C  ⇧⌘C", "Copy every setting on this frame", menu: ["All"]),
            Row("⇧⌘V", "Paste them onto the selection. So does ⌘V", menu: ["Paste Settings"]),
            Row("⌘[  ⌘]", "Rotate the selection left and right", menu: ["Rotate Left", "Rotate Right"]),
            Row("⌘E", "Export the selection", menu: ["Export…"]),
            Row("⇧⌘M", "Move the selection to another folder", menu: ["Move to Folder…"]),
            Row("⌘⌫", "Move the selection to the Trash. ⌘Z brings it back", menu: ["Move to Trash"]),
            Row("⌥⌘R", "Show the selection in Finder", menu: ["Reveal in Finder"]),
        ]),
        Group(title: "The usual ones", rows: [
            Row("⌘O", "Add a folder of scans", menu: ["Add Folder…"]),
            Row("⌘Z    ⇧⌘Z", "Undo and redo", menu: ["Undo", "Redo"]),
            Row("⌘X  ⌘C  ⌘V", "Cut, copy, paste. On frames, their settings", menu: ["Cut", "Copy", "Paste"]),
            Row("⌘A    ⇧⌘A", "Select all, and select none",
                menu: ["Select All", "Deselect All"]),
            Row("⌘/", "This window", menu: ["Keyboard Shortcuts"]),
        ]),
    ]

    /// Every menu command the panel claims to cover, for the test to compare against the
    /// Commands block.
    static var coveredMenuCommands: Set<String> {
        Set(groups.flatMap { $0.rows.flatMap(\.menuCommands) })
    }

    static var rowCount: Int { groups.reduce(0) { $0 + $1.rows.count } }

    /// How wide the key column has to be, MEASURED from the widest key in this file rather
    /// than guessed at.
    ///
    /// At a hardcoded 118, "Click the number" does not fit, so that one row wraps its key
    /// onto two lines and stands 32 pt tall in a list where every other row is 16. Nothing
    /// is clipped, which is exactly why it reads as an uneven gap rather than as a defect.
    ///
    /// Deriving it means adding a longer key can never bring that back. What a derived
    /// width CAN do is squeeze the descriptions until THEY wrap, so
    /// `ShortcutCatalogTests.testTheKeyColumnAndTheLongestDescriptionBothFit` holds the
    /// other end against the sheet's 560 pt.
    static let keyColumnWidth: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                                               weight: .regular)
        let widest = groups.flatMap(\.rows).map { ($0.keys as NSString).size(withAttributes: [.font: font]).width }
        return (widest.max() ?? 118).rounded(.up) + 2
    }()

    /// The widest description, in the body font, for the same test.
    static var widestDescriptionWidth: CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .body)
        return groups.flatMap(\.rows)
            .map { ($0.what as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
    }
}
