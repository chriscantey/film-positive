import Foundation
import FilmSidecar
import FilmPositiveCore

/// Reset for the Frame section's header, taking rotate, mirror and crop back to none. Every
/// other section's header carries one, so a section whose header slot is empty reads as a
/// section you cannot undo.
///
/// It is its own call rather than a second caller of `resetCropSelection` for one reason
/// that shows up in the Edit menu: an undo named "Reset Crop" after pressing a button
/// labeled Reset in a section labeled Frame is the app describing the same action two
/// ways. The mechanics are identical, because a default `GeometrySettings` IS the whole of
/// the frame geometry: rotate 0, flip false, straighten 0, crop nil.
extension AppModel {

    /// One undo step over the whole selection, through the same funnel every other edit
    /// uses, so a selection of forty frames is one Command Z.
    func resetFrameSelection() {
        applyToSelection({ SidecarEdits.setGeometry($0, GeometrySettings()) }, actionName: "Reset Frame")
    }

    /// Whether the header's Reset is live: at least one selected frame carries geometry
    /// that is not the identity.
    ///
    /// Asked of the frames rather than of `SelectionSummary`, because the summary carries
    /// no geometry field and one selected frame with a crop is enough to make the button
    /// meaningful even when the rest of the selection is untouched.
    var hasFrameGeometry: Bool {
        selectedFrames.contains { !($0.sidecar.geometry ?? GeometrySettings()).isIdentity }
    }
}
