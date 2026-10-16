import Foundation

/// Reopen the last selected folder on relaunch, so anyone working down the list starts each
/// session in the roll they left rather than the first one.
extension AppModel {
    /// The folder to select at launch: the remembered one when it came back, else the first.
    /// Pure so the choice is testable without a relaunch.
    nonisolated static func folderToReopen(_ urls: [URL], remembered: String?) -> URL? {
        if let remembered,
           let hit = urls.first(where: { $0.standardizedFileURL.path == remembered }) { return hit }
        return urls.first
    }

    /// Called from `selectedFolderID`'s didSet. Not during the launch restore, because a
    /// remembered folder on an unmounted volume falls back to the first one there, and
    /// writing that fallback down would forget the real choice before the volume returns.
    func rememberSelectedFolder(_ old: FolderSession.ID?) {
        guard !restoringFolders, selectedFolderID != old else { return }
        let path = selectedFolderID?.standardizedFileURL.path
        guard prefs.lastFolderPath != path else { return }
        prefs.lastFolderPath = path
        prefs.save()
    }
}
