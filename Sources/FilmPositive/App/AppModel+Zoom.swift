import CoreGraphics

/// The closeup's zoom commands: View > Zoom In, Zoom Out and Zoom to Fit on ⌘+, ⌘−
/// and ⌘0, plus ⌘= as a quiet alias for ⌘+ (see `ZoomKeyAlias`).
///
/// They act on the finished picture only. The crop rectangle keeps every drag for its own
/// grips and the eyedropper aims at the whole uncropped negative, so in either mode the
/// items grey out rather than zooming something the pointer is busy with.
extension AppModel {
    /// Whether the closeup is showing a picture the zoom can act on. The view reports a
    /// layout only while it draws the positive.
    var canZoomCloseup: Bool {
        viewerFrameID != nil && !showsCropOverlay && !isPickingBase && closeupZoom.layout != nil
    }

    var canZoomCloseupIn: Bool { canZoomCloseup && closeupZoom.canZoomIn }
    var canZoomCloseupOut: Bool { canZoomCloseup && closeupZoom.canZoomOut }
    var canZoomCloseupToFit: Bool { canZoomCloseup && !closeupZoom.isFit }

    func zoomCloseupIn() {
        guard canZoomCloseup else { return }
        closeupZoom.zoomIn(around: closeupPointer)
    }

    func zoomCloseupOut() {
        guard canZoomCloseup else { return }
        closeupZoom.zoomOut(around: closeupPointer)
    }

    func zoomCloseupToFit() { closeupZoom.reset() }

    var canZoomCloseupToActualSize: Bool { canZoomCloseup && closeupZoom.canShowActualSize }

    func zoomCloseupToActualSize() {
        guard canZoomCloseup else { return }
        closeupZoom.actualSize(around: closeupPointer)
    }
}
