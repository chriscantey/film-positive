import Foundation
import AppKit

/// Move to Folder. The planner is `MovePlan`, and this is where the model follows the
/// files it moved.
///
/// **Which folder stays on screen.** The source, with the selection cleared, so sorting a
/// four-hundred-frame session is select, move, select, move without a click in between.
/// The destination joins the sidebar without being selected. The one exception is a move
/// that empties the source: there is nothing left to sort there, so the screen follows
/// the frames to where they went.
extension AppModel {

    /// The context menu's and the File menu's item: asks where, then moves the selection.
    func presentMoveSelection() {
        guard let source = selectedFolder, !selectedFrames.isEmpty else { return }
        // A turn later, so a context menu has finished closing before a modal opens.
        DispatchQueue.main.async { [weak self] in self?.runMovePanel(from: source.url) }
    }

    private func runMovePanel(from folder: URL) {
        guard !selectedFrames.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Here"
        let count = selectedFrames.count
        panel.message = count == 1 ? "Move 1 frame to the folder you choose" : "Move \(count) frames to the folder you choose"
        // Starting inside the roll makes a subfolder one click on New Folder.
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        moveSelection(to: url)
    }

    func moveSelection(to destination: URL) {
        moveFrames(selectedFrames.map(\.id), to: destination)
    }

    /// Moves frames on disk and in the model, as one undo step.
    ///
    /// `returning` is the undo's own call. It names the folder the forward move added to
    /// the list, so taking the move back also takes that row back when the folder is left
    /// empty, and it selects the frames that came home when their folder is already the
    /// one on screen. When it is not, the grid clears any selection made in the same turn
    /// as a folder change, so none is attempted.
    @discardableResult
    func moveFrames(_ ids: [Frame.ID], to destination: URL,
                    returning addedFolder: FolderSession.ID? = nil) -> Bool {
        let frames = ids.compactMap { frame($0) }
        guard !frames.isEmpty else { return false }
        // The sidecar on disk has to be the current one before it travels: an edit made in
        // the last 400 ms exists only in memory.
        for f in frames { flushPendingSave(f.id) }
        let plan: MovePlan
        do { plan = try MovePlan.make(moving: frames.map(\.url), to: destination) }
        catch let refusal as MovePlan.Refusal { lastError = refusal.sentence; return false }
        catch { lastError = "Nothing was moved: \(error.localizedDescription)"; return false }

        let sourceID = listedFolder(at: plan.sourceFolder)?.id
        let outcome = plan.run()
        if !outcome.problems.isEmpty {
            let moved = outcome.moved.count
            let head = moved == 0 ? "Nothing was moved." : "Moved \(moved) of \(plan.frames.count)."
            lastError = ([head] + outcome.problems).joined(separator: "\n")
        }
        guard !outcome.moved.isEmpty else { return false }

        let byOld = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, $0) })
        let arrived = outcome.moved.compactMap { pair -> Frame? in
            guard let f = byOld[pair.from] else { return nil }
            return Frame(url: pair.to, sidecar: f.sidecar, status: f.status)
        }
        dropFrames(Set(outcome.moved.map(\.from)))

        var added: FolderSession.ID?
        if let listed = listedFolder(at: plan.destination) {
            placeFrames(arrived, in: listed.id)
        } else if let session = addFolder(plan.destination, select: false) {
            added = session.id
        }
        let destinationID = listedFolder(at: plan.destination)?.id
        // The ids as the destination session holds them, not as the plan spelled them. A
        // scan can name the same file by another path (`/private/var` for `/var` on a temp
        // volume), and an undo keyed on the plan's spelling would find no frames to move.
        let movedNames = Set(outcome.moved.map { $0.to.lastPathComponent })
        let landed = folders.first { $0.id == destinationID }?.frames
            .filter { movedNames.contains($0.name) }.map(\.id) ?? arrived.map(\.id)

        let wasOnSource = sourceID != nil && selectedFolderID == sourceID
        if let addedFolder, let emptied = folders.first(where: { $0.id == addedFolder }), emptied.frames.isEmpty {
            // Undoing the move that listed it. The folder stays on disk: an empty
            // directory is the user's, made in the open panel, and not ours to delete.
            forgetFolder(emptied.id)
        }
        let sourceLeftEmpty = folders.first(where: { $0.id == sourceID })?.frames.isEmpty ?? true
        if wasOnSource, sourceLeftEmpty, let destinationID {
            selectedFolderID = destinationID
        } else if undoManager.isUndoing, let destinationID, selectedFolderID == destinationID {
            selection = Set(landed)
            cursor = landed.first
            anchor = landed.first
        } else if wasOnSource {
            selection = []
            cursor = nil
            anchor = nil
        }

        let back = landed
        let from = plan.sourceFolder
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            model.moveFrames(back, to: from, returning: added)
        }
        undoManager.setActionName("Move to Folder")
        undoManager.endUndoGrouping()
        return true
    }
}
