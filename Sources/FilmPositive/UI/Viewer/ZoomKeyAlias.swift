import AppKit

/// ⌘= zooms in, the way it does in Preview and Safari.
///
/// The menu item is ⌘+ because that is what the menu should read,
/// but on a US keyboard + is the shifted =, and the key people actually press is ⌘= with no
/// shift. A second menu item would put "Zoom In" in the View menu twice, so the unshifted
/// key is caught here instead, by a local monitor installed while the closeup is up. A
/// local monitor sees the key before the menu's key equivalents do, so nothing fires twice.
@MainActor
final class ZoomKeyAlias {
    private var monitor: Any?

    func install(_ zoomIn: @escaping () -> Bool) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Self.isZoomInAlias(characters: event.charactersIgnoringModifiers,
                                     modifiers: event.modifierFlags) else { return event }
            return zoomIn() ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Command and = and no other modifier. Pure so the rule is testable.
    nonisolated static func isZoomInAlias(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        characters == "=" && modifiers.intersection([.command, .shift, .option, .control]) == .command
    }
}
