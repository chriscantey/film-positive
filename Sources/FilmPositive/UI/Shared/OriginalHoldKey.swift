import AppKit
import SwiftUI

/// Hold M, caught ABOVE the focus chain.
///
/// `onKeyPress` only fires while its view holds focus. A slider track is focusable, for its
/// arrow nudges, so a drag on it takes focus and the next M would go to the track, which
/// does not answer it, and on to the system beep.
///
/// The track keeps its focus on purpose: click a slider, then the arrows step it, and
/// Escape hands the keyboard back. So rather than taking focus away from
/// every control that can hold it, the showing view installs a local event monitor while
/// it is on screen. M down, its repeats and M up are handled there wherever focus is,
/// except in a text field, where M is a letter.
@MainActor
final class OriginalHoldKey {
    private var monitor: Any?

    /// `handle` answers whether the view took the phase. A phase it refuses (the crop
    /// editor is open, say) goes on down the chain as before.
    func install(_ handle: @escaping (KeyPress.Phases) -> Bool) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard let phase = Self.phase(type: event.type, isRepeat: event.type == .keyDown && event.isARepeat,
                                         characters: event.charactersIgnoringModifiers,
                                         modifiers: event.modifierFlags,
                                         textFieldHasFocus: event.window?.firstResponder is NSText)
            else { return event }
            return handle(phase) ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Which phase of the hold an event is, or nil when it is not a bare M outside a text
    /// field. Command, Option and Control M belong to the menus. Pure so it is testable.
    nonisolated static func phase(type: NSEvent.EventType, isRepeat: Bool, characters: String?,
                                  modifiers: NSEvent.ModifierFlags, textFieldHasFocus: Bool) -> KeyPress.Phases? {
        guard !textFieldHasFocus, characters?.lowercased() == "m",
              modifiers.intersection([.command, .option, .control]).isEmpty else { return nil }
        switch type {
        case .keyDown: return isRepeat ? .repeat : .down
        case .keyUp: return .up
        default: return nil
        }
    }
}
