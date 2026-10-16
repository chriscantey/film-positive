import Foundation
import Observation

/// The Edit menu names what it will undo ("Undo Straighten", "Redo Move to Folder"),
/// the way every Mac app does.
///
/// Every edit calls `setActionName`, but `UndoManager` is not Observable, so a Commands
/// body that read `undoMenuItemTitle` directly would read it once and keep the stale title.
/// This mirrors the two titles into observable properties, refreshed on the undo manager's
/// own notifications, which fire on every group close, undo, redo and checkpoint.
@MainActor
@Observable
final class UndoTitleMirror {
    private(set) var undoTitle = "Undo"
    private(set) var redoTitle = "Redo"

    @ObservationIgnored private weak var undoManager: UndoManager?
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    nonisolated init() {}

    func watch(_ undoManager: UndoManager) {
        self.undoManager = undoManager
        let names: [Notification.Name] = [.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                                          .NSUndoManagerDidRedoChange, .NSUndoManagerCheckpoint]
        tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    /// Also called by hand after `removeAllActions`, which posts nothing.
    func refresh() {
        guard let um = undoManager else { return }
        let u = um.canUndo ? um.undoMenuItemTitle : "Undo"
        let r = um.canRedo ? um.redoMenuItemTitle : "Redo"
        if u != undoTitle { undoTitle = u }
        if r != redoTitle { redoTitle = r }
    }
}
