import Foundation
import AppKit
import UniformTypeIdentifiers

/// Dragging folders and files from Finder onto the window. A dropped folder is added to
/// the folders panel, and a dropped file adds the folder it is in. Finder file URLs only.
/// A photo library hands over file promises, which name no folder on disk, so they are not
/// accepted.
enum DroppedFolders {
    /// The folders a drop adds, in the order they were dropped, each once. A folder is
    /// itself, a file is the folder it sits in, so forty frames dragged out of one roll
    /// add that roll once. A dropped folder is added whether or not it holds raw files,
    /// exactly as Add Folder does, so the two ways in never disagree: an empty one shows
    /// No Raw Files and can be removed like any other.
    static func folders(from urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls where url.isFileURL {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let folder = isDirectory ? url : url.deletingLastPathComponent()
            let path = folder.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            result.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        return result
    }
}

extension AppModel {
    /// Reads every file URL out of a drop and adds the folders it names. Each one goes
    /// through `addFolder`, which already refuses a duplicate and selects what it adds, so
    /// a drop of several folders ends with the last of them selected.
    func addDropped(_ providers: [NSItemProvider]) {
        let wanted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        // A refused drop says why, once, in the banner, so it does not read as a drop that
        // broke while the window reports it as taken.
        guard !wanted.isEmpty else { notice = Self.refusedDropNotice; return }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in wanted {
                if let url = await Self.fileURL(from: provider) { urls.append(url) }
            }
            let folders = DroppedFolders.folders(from: urls)
            guard !folders.isEmpty else { notice = Self.refusedDropNotice; return }
            for folder in folders { addFolder(folder) }
        }
    }

    /// A photo library hands over file promises that name no folder on disk, which is the
    /// drop that lands here in practice.
    static let refusedDropNotice = "Drag folders or files from Finder. Only items on disk can be added."

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}
