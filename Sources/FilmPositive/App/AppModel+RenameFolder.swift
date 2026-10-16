import Foundation

/// The checks a new folder name passes before anything on disk moves, and the move itself.
///
/// A sidebar folder has no name of its own apart from the one on disk, so a rename is a
/// rename of the folder, the way Finder does it. The frames and sidecars inside travel with
/// it, and so does its Finder color tag, which is stored on the folder.
enum FolderRename {
    enum Refusal: Error, Equatable {
        case empty
        case badCharacter
        /// The name of the item already in the parent, as the disk spells it.
        case taken(String)
        /// The move failed: the system's own sentence, usually a permission refusal.
        case failed(String)

        /// The line the banner shows while the name field stays open.
        var sentence: String {
            switch self {
            case .empty: return "A folder needs a name."
            case .badCharacter: return "A folder name cannot contain a slash or a colon."
            case .taken(let name): return "Another item in the same place is already named \(name)."
            case .failed(let why): return "Could not rename the folder: \(why)"
            }
        }
    }

    /// The typed name with surrounding spaces and line breaks dropped.
    static func cleaned(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why `name` cannot replace the name of `folder`, or nil when it can.
    ///
    /// The clash test ignores case because the usual Mac volume does: a sibling named
    /// "Roll One" blocks "roll one". The folder's own entry is skipped, so changing only the
    /// case of its name is allowed.
    static func refusal(renaming folder: URL, to name: String) -> Refusal? {
        if name.isEmpty { return .empty }
        if name.contains("/") || name.contains(":") { return .badCharacter }
        let parent = folder.deletingLastPathComponent()
        let own = folder.lastPathComponent
        let fm = FileManager.default
        if let siblings = try? fm.contentsOfDirectory(atPath: parent.path) {
            if let clash = siblings.first(where: { $0 != own && $0.caseInsensitiveCompare(name) == .orderedSame }) {
                return .taken(clash)
            }
        } else if name.caseInsensitiveCompare(own) != .orderedSame,
                  fm.fileExists(atPath: parent.appendingPathComponent(name).path) {
            return .taken(name)
        }
        return nil
    }

    /// Renames the folder in place. A change of case alone goes through a hidden temporary
    /// name, because a case-insensitive volume sees the new name as the folder itself.
    static func move(_ old: URL, to new: URL) throws {
        let fm = FileManager.default
        guard old.lastPathComponent.caseInsensitiveCompare(new.lastPathComponent) == .orderedSame else {
            try fm.moveItem(at: old, to: new)
            return
        }
        let step = old.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)", isDirectory: true)
        try fm.moveItem(at: old, to: step)
        do { try fm.moveItem(at: step, to: new) } catch {
            try? fm.moveItem(at: step, to: old)
            throw error
        }
    }
}

/// What a rename did.
enum FolderRenameOutcome: Equatable {
    /// Renamed on disk and in the list; the folder's id is now this.
    case renamed(FolderSession.ID)
    /// The name was the same, so nothing moved and no undo step was added.
    case unchanged
    case refused(FolderRename.Refusal)
}

/// Rename from the sidebar: the context menu's Rename... and Return on the selected row,
/// both of which open a name field in the row.
extension AppModel {

    /// Why a folder cannot be renamed right now, for the menu item's help text, or nil.
    ///
    /// Write permission on the parent is what a rename needs, and `isWritableFile` asks the
    /// system the same question the move will. A run in progress holds its frames by id, and
    /// a rename changes every id in the folder, so the item waits for the run to end.
    func renameBlocker(_ id: FolderSession.ID) -> String? {
        guard let session = folders.first(where: { $0.id == id }) else { return "This folder is no longer in the list." }
        if enhanceRunning || autoCropProgress != nil { return "Wait for the current run to finish." }
        let parent = session.url.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: parent.path) {
            return "The folder that holds \(session.name) cannot be written to, so it cannot be renamed here."
        }
        return nil
    }

    /// Opens the name field on a folder's row.
    func beginRename(_ id: FolderSession.ID) {
        guard renameBlocker(id) == nil else { return }
        renamingFolderID = id
    }

    /// Closes the name field with no change.
    func cancelRename() { renamingFolderID = nil }

    /// The name field's commit. Returns whether the field closes. A refusal leaves it open
    /// with the typed text, shakes it, and says why in the banner line.
    @discardableResult
    func commitRename(_ typed: String) -> Bool {
        guard let id = renamingFolderID else { return true }
        switch renameFolder(id, to: typed) {
        case .renamed, .unchanged:
            renamingFolderID = nil
            return true
        case .refused(let refusal):
            notice = refusal.sentence
            renameRefusals += 1
            return false
        }
    }

    /// Renames a listed folder on disk and follows it in the model, as one undo step.
    ///
    /// The session keeps its place in the list and the selection stays on it. Its frames,
    /// and the frame selection, cursor and closeup, move to the new paths. A fresh bookmark
    /// is made from the new URL, so the sweep that runs when the app comes forward finds the
    /// folder where it now is and does not report the old path as gone.
    @discardableResult
    func renameFolder(_ id: FolderSession.ID, to typed: String) -> FolderRenameOutcome {
        guard let session = folders.first(where: { $0.id == id }) else {
            return .refused(.failed("the folder is no longer in the list."))
        }
        let name = FolderRename.cleaned(typed)
        guard name != session.name else { return .unchanged }
        if let refusal = FolderRename.refusal(renaming: session.url, to: name) { return .refused(refusal) }

        let old = session.url
        let new = old.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        // The sidecars travel with the folder, so each has to be the current one: an edit
        // made in the last 400 ms exists only in memory, and its queued write names the old
        // path. A listed folder inside this one moves too.
        let affected = folders.filter { Self.rebased($0.url, from: old, to: new) != nil }
        for f in affected.flatMap(\.frames) { flushPendingSave(f.id) }
        do { try FolderRename.move(old, to: new) } catch {
            return .refused(.failed(error.localizedDescription))
        }
        followRename(from: old, to: new)

        let oldName = session.name
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            if case .refused(let refusal) = model.renameFolder(new, to: oldName) { model.notice = refusal.sentence }
        }
        undoManager.setActionName("Rename Folder")
        undoManager.endUndoGrouping()
        return .renamed(new)
    }

    /// Where `url` is after `old` became `new`, or nil when it is not `old` or inside it.
    nonisolated static func rebased(_ url: URL, from old: URL, to new: URL) -> URL? {
        let base = old.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let path = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard path.count >= base.count, Array(path.prefix(base.count)) == base else { return nil }
        return path.dropFirst(base.count).reduce(new) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// Moves every session at or under `old` to its new path, in place in the list, and
    /// carries the selection, navigation and folder-keyed caches with it.
    private func followRename(from old: URL, to new: URL) {
        var frameMap: [Frame.ID: Frame.ID] = [:]
        var folderMap: [FolderSession.ID: FolderSession.ID] = [:]
        for i in folders.indices {
            let s = folders[i]
            guard let moved = Self.rebased(s.url, from: old, to: new) else { continue }
            s.url.stopAccessingSecurityScopedResource()
            _ = moved.startAccessingSecurityScopedResource()
            let frames = s.frames.map { f -> Frame in
                let to = moved.appendingPathComponent(f.name)
                frameMap[f.id] = to
                return Frame(url: to, sidecar: f.sidecar, status: f.status)
            }
            let bookmark = (try? Self.folderBookmark(for: moved)) ?? s.bookmark
            replaceFolder(at: i, with: FolderSession(url: moved, bookmark: bookmark, frames: frames))
            folderMap[s.id] = moved
        }
        for id in frameMap.keys { renders.invalidate(id) }
        for (from, to) in folderMap {
            folderColours[from] = nil
            // Read back off the disk rather than carried over: the tag lives on the folder.
            folderColours[to] = FolderColour.read(to)
            if let scale = frameScales.removeValue(forKey: from) { frameScales[to] = scale }
        }

        if let selected = selectedFolderID, let to = folderMap[selected] {
            followingRename = true
            selectedFolderID = to
            followingRename = false
        }
        func follow(_ id: Frame.ID?) -> Frame.ID? { id.map { frameMap[$0] ?? $0 } }
        selection = Set(selection.map { frameMap[$0] ?? $0 })
        cursor = follow(cursor)
        anchor = follow(anchor)
        viewerFrameID = follow(viewerFrameID)
        galleryTopFrameID = follow(galleryTopFrameID)
        persistFolders()
    }
}
