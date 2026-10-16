import Foundation
import AppKit
import FilmSidecar
import FilmPositiveCore

/// The frame context menu's two file-and-clipboard actions. Reset Crop lives on the model
/// itself beside the other two resets. These two are here because neither is an edit of a
/// sidecar the way every other action in this app is.
extension AppModel {

    // MARK: Duplicate

    /// Duplicates every selected frame on disk, beside the original.
    ///
    /// The new files become the selection, so the obvious next move (duplicate, then grade
    /// the copy differently) works without a click in between.
    func duplicateSelection() {
        let targets = selectedFrames
        guard !targets.isEmpty else { return }
        // A snapshot of values, so inserting into the folder under the loop cannot move the
        // ground out from under it; every step re-locates its original by id.
        let made = targets.compactMap { duplicate($0.id) }
        guard !made.isEmpty else { return }
        selection = Set(made)
        cursor = made.first
        anchor = made.first
        // Duplicating is a request to be shown the result, so the first copy is scrolled to.
        if let first = made.first { requestScroll(to: first) }
    }

    /// One frame: the raw copied under the next free name, the sidecar written beside it,
    /// the new frame inserted right after the original.
    ///
    /// **Not undoable, on purpose.** Everything else in this app undoes because everything
    /// else is a value in memory; this one puts a file on the user's disk, and deleting a
    /// file behind their back is not something we do silently. The menu item says so.
    ///
    /// The sidecar is WRITTEN from the frame's live state rather than copied byte for byte.
    /// Two reasons: an edit made in the last 400 ms exists only in memory (hence the flush
    /// of the original first, so the two files agree), and the copy's `source` block has to
    /// name the copy rather than the file it came from.
    @discardableResult
    func duplicate(_ id: Frame.ID) -> Frame.ID? {
        guard let frame = frame(id) else { return nil }
        flushPendingSave(id)
        let url: URL
        do {
            url = try DuplicateName.nextURL(for: frame.url)
            try FileManager.default.copyItem(at: frame.url, to: url)
        } catch {
            lastError = "Could not duplicate \(frame.name): \(error.localizedDescription)"
            return nil
        }
        var sidecar = frame.sidecar
        if let source = try? SidecarStore.source(for: url) { sidecar.source = source }
        // A failure here leaves a perfectly good copy of the raw with its settings only in
        // memory, which is worth reporting and is not worth throwing the copy away over.
        do { try writeSidecar(sidecar, for: url) }
        catch { lastError = "Copied \(frame.name) but could not write \(url.lastPathComponent)'s settings: \(error.localizedDescription)" }
        insertFrame(Frame(url: url, sidecar: sidecar, status: .ok), after: id)
        return url
    }

    // MARK: Copy and paste settings

    /// The frame a Copy from the Edit menu reads: the keyboard cursor when it is part of
    /// the selection, otherwise the first selected frame in folder order. The context menu
    /// does not use this, because a right click names its own frame.
    var copySettingsSource: Frame? {
        if let c = cursor, selection.contains(c), let f = framesInView.first(where: { $0.id == c }) { return f }
        return framesInView.first { selection.contains($0.id) }
    }

    /// Puts one frame's chosen sections on the pasteboard, replacing whatever was there.
    func copySettings(_ sections: Set<FrameSettingsSection>, from id: Frame.ID,
                      to pasteboard: NSPasteboard = .general) {
        guard let frame = frame(id),
              let payload = FrameSettingsPayload.copying(sections, from: frame.sidecar,
                                                         effective: effectiveDevelop(for: frame)) else { return }
        FrameSettingsPasteboard.write(payload, to: pasteboard)
    }

    /// Applies the copied sections to every selected frame, as ONE undo step.
    ///
    /// Goes through `applyToSelection`, so it is the same path a slider edit takes: sidecars
    /// save, renders invalidate, and one Command Z reverts every frame it touched. A paste
    /// with nothing on the pasteboard is a no-op, which is why the Edit menu item can stay
    /// enabled (see `AppCommands`).
    func pasteSettings(from pasteboard: NSPasteboard = .general) {
        guard let payload = FrameSettingsPasteboard.read(from: pasteboard) else { return }
        applyToSelection({ payload.applied(to: $0) }, actionName: "Paste Settings")
        // Say what did NOT happen, quietly, in the column the user is already looking at.
        // A paste that leaves the target's whole Positive block alone is otherwise silent
        // and reads as a paste that failed.
        pasteNote = payload.partialPasteNote
    }

    /// Whether anything is on the pasteboard to paste. Read at the moment a menu is built.
    var canPasteSettings: Bool { FrameSettingsPasteboard.hasPayload() }

    /// The Paste item's wording for a menu that is rebuilt every time it opens, which is
    /// the frame context menu. Reads the real pasteboard, live.
    var pasteSettingsTitle: String { FrameSettingsPasteboard.pasteMenuTitle() }
}
