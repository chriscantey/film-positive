import SwiftUI
import AppKit
import FilmSidecar

/// The right-click menu for one frame, wherever that frame is on screen.
///
/// The gallery and the closeup both build it. Two copies of a fifteen-item menu drift on
/// the first change, so there is exactly one.
///
/// The selection rule is Finder's and it lives in `focusForContextMenu(on:)`: the frame you
/// right-clicked is what Copy reads, and the SELECTION is what a paste or a reset acts on.
/// A frame already inside a multi-selection leaves that selection alone, which is what makes
/// the menu behave the same way in the closeup, where three selected frames stay three
/// selected frames with one of them on screen.
struct FrameContextMenu: View {
    /// Where the menu was opened. One item is gallery only, because in the closeup the
    /// frame on screen IS the frame being right-clicked and "from this frame" would name
    /// the thing the plain Pick Base already samples.
    enum Site { case gallery, closeup }

    @Environment(AppModel.self) private var model
    let frame: Frame
    var site: Site = .gallery

    var body: some View {
        // The double-click and Command K, where a right click finds them.
        if site == .gallery {
            Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") { model.openViewer(on: frame.id) }
        }
        Button(model.showsCropOverlay ? "Hide Crop Overlay" : "Show Crop Overlay", systemImage: "crop") {
            model.focusForContextMenu(on: frame.id)
            if site == .gallery { model.cursor = frame.id }
            model.toggleCropOverlay()
        }
        .disabled(!frame.isDeveloped && !model.showsCropOverlay)
        Divider()
        // No sheet. The item commits the defaults the frames are already being
        // rendered through, which is what the toolbar button, Command D and the inspector's
        // Develop button all do. There is no mode to enter and nothing to choose: the
        // inspector rows are the controls, on every frame, all the time.
        Button("Develop", systemImage: "circle.lefthalf.striped.horizontal") {
            model.focusForContextMenu(on: frame.id)
            model.developSelection()
        }
        Divider()
        // The eyedropper, after Develop and before the Resets. Same Finder rule as
        // every other item here: the clicked frame joins the selection if it was outside
        // it, and the SELECTION is what gets written.
        Button("Pick Film Color…", systemImage: "eyedropper") {
            model.focusForContextMenu(on: frame.id)
            model.beginPickingBase()
        }
        .disabled(!model.canPickBase)
        .help("Click clear film on any frame to set the film color.")
        // The one item that does NOT take the Finder rule, and the reason it exists. Pick
        // Base… samples wherever the user then navigates to; this names the frame under the
        // cursor as the one to sample and leaves the selection exactly as it is, so "use
        // THAT frame's base on these ten" is one right click rather than a navigation.
        if site == .gallery {
            Button("Pick Film Color From This Frame…", systemImage: "eyedropper") {
                model.beginPickingBase(sampling: frame.id, targets: model.selectedFrames.map(\.id))
            }
            .disabled(!model.canPickBase(from: frame))
            .help("Use this frame's clear film for every selected frame.")
        }
        Button("Reuse Last Film Color", systemImage: "eyedropper.halffull") {
            model.focusForContextMenu(on: frame.id)
            model.reusePickedBase()
        }
        .disabled(model.lastPickedBase == nil)
        Button("Clear Film Color", systemImage: "eyedropper.full") {
            model.focusForContextMenu(on: frame.id)
            model.clearBase()
        }
        .disabled(!model.canClearBase)
        Divider()
        Button("Reset Develop", systemImage: "arrow.uturn.backward") {
            model.focusForContextMenu(on: frame.id)
            model.resetDevelopSelection()
        }
        Button("Reset Enhance", systemImage: "slider.horizontal.3") {
            model.focusForContextMenu(on: frame.id)
            model.resetEnhanceSelection()
        }
        Button("Reset Crop", systemImage: "crop") {
            model.focusForContextMenu(on: frame.id)
            model.resetCropSelection()
        }
        .help("Clear the crop, straighten and rotation.")
        Divider()
        // The Finder rule again: the clicked frame joins the selection if it was
        // outside it, and the whole selection turns.
        Button("Rotate Left", systemImage: "rotate.left") {
            model.focusForContextMenu(on: frame.id)
            model.rotateSelection(clockwise: false)
        }
        Button("Rotate Right", systemImage: "rotate.right") {
            model.focusForContextMenu(on: frame.id)
            model.rotateSelection(clockwise: true)
        }
        Divider()
        // Copy reads THE CLICKED FRAME, never the selection: one frame's settings are what
        // a paste reproduces, and a right click names which one. Paste is the half that
        // acts on the whole selection.
        // Flat, not a submenu. Four items read at a glance, and a submenu hides them behind
        // a hover.
        ForEach(FrameSettingsSection.allCases, id: \.self) { section in
            Button("Copy \(section.title)", systemImage: section.symbol) {
                model.copySettings([section], from: frame.id)
            }
            // A frame with no positive has no positive to copy; enhance and crop are
            // copyable at their identity value, where a paste means "clear it".
            .disabled(section == .positive && !frame.isDeveloped)
        }
        Button("Copy All", systemImage: "square.on.square") {
            model.copySettings(FrameSettingsSection.all, from: frame.id)
        }
        // Disabled live. A context menu is rebuilt every time it opens, so this reads the
        // real pasteboard at the moment the user looks at it. The Edit menu's copy of this
        // item cannot do the same and stays enabled instead; see `AppCommands`.
        // The title qualifies itself when the pasteboard carries no positive section, so
        // the menu says what it is about to do rather than leaving the user to notice
        // afterwards that the Positive block did not move. Same live read as `.disabled`
        // below, and legal for the same reason: this menu is rebuilt every time it opens.
        Button(model.pasteSettingsTitle, systemImage: "doc.on.clipboard") {
            model.focusForContextMenu(on: frame.id)
            model.pasteSettings()
        }
        .disabled(!model.canPasteSettings)
        .help("Apply the copied settings to every selected frame")
        Divider()
        Button("Duplicate", systemImage: "plus.square.on.square") {
            model.focusForContextMenu(on: frame.id)
            model.duplicateSelection()
        }
        .help("Copy the frame next to the original, with no undo.")
        // The same Finder rule: the clicked frame joins the selection if it was
        // outside it, and the whole selection moves.
        Button("Move to Folder…", systemImage: "folder.badge.plus") {
            model.focusForContextMenu(on: frame.id)
            model.presentMoveSelection()
        }
        .help("Move to a folder you pick and add it to the sidebar.")
        // Same Finder rule, and the same companions as a move.
        Button("Move to Trash", systemImage: "trash") {
            model.focusForContextMenu(on: frame.id)
            model.trashSelection()
        }
        .help("Move to the Trash (Undo brings them back).")
        Button("Export…", systemImage: "square.and.arrow.up") {
            model.focusForContextMenu(on: frame.id)
            model.showsExportSheet = true
        }
        .disabled(!frame.isDeveloped)
        Divider()
        Button("Reveal in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([frame.url])
        }
    }
}
