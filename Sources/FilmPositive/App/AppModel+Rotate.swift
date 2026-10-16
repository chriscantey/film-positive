import Foundation
import FilmSidecar
import FilmPositiveCore

/// Rotate Left and Right as model actions, so the Image menu (Command [ and
/// Command ]), the frame context menu and the inspector's Frame row are one path. Acts on
/// `selectedFrames`, which is the grid selection in the grid and the shown frame alone in
/// the closeup, as ONE undo step however many frames turn.
///
/// Only `rotate` changes. The crop is stored in the original frame's space and the viewer
/// converts it through the turn, so the crop turns with the picture without being touched.
extension AppModel {
    func rotateSelection(clockwise: Bool) {
        let degrees = clockwise ? 90 : -90
        applyToSelection({ sidecar in
            var g = sidecar.geometry ?? GeometrySettings()
            g.rotate = Self.quarterTurned(g.rotate, by: degrees)
            return SidecarEdits.setGeometry(sidecar, g)
        }, actionName: clockwise ? "Rotate Right" : "Rotate Left")
    }

    /// 0, 90, 180 or 270, whatever the sign of the step.
    nonisolated static func quarterTurned(_ rotate: Int, by degrees: Int) -> Int {
        ((rotate + degrees) % 360 + 360) % 360
    }
}
