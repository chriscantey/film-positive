import Foundation
import AppKit

/// One undo step per drag, and the reason it is a type rather than two calls.
///
/// `UndoManager.groupsByEvent` is true by default on the main run loop: the manager opens
/// a group at the top of each event and closes it at the bottom. A drag spans many events,
/// so a bare `beginUndoGrouping` at drag start leaves a nested group open across the
/// automatic close and the stack ends up in an inconsistent state. The supported way to
/// hold a group open across events is to turn event grouping off for exactly as long as
/// the group is open, which is what this does.
///
/// The failure that matters is the asymmetric one: if a drag never ends (the frame is
/// deselected, the window closes, the view is torn down mid-gesture) and the group is left
/// open with `groupsByEvent` still false, undo stops working app-wide for every other arm.
/// So closing is idempotent, and the inspector calls `end()` from `onDisappear` as well as
/// from the slider's own drag-ended callback.
///
/// It also makes a double-click reset one undo step (`reset(_:)`). A press on a track is a
/// drag of zero distance, so each click of a double click opens and closes a group of its
/// own, and the first one moves the value before the double click is recognized.
@MainActor
final class UndoCoalescer {
    private let undoManager: UndoManager
    private var isOpen = false
    private var restoreGroupsByEvent = true

    /// One press: the group it opened, when it opened and when it closed.
    private struct Press {
        let action: String
        let began: Date
        var ended: Date?
    }
    /// The last two presses, when the second followed the first within the double-click
    /// interval on the same control. Every press opens exactly one group, and `UndoManager`
    /// keeps a group even when it closes empty, so these are the top two steps on the stack.
    private var presses: [Press] = []
    /// Injectable for the tests, which cannot wait out a real interval.
    var clock: () -> Date = Date.init
    var doubleClickInterval: TimeInterval = NSEvent.doubleClickInterval

    init(_ undoManager: UndoManager) { self.undoManager = undoManager }

    var isGroupOpen: Bool { isOpen }

    /// Opens one group for the whole drag. A second call while open does nothing, so a
    /// stray `onEditingChanged(true)` cannot nest a group that never closes.
    func begin(_ actionName: String) {
        guard !isOpen else { return }
        let now = clock()
        if let last = presses.last, last.action == actionName, let ended = last.ended,
           now.timeIntervalSince(ended) <= doubleClickInterval {
            presses = [last]
        } else {
            presses = []
        }
        presses.append(Press(action: actionName, began: now))
        restoreGroupsByEvent = undoManager.groupsByEvent
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        undoManager.setActionName(actionName)
        isOpen = true
    }

    /// Closes the group and restores event grouping. Safe to call when nothing is open.
    func end() {
        guard isOpen else { return }
        isOpen = false
        undoManager.endUndoGrouping()
        undoManager.groupsByEvent = restoreGroupsByEvent
        if !presses.isEmpty { presses[presses.count - 1].ended = clock() }
    }

    /// A row's reset, made one undo step with the double click that asked for it.
    ///
    /// When the reset arrives while the last two presses form a double click on one control,
    /// both presses' groups are undone first, which puts the value back where it was before
    /// the first click, and the reset is then written as one new step from there. Undo after
    /// it returns that value, and redo resets again. The redo entries of the undone presses
    /// are dropped by the reset's own registration.
    ///
    /// The second press's group is still open when the double tap is recognized (the tap
    /// ends before the drag does), so it is closed here first; the drag's own `end()` that
    /// follows is then a no-op.
    ///
    /// A single click is untouched: it opens, sets and closes its one group at once, with no
    /// wait, and it is never undone here because one press is not a double click. Each undo
    /// also checks the top step still carries the press's action name, so a step anything
    /// else registered in between is never taken back.
    func reset(_ body: () -> Void) {
        end()
        if presses.count == 2, let second = presses.last,
           clock().timeIntervalSince(second.began) <= doubleClickInterval {
            for press in presses.reversed() {
                guard undoManager.canUndo, undoManager.undoActionName == press.action else { break }
                undoManager.undo()
            }
        }
        presses = []
        body()
    }
}
