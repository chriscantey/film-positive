import SwiftUI

/// The Develop button: the one control that turns negatives into positives, and the one
/// place its words are decided.
///
/// The vocabulary rule: Develop is what you do, a Positive is what you get. Every action
/// reads Develop: this button, the Develop menu item on Command D, the context menu item,
/// the closeup's "Develop first" hint and the shortcut catalog. The word Positive stays only
/// where it is the NOUN, the result: this button's done state (with the checkmark it labels
/// what the frame now is), the crop pane's "No Positive Yet", the Positives export folder,
/// and the app's own name.
///
/// The button never disappears and is the LAST ROW of the Develop section. When any
/// selected frame is unprocessed it is the tinted prominent button, "Develop" for one and
/// "Develop (3)" for several. When every selected frame is processed it stays exactly where
/// it was, quiet and disabled, reading "Positive" beside a checkmark. Never "All positive",
/// which reads wrong on a selection of one. A mixed selection lights it back up with the
/// count of the UNprocessed frames only.
///
/// The slot is fixed rather than the button appearing and vanishing, so a person pressing
/// it on the last unprocessed frame never watches the control they just pressed turn into a
/// different one. A button that is always there and goes quiet says the same thing without
/// moving anything.
enum PositiveButton {

    /// What the button SAYS, for a count of unprocessed frames in the selection.
    ///
    /// Pure and static so the wording has a test rather than a screenshot. Three shapes:
    /// nothing left to do (the noun, because the frames ARE positives now), exactly one
    /// frame (no count, because "Develop (1)" is a number nobody needs), and several frames
    /// (the count, because that is the fact a person wants before pressing a button that
    /// writes files).
    static func title(unprocessed: Int) -> String {
        switch unprocessed {
        case 0: return "Positive"
        case 1: return "Develop"
        default: return "Develop (\(unprocessed))"
        }
    }

    /// The tooltip. It says what pressing it DOES, which the title deliberately does not.
    static func help(unprocessed: Int) -> String {
        switch unprocessed {
        case 0: return "Every selected frame is already a positive"
        case 1: return "Develop the selected frame."
        default: return "Develop the selected frames."
        }
    }
}
