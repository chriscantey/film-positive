import Foundation
import FilmSidecar
import FilmPositiveCore

/// One raw file in a folder. The sidecar struct is the single source of truth for its
/// state, and `nil` develop means undeveloped. Identity is the file URL.
struct Frame: Identifiable, Equatable, Hashable, Sendable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var stem: String { url.deletingPathExtension().lastPathComponent }

    /// The in-memory state, loaded from `<base>.xmp` when present.
    var sidecar: Sidecar
    /// What the store said about the sidecar on load.
    var status: SidecarStore.LoadStatus?

    var isDeveloped: Bool { sidecar.develop != nil }

    func hash(into h: inout Hasher) { h.combine(url) }
}

/// A folder added as an independent session: top level only, no subfolder scanning,
/// removable without touching disk, re-opened at launch through its security-scoped
/// bookmark when it still exists.
struct FolderSession: Identifiable, Equatable, Hashable, Sendable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var bookmark: Data
    var frames: [Frame]

    func hash(into h: inout Hasher) { h.combine(url) }

    static let rawExtensions: Set<String> = ["cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2", "pef", "srw"]

    /// The raw files directly inside `url`, sorted by name, each with its sidecar loaded.
    static func scan(_ url: URL) throws -> [Frame] {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        let store = SidecarStore()
        return names
            .filter { rawExtensions.contains($0.pathExtension.lowercased()) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { file in
                if let loaded = try? store.load(for: file) {
                    return Frame(url: file, sidecar: loaded.sidecar.withLiveFields, status: loaded.status)
                }
                let source = (try? SidecarStore.source(for: file)) ?? SidecarSource(name: file.lastPathComponent, size: 0, mtime: Date(), fingerprint: "")
                return Frame(url: file, sidecar: Sidecar(source: source), status: nil)
            }
    }
}
