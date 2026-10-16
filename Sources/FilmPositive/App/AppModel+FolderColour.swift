import Foundation

/// The sidebar's color labels, which are the folders' own Finder color tags.
extension AppModel {
    /// Reads every folder's color tag off the disk. Cheap: one resource value per folder.
    func refreshFolderColours() {
        var read: [FolderSession.ID: FolderColour] = [:]
        for f in folders { if let c = FolderColour.read(f.url) { read[f.id] = c } }
        if read != folderColours { folderColours = read }
    }

    /// Sets one folder's color tag, keeping every other tag it has. Nil clears the color.
    /// A failure says so in the banner line rather than an alert, the same as a folder that
    /// vanished: there is nothing to decide, only something to know.
    func setFolderColour(_ colour: FolderColour?, for id: FolderSession.ID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        do {
            folderColours[id] = try FolderColour.write(colour, to: folder.url)
        } catch {
            folderColours[id] = FolderColour.read(folder.url)
            notice = "Could not set the color of \(folder.name): \(error.localizedDescription)"
        }
    }
}
