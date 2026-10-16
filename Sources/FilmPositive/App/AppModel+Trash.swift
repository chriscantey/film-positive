import Foundation
import AppKit

/// Move to Trash: Command Backspace, the Finder key. The files go to the real Trash with
/// their companions (`TrashPlan`), and Command Z brings them back, so there is no "are you
/// sure" dialog in front of it. A reversible action does not ask.
extension AppModel {

    func trashSelection() { trashFrames(selectedFrames.map(\.id)) }

    /// File > Reveal in Finder: the selection, selected in one Finder window.
    func revealSelectionInFinder() {
        let urls = selectedFrames.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Trashes frames on disk and takes them out of the model, as one undo step.
    @discardableResult
    func trashFrames(_ ids: [Frame.ID]) -> Bool {
        let frames = ids.compactMap { frame($0) }
        guard !frames.isEmpty else { return false }
        // The sidecar goes with the scan, so it has to be the current one: an edit made in
        // the last 400 ms exists only in memory, and an undo brings back what is on disk.
        for f in frames { flushPendingSave(f.id) }
        let plan: TrashPlan
        do { plan = try TrashPlan.make(trashing: frames.map(\.url)) }
        catch let refusal as MovePlan.Refusal {
            lastError = refusal.sentence.replacingOccurrences(of: "Nothing was moved", with: "Nothing went to the Trash")
            return false
        }
        catch { lastError = "Nothing went to the Trash: \(error.localizedDescription)"; return false }

        let outcome = plan.run(trash: trashFile)
        if !outcome.problems.isEmpty {
            let n = outcome.trashed.count
            let head = n == 0 ? "Nothing went to the Trash." : "Moved \(n) of \(plan.frames.count) to the Trash."
            lastError = ([head] + outcome.problems).joined(separator: "\n")
        }
        guard !outcome.trashed.isEmpty else { return false }

        let gone = Set(outcome.trashed.map(\.frame))
        // The frame the cursor lands on: the first survivor after the first one trashed, or
        // before it at the end of the roll. So pressing the key again trashes the next frame,
        // which is how culling a roll with it feels right.
        let shown = framesInView
        let firstGone = shown.firstIndex { gone.contains($0.id) }
        let neighbour = firstGone.flatMap { i in
            shown[i...].first { !gone.contains($0.id) } ?? shown[..<i].last { !gone.contains($0.id) }
        }
        let wasShowing = viewerFrameID.map(gone.contains) ?? false
        dropFrames(gone)
        if firstGone != nil {
            selection = neighbour.map { [$0.id] } ?? []
            cursor = neighbour?.id
            anchor = neighbour?.id
            if wasShowing { viewerFrameID = neighbour?.id }
        }

        let record = outcome.trashed
        let restoring = frames.filter { gone.contains($0.id) }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            model.restoreFromTrash(record, frames: restoring)
        }
        undoManager.setActionName("Move to Trash")
        undoManager.endUndoGrouping()
        return true
    }

    /// The undo: each file back to where it was, then the frames back in their folder and
    /// selected. A name taken in the meantime is not overwritten; that frame stays in the
    /// Trash and the banner says so.
    func restoreFromTrash(_ trashed: [(frame: URL, files: [(from: URL, to: URL)])], frames: [Frame]) {
        let fm = FileManager.default
        var back: [Frame] = []
        var problems: [String] = []
        for item in trashed {
            var done: [(from: URL, to: URL)] = []
            var failed = false
            for file in item.files {
                do { try fm.moveItem(at: file.to, to: file.from); done.append(file) }
                catch { problems.append("\(file.from.lastPathComponent): \(error.localizedDescription)"); failed = true; break }
            }
            if failed {
                // Whole or not at all, as on the way out.
                for file in done.reversed() { try? fm.moveItem(at: file.from, to: file.to) }
                continue
            }
            if let f = frames.first(where: { $0.url == item.frame }) { back.append(f) }
        }
        if !problems.isEmpty {
            lastError = (["Could not bring everything back from the Trash."] + problems).joined(separator: "\n")
        }
        guard !back.isEmpty else { return }
        var byFolder: [URL: [Frame]] = [:]
        for f in back { byFolder[f.url.deletingLastPathComponent(), default: []].append(f) }
        for (dir, arrived) in byFolder {
            if let listed = listedFolder(at: dir) { placeFrames(arrived, in: listed.id) }
        }
        let ids = back.map(\.id)
        if back.contains(where: { listedFolder(at: $0.url.deletingLastPathComponent())?.id == selectedFolderID }) {
            selection = Set(ids)
            cursor = ids.first
            anchor = ids.first
        }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in model.trashFrames(ids) }
        undoManager.setActionName("Move to Trash")
        undoManager.endUndoGrouping()
    }
}
