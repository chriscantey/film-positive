import Foundation
import CoreGraphics
import FilmSidecar
import FilmPositiveCore

/// Pick Base: the eyedropper's model half.
///
/// The frame being SAMPLED is free to sit outside the selection being written. So there
/// are two sets here and they are deliberately not the same set: the frame on screen, which
/// the arrows walk over the whole roll, and the target set, which is the selection.
///
/// Everything a pick writes goes through `apply`, so the defaults commit, the undo
/// registration and the debounced save all come for free. The only thing this file adds on
/// top is the ONE undo group around all N frames and the sanity band.

/// The band a picked base has to land in before anything is written.
///
/// It is stated on the RAW channel ratio of the proxy decode, `r/g`, because that is the
/// quantity `BaseResolver` compares and stores. Rung 1 of `BaseResolver.resolve` returns
/// `develop.base.ratios` straight through as the resolution, and rung 2 builds the same
/// type from `Calibrator.rebateEstimate`'s raw means via `BaseResolver.ratios(fromRebate:)`,
/// so a sidecar pair and a film-edge pair are the same kind of number and this band has to
/// be about that number.
///
/// A raw ratio carries the camera's own white balance in it and sits low: the edge reader
/// measures R/G 0.4743 on one test frame, and the crop battery spans roughly 0.23 to
/// 0.62 across three real rolls. So the band is set wide enough that no real base is
/// refused. What it catches is the degenerate pick: a zero or non-finite green, an inverted
/// sample, a click on something that is not film at all. Refusing a real
/// base is worse than accepting a picture, because a picture is visible in the render and a
/// refusal reads as the tool being broken.
enum PickBaseBand {
    /// Raw `r/g`, inclusive. Below the low bound green is implausibly larger than red for
    /// any negative base; above the high bound the sample is not a base.
    static let lowRG = 0.15
    static let highRG = 3.0

    /// Nil when the pair is acceptable, otherwise the one line the user reads.
    static func refusal(for ratios: BaseRatios) -> String? {
        guard ratios.rg.isFinite, ratios.bg.isFinite, ratios.rg > 0, ratios.bg > 0 else {
            return "That patch did not measure. Pick a spot on the film base, away from the sprockets."
        }
        guard ratios.rg >= lowRG, ratios.rg <= highRG else {
            return String(format: "That does not look like film base (R/G %.2f, outside %.2f to %.2f). "
                          + "Pick a spot on the unexposed film between the frames.",
                          ratios.rg, lowRG, highRG)
        }
        return nil
    }
}

/// The target snapshot for a pick that was armed from one frame while the selection sat on
/// others ("Pick Film Color From This Frame…").
///
/// It is a side table rather than a stored property on `AppModel` because the pick's target
/// set has to survive a click that must NOT be allowed to change the selection, so it
/// cannot be derived from the selection at the moment the click lands. Entries are written
/// and cleared in exactly two places, both in this file, and always in the same statement
/// as `isPickingBase`, so nothing can observe a snapshot without also observing the flag
/// that publishes it.
@MainActor
enum PickBaseStore {
    static var snapshots: [ObjectIdentifier: [Frame.ID]] = [:]
}

extension AppModel {

    // MARK: entering and leaving the mode

    /// "Pick Film Color…", from the Positive menu, the context menu and the inspector's
    /// eyedropper button.
    ///
    /// From the grid it does not open the closeup. The loupe magnifies the hovered spot of
    /// the hovered thumbnail, so a click on a cell is a pick rather than a guess.
    func beginPickingBase() {
        guard !pickBaseTargets.isEmpty else { return }
        pickBaseNote = nil
        // The targets are snapshotted in both places. In the gallery, the click that lands
        // next must not be allowed to change the selection, so the selection cannot be
        // what is read at the moment it lands. In the closeup the acting set is the SHOWN
        // frame, and the arrows walk the roll while picking so a clean frame can be
        // sampled for this one: read live, the target would follow the walk onto the frame
        // being sampled. The snapshot keeps it on the frame the pick was armed on.
        PickBaseStore.snapshots[ObjectIdentifier(self)] = selectedFrames.map(\.id)
        // The rectangle and the eyedropper both want the whole uncropped frame and would
        // be drawing over each other, so raising one lowers the other.
        showsCropOverlay = false
        isPickingBase = true
    }

    /// Whether the eyedropper is armed over the GRID rather than over the closeup. Derived
    /// rather than stored: the closeup is open exactly when `viewerFrameID` is set, so a
    /// second flag could only ever disagree with it.
    var isPickingBaseInGallery: Bool { isPickingBase && viewerFrameID == nil }

    /// A click on a gallery thumbnail while the mode is on.
    ///
    /// `displayPoint` has already been through `GalleryPick.displayPoint`, so it is a point
    /// on FILM in the cell's fitted picture, normalized. Everything after that is the
    /// closeup's path verbatim: the same mapping, the same radius, the same
    /// `samplePatch`, the same `applyPickedBase`. The selection is untouched and the
    /// closeup does not open.
    func pickFromGallery(url: URL, geometry: GeometrySettings, at displayPoint: CGPoint) async {
        let targets = pickBaseTargets
        let point = PickBaseMapping(geometry: geometry).decodePoint(fromDisplay: displayPoint)
        guard let means = await renders.service.samplePatch(url: url, at: point,
                                                           radius: PickBasePatch.radius) else {
            pickBaseNote = "That patch did not measure. Pick a spot on the film base, "
                + "away from the sprockets."
            return
        }
        applyPickedBase(means, to: targets)
    }

    /// "Pick Film Color From This Frame…", from a gallery cell's right-click menu.
    ///
    /// The two halves of the eyedropper finally come apart here. `source` is the frame that
    /// gets SAMPLED, which is the one the user right-clicked, and `targets` is the set that
    /// gets WRITTEN, which is whatever was selected at that moment. Neither one is allowed
    /// to move the other: the item deliberately does NOT call `focusForContextMenu`, so a
    /// right click on a frame outside the selection samples that frame and still writes the
    /// selection, and the closeup opens without `openViewer(on:)` because that function
    /// applies Finder's rule and would pull the clicked frame into the selection.
    ///
    /// An empty selection targets the clicked frame alone, which is the only reading of
    /// "this frame" that does anything at all.
    func beginPickingBase(sampling source: Frame.ID, targets: [Frame.ID]) {
        guard framesInView.contains(where: { $0.id == source }) else { return }
        let ids = targets.isEmpty ? [source] : targets
        pickBaseNote = nil
        showsCropOverlay = false
        PickBaseStore.snapshots[ObjectIdentifier(self)] = ids
        // Not `openViewer(on:)`: selection, anchor and the grid cursor all stay where they
        // are, so returning to the grid afterwards finds the roll exactly as it was left.
        viewerFrameID = source
        isPickingBase = true
    }

    /// Escape, a completed pick, or leaving the closeup.
    func endPickingBase() {
        isPickingBase = false
        PickBaseStore.snapshots[ObjectIdentifier(self)] = nil
    }

    /// The frames a pick writes to.
    ///
    /// The snapshot taken when the mode was armed, while the mode is on, and the live
    /// selection otherwise. That one line is what lets `applyPickedBase`, `pickBaseHeader`,
    /// Reuse and Clear go on reading a single property while a pick armed from a gallery
    /// cell writes to frames the user may since have clicked away from.
    var pickBaseTargets: [Frame.ID] {
        if isPickingBase, let snapshot = PickBaseStore.snapshots[ObjectIdentifier(self)] {
            return snapshot
        }
        return selectedFrames.map(\.id)
    }

    /// Whether the eyedropper has anything to write to. Leaving the mode is always allowed.
    ///
    /// A selection that agrees on a black and white stock cannot be picked on, the same
    /// rule and the same reason the inspector's Base control is inert there: a mono
    /// profile has no color base, so `BaseResolver.resolve` answers 1:1 as black and white
    /// and a measured pair would be written and then ignored. Agreement is the condition, so a
    /// mixed selection holding one B&W frame stays live, exactly as the toggle does.
    ///
    /// It is stated HERE rather than on each control because three sites read it (the
    /// Positive menu, the two context items and the inspector button) and they must agree.
    var canPickBase: Bool {
        if isPickingBase { return true }
        let frames = selectedFrames
        guard !frames.isEmpty else { return false }
        return !frames.allSatisfy(isMonoStock)
    }

    /// Whether a pick armed FROM one frame would do anything, for the gallery item whose
    /// targets fall back to the clicked frame when nothing is selected.
    func canPickBase(from frame: Frame) -> Bool {
        let targets = selectedFrames.isEmpty ? [frame] : selectedFrames
        return !targets.allSatisfy(isMonoStock)
    }

    /// Whether this frame's EFFECTIVE stock resolves to a mono profile. Effective, not
    /// stored: an undeveloped frame has no stock of its own and would otherwise read as
    /// color whatever the defaults say it is about to become.
    func isMonoStock(_ frame: Frame) -> Bool {
        guard let profiles = renders.profiles,
              let stock = effectiveDevelop(for: frame)?.stock
        else { return false }
        return profiles.resolveFilm(stock).profile.isMono
    }

    /// The closeup header while the mode is on, naming BOTH the count it will write and
    /// the frame it is sampling, because those are different frames and the user has to be
    /// able to see that they are.
    var pickBaseHeader: String {
        let n = pickBaseTargets.count
        let frames = n == 1 ? "1 frame" : "\(n) frames"
        guard let shown = viewerFrame else { return "Pick the film color for \(frames)" }
        return "Pick the film color for \(frames), sampling \(shown.stem)"
    }

    // MARK: walking the roll without disturbing the target set

    /// The closeup's arrows while Pick Base is on.
    ///
    /// `navigate` cannot be used here and the reason is the whole point of the mode. With
    /// one frame selected it writes the cursor back into `selection`, so the first arrow
    /// press would silently move the target set onto the frame being sampled. With several
    /// selected it walks the SELECTION, so the leader frame that actually shows the film
    /// base is unreachable. This walks the whole roll and writes only the shown frame and
    /// the cursor.
    @discardableResult
    func walkRollForPickBase(_ move: GridNavigation<Frame.ID>.Move) -> Bool {
        let order = framesInView.map(\.id)
        let state = GridNavigation<Frame.ID>.State(selected: selection, anchor: nil,
                                                  cursor: viewerFrameID ?? cursor)
        guard let next = GridNavigation<Frame.ID>.move(move, order: order, state: state, columns: 1),
              let id = next.cursor else { return false }
        viewerFrameID = id
        cursor = id
        return true
    }

    /// One step in the closeup, whichever mode it is in. The header chevrons and the arrow
    /// keys both go through here so the two can never disagree about what an arrow means.
    @discardableResult
    func closeupStep(_ move: GridNavigation<Frame.ID>.Move) -> Bool {
        isPickingBase ? walkRollForPickBase(move) : navigate(move, columns: 1)
    }

    // MARK: the writes

    /// Write a measured base onto every target, as ONE undo step.
    ///
    /// `measured` is the three raw channel means `Calibrator.patchEstimate` returned. The
    /// ratios are derived with `BaseResolver.ratios(fromRebate:)`, the same function the
    /// film-edge path uses, so a picked pair and an edge pair are the same number computed
    /// the same way and nothing downstream can tell them apart.
    ///
    /// A refusal writes NOTHING and sets the note. It also leaves the mode on, so the user
    /// gets another click rather than having to re-arm the tool after a miss.
    func applyPickedBase(_ measured: [Double], to targets: [Frame.ID]) {
        guard !targets.isEmpty else {
            pickBaseNote = "Select the frames to write the base to first."
            return
        }
        guard let ratios = BaseResolver.ratios(fromRebate: measured) else {
            pickBaseNote = PickBaseBand.refusal(for: BaseRatios(rg: .nan, bg: .nan))
            return
        }
        if let refusal = PickBaseBand.refusal(for: ratios) {
            pickBaseNote = refusal
            return
        }
        // Rounded rather than truncated. The stored triple is a record of what was
        // measured, and a mean over tens of thousands of pixels deserves the nearer of the
        // two integers; the ratios that actually drive the render carry the full precision.
        let base = BaseSettings(mode: .measured, ratios: ratios,
                                measured: measured.map { Int($0.rounded()) })
        writeBase(base, to: targets, actionName: "Pick Film Color")
        lastPickedBase = ratios
        lastPickedMeasured = base.measured
        pickBaseNote = String(format: "Base set on %d %@: R/G %.3f, B/G %.3f",
                              targets.count, targets.count == 1 ? "frame" : "frames",
                              ratios.rg, ratios.bg)
        endPickingBase()
    }

    /// "Reuse Last Base": the same `BaseSettings` the last pick wrote, on the selection.
    /// Not a re-measurement, which is the point: the user liked that base and wants THAT
    /// number on these frames too.
    func reusePickedBase() {
        guard let ratios = lastPickedBase else { return }
        let targets = pickBaseTargets
        guard !targets.isEmpty else { return }
        let base = BaseSettings(mode: .measured, ratios: ratios, measured: lastPickedMeasured)
        writeBase(base, to: targets, actionName: "Reuse Last Film Color")
        pickBaseNote = String(format: "Base reused on %d %@: R/G %.3f, B/G %.3f",
                              targets.count, targets.count == 1 ? "frame" : "frames",
                              ratios.rg, ratios.bg)
    }

    /// The mono rule binds here too: a black and white frame never
    /// reads a base pair, so reusing one onto an all-mono selection would write a number
    /// the render ignores. A mixed selection stays live, like the toggle.
    var canReusePickedBase: Bool {
        guard lastPickedBase != nil, !pickBaseTargets.isEmpty else { return false }
        return !selectedFrames.allSatisfy(isMonoStock)
    }

    /// "Clear Base": back to `.anchor`, which hands the frame to auto again. Acts on the
    /// same set a pick acts on.
    func clearBase() {
        let targets = pickBaseTargets
        guard !targets.isEmpty else { return }
        writeBase(BaseSettings(mode: .anchor), to: targets, actionName: "Clear Film Color")
        pickBaseNote = nil
    }

    /// The Base control's write: Auto, Picked or None on every selected color frame,
    /// as ONE undo step through `applyToSelection`.
    ///
    /// Black and white frames are skipped, so a stored choice survives on them and comes
    /// back when the stock goes back to color. Picked on a selection where any color frame
    /// has no stored pair writes nothing and starts Pick Base instead, and the pick that
    /// completes writes `.measured`, which reads as Picked.
    ///
    /// Returns whether anything was written, because the segmented control keeps the segment
    /// it was clicked on when its binding does not change, and has to be told to redraw.
    @discardableResult
    func chooseBase(_ choice: BaseChoice) -> Bool {
        let colour = selectedFrames.filter { !isMonoStock($0) }
        guard !colour.isEmpty else { return false }
        if choice == .picked,
           colour.contains(where: { effectiveDevelop(for: $0)?.base.ratios == nil }) {
            beginPickingBase()
            return false
        }
        let mono = Set(selectedFrames.filter(isMonoStock).map(\.id))
        applyToSelection({ sidecar in
            guard let develop = sidecar.develop,
                  let next = choice.applied(to: develop), next != develop else { return sidecar }
            return SidecarEdits.setDevelop(sidecar, next)
        }, actionName: "Base", where: { !mono.contains($0.id) })
        return true
    }

    /// Whether any selected frame carries a measured pair worth clearing. A frame with no
    /// develop layer has nothing measured, so Clear Base on it would commit the defaults
    /// and change nothing the user can see.
    var canClearBase: Bool {
        // Same mono rule as Pick and Reuse: nothing measured on a black and white frame is
        // worth clearing, because nothing measured there ever reached the render.
        guard !selectedFrames.allSatisfy(isMonoStock) else { return false }
        return selectedFrames.contains { $0.sidecar.develop?.base.ratios != nil }
    }

    /// The one write path for all three commands. Explicitly grouped rather than left to
    /// `groupsByEvent` for the reason `applyToSelection` documents: an explicit balanced
    /// group holds the one-undo property in a test as well as in the app.
    ///
    /// Not `applyToSelection`, because the target set here is a LIST OF IDS rather than the
    /// live selection: a pick is written to the frames that were selected when the click
    /// landed, and the shown frame may not be one of them.
    private func writeBase(_ base: BaseSettings, to targets: [Frame.ID], actionName: String) {
        undoManager.beginUndoGrouping()
        for id in targets {
            apply({ SidecarEdits.setBase($0, base) }, to: id, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }
}
