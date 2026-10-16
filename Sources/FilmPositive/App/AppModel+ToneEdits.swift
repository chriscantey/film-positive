import Foundation
import FilmSidecar
import FilmPositiveCore

/// Levels and Curves over the selection, the way a slider writes: one absolute value
/// to every selected frame through `applyToSelection`, one undo step per call, and inside a
/// drag one step for the whole drag because the inspector holds an `UndoCoalescer` open.
extension AppModel {
    static let levelsAction = "Levels"
    static let curvesAction = "Curves"

    /// One Levels handle, written to every selected frame. Each frame's other handles stay as
    /// they were and bound the write for that frame (`LevelsHandle.setting`), so a black point
    /// can never cross the white point of any frame it lands on.
    func setLevelsHandle(_ handle: LevelsHandle, to value: Double) {
        applyToSelection({ s in
            let current = (s.enhance ?? .identity).levels
            let updated = handle.setting(current, to: value)
            return updated == current ? s : SidecarEdits.setLevels(s, updated)
        }, actionName: Self.levelsAction)
    }

    /// The Levels group's Reset: Levels back to identity on every selected frame, nothing else.
    func resetLevelsSelection() {
        applyToSelection({ s in
            (s.enhance ?? .identity).levels.isIdentity ? s : SidecarEdits.setLevels(s, .identity)
        }, actionName: "Reset Levels")
    }

    /// One curve, written whole to every selected frame. The other three curves of each frame
    /// stay as they were.
    func setCurve(_ channel: CurveChannel, to points: CurvePoints) {
        let held = points.quantized4
        applyToSelection({ s in
            var curves = (s.enhance ?? .identity).curves
            guard curves[keyPath: channel.path] != held else { return s }
            curves[keyPath: channel.path] = held
            return SidecarEdits.setCurves(s, curves)
        }, actionName: Self.curvesAction)
    }

    /// The Curves group's Reset: all four curves back to identity on every selected frame.
    func resetCurvesSelection() {
        applyToSelection({ s in
            (s.enhance ?? .identity).curves.isIdentity ? s : SidecarEdits.setCurves(s, .identity)
        }, actionName: "Reset Curves")
    }
}
