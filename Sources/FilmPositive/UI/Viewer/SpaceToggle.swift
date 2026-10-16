import SwiftUI

/// Space toggles the grid and the closeup, the way Space opens and closes a preview in
/// Finder. In the grid it is Return, in the closeup it is Escape, except that
/// it never cancels an armed eyedropper (Escape's first job there): a key that toggles
/// should only ever toggle.
///
/// Only the key DOWN acts. Held, Space repeats about ten times a second, and a toggle on
/// every repeat would flicker between the two views, so a repeat is swallowed.
enum SpaceToggle: Equatable {
    case open, close, swallow, notOurs

    static func action(phase: KeyPress.Phases, inCloseup: Bool, pickingBase: Bool) -> SpaceToggle {
        if phase == .repeat { return .swallow }
        guard phase == .down else { return .notOurs }
        if !inCloseup { return .open }
        return pickingBase ? .notOurs : .close
    }
}
