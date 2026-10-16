import Foundation

/// Whether a folder the app remembers is still on disk, and when it is not, whether that is
/// because it was deleted or because the volume holding it is not mounted right now.
///
/// This distinction is the entire reason the type exists. Both cases are the SAME answer
/// from the filesystem (`fileExists` returns false and nothing else is offered), and
/// treating them alike silently empties the user's folder list every time an external drive
/// sleeps. That failure is worse than the one this file was written for: a folder wrongly
/// shown can be refreshed away in a second, a folder wrongly forgotten has to be found and
/// added again, and nothing on screen ever explains why it went.
///
/// The asymmetry is the design rule, and it is stated here because it is easy to write code
/// that contradicts it a few lines later: **a stale row costs one refresh, a forgotten
/// folder costs the folder.** Every branch below resolves ties toward keeping.
public enum FolderPresence: Equatable, Sendable {
    /// The path is there. Nothing to decide.
    case present
    /// The volume is mounted and the path is genuinely absent: deleted, renamed or moved.
    /// The only state that may lead to a removal, and even then only once confirmed.
    case missing
    /// The volume that would hold this path is not mounted. Say nothing, change nothing,
    /// keep the folder for when the drive comes back.
    case volumeOffline
}

/// Answers `FolderPresence` for a path.
///
/// The pure entry points take their facts as closures so every branch is testable without a
/// drive to eject, a Trash to fill or a symlink to dangle.
public enum FolderOnDisk {

    // MARK: the volume rule

    /// The mount point a path would live under.
    ///
    /// It is a claim about the STRING, never about the filesystem, and that is forced rather
    /// than lazy: the question only gets asked when the path is not there, which is exactly
    /// the moment the path cannot be interrogated for its volume. `URLResourceKey.volumeURLKey`
    /// on a missing path answers for the nearest EXISTING ancestor, which for an ejected
    /// drive is the root volume, the one answer that would prune the folder.
    ///
    /// Network automounts get the same treatment as `/Volumes` because they fail the same
    /// way: a NAS under `/net` or `/private/var/automount` that reads as the root volume
    /// would be pruned the moment it went away.
    public static func expectedVolumeRoot(forPath path: String) -> String {
        guard path.hasPrefix("/") else { return "/" }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 2, parts[0] == "Volumes" { return "/Volumes/\(parts[1])" }
        if parts.count >= 2, parts[0] == "net" { return "/net/\(parts[1])" }
        if parts.count >= 4, parts[0] == "private", parts[1] == "var", parts[2] == "automount" {
            return "/private/var/automount/\(parts[3])"
        }
        return "/"
    }

    /// The pure rule.
    ///
    /// `symlinkTarget` is not an embellishment. A home-directory symlink pointing at an
    /// external drive is an ordinary way to keep rolls handy, and when that drive is
    /// ejected `fileExists` FOLLOWS the link and reports the target's absence under the
    /// link's own path. The volume rule then reads the link's path, sees the root volume,
    /// and prunes a folder whose only problem is an unplugged drive. So a path that is not
    /// there is asked whether it is a link before the volume rule runs at all.
    public static func presence(ofPath path: String,
                                exists: (String) -> Bool,
                                symlinkTarget: (String) -> String? = { _ in nil },
                                mountedVolumePaths: () -> [String]) -> FolderPresence {
        presence(ofPath: path, hops: 0, exists: exists,
                 symlinkTarget: symlinkTarget, mountedVolumePaths: mountedVolumePaths)
    }

    private static func presence(ofPath path: String,
                                 hops: Int,
                                 exists: (String) -> Bool,
                                 symlinkTarget: (String) -> String?,
                                 mountedVolumePaths: () -> [String]) -> FolderPresence {
        if exists(path) { return .present }
        // `readlink`, which answers whatever the target's state, where `realpath` fails on a
        // dangling link and tells you nothing. The hop limit is for a symlink cycle.
        if hops < 8, let target = symlinkTarget(path) {
            let absolute = target.hasPrefix("/")
                ? target
                : (path as NSString).deletingLastPathComponent + "/" + target
            return presence(ofPath: absolute, hops: hops + 1, exists: exists,
                            symlinkTarget: symlinkTarget, mountedVolumePaths: mountedVolumePaths)
        }
        let root = expectedVolumeRoot(forPath: path)
        // The root volume is mounted by definition: if it were not, this process would not
        // be running to ask. Short-circuited so a truncated volume list can never make an
        // ordinary deleted folder look offline, which would stop the home volume pruning.
        guard root != "/" else { return .missing }
        // Either test alone is wrong. The list misses the boot volume when a path was stored
        // as `/Volumes/Macintosh HD/...`, which `mountedVolumeURLs` reports as `/`, and that
        // folder would then be permanently offline and never fixable. The directory test
        // alone would trust a mount point left behind after an eject. Case-insensitively,
        // because the filesystem is.
        let listed = mountedVolumePaths().contains {
            normalized($0).compare(root, options: .caseInsensitive) == .orderedSame
        }
        return (listed || exists(root)) ? .missing : .volumeOffline
    }

    /// The live rule, over the real filesystem.
    public static func presence(of url: URL) -> FolderPresence {
        presence(ofPath: url.standardizedFileURL.path,
                 exists: { FileManager.default.fileExists(atPath: $0) },
                 symlinkTarget: { try? FileManager.default.destinationOfSymbolicLink(atPath: $0) },
                 mountedVolumePaths: {
                     // No `skipHiddenVolumes`: a complete list is what makes the mounted test
                     // accurate in both directions.
                     (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                           options: []) ?? [])
                         .map(\.standardizedFileURL.path)
                 })
    }

    private static func normalized(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    // MARK: confirming a removal

    /// The second, independent opinion required before anything is removed.
    ///
    /// A volume coming back from sleep is the case this exists for: it appears in
    /// `mountedVolumeURLs` while I/O against it is still failing, so `fileExists` says false
    /// for every path on it at once and the volume rule happily calls them all deleted. If
    /// the containing directory can be LISTED, the absence is a fact about one folder. If it
    /// cannot, the absence is a fact about the storage, and nothing may be removed.
    ///
    /// Cheap by construction: it runs only for a folder already believed gone, never on the
    /// ordinary path.
    public static func parentIsListable(_ url: URL) -> Bool {
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        return (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) != nil
    }

    // MARK: the Trash

    /// Whether a resolved URL has landed in a Trash.
    ///
    /// A macOS bookmark tracks a file by IDENTITY, not by path, so dragging a folder to the
    /// Trash MOVES it and the bookmark follows. Measured: a folder trashed after bookmarking
    /// resolves to `~/.Trash/<name>`, the resolve reports stale, and `fileExists` on that
    /// path returns TRUE. Without this test the app would hold a live handle on the Trash
    /// copy, and a sidecar written there dies when the Trash is emptied.
    ///
    /// Asked by name rather than by convention: `appropriateFor:` returns the trash of the
    /// volume that URL lives on, which covers external media without hardcoding
    /// `/Volumes/<name>/.Trashes/<uid>`, and covers a relocated home directory. The
    /// component checks remain as a fallback for a volume whose trash cannot be named, and
    /// they are case-insensitive because the filesystem is: an exact `.Trash` match would
    /// let `.trash` through as live, which is the failure being closed.
    public static func isInTrash(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                    appropriateFor: url, create: false) {
            let root = trash.standardizedFileURL.path
            if path.compare(root, options: .caseInsensitive) == .orderedSame { return true }
            if path.lowercased().hasPrefix(root.lowercased() + "/") { return true }
        }
        let components = path.split(separator: "/").map(String.init)
        return components.contains {
            $0.compare(".Trashes", options: .caseInsensitive) == .orderedSame
                || $0.compare(".Trash", options: .caseInsensitive) == .orderedSame
        }
    }
}

// MARK: resolving a remembered folder

/// What a resolved bookmark says about a folder the app remembers.
public enum FolderVerdict: Equatable, Sendable {
    /// Why a folder is gone. Both remove it; they differ only in what the user is told.
    public enum Gone: Equatable, Sendable {
        /// The volume is mounted, the containing directory reads, and nothing is at the path.
        case deleted
        /// It resolved into a Trash.
        case trashed
    }

    /// Still there, at this URL. `refreshedBookmark` is non-nil when the stored bookmark was
    /// stale and has been re-created, in which case the caller persists it.
    case live(URL, refreshedBookmark: Data?)
    /// Remove it and persist the shorter list.
    case gone(Gone)
    /// Unreachable right now, which is not the same as gone. Keep the bookmark, create no
    /// session, say nothing, change nothing.
    case offline
}

public extension FolderOnDisk {

    /// The outcome of resolving a bookmark, with its staleness flag.
    struct BookmarkResolution: Equatable {
        public let url: URL?
        public let isStale: Bool
        public init(url: URL?, isStale: Bool) { self.url = url; self.isStale = isStale }
    }

    /// The pure rule, with every fact injected.
    ///
    /// Two things the measurement settled, both of which the code has to respect.
    ///
    /// **Staleness does not mean gone.** A folder trashed and a folder legitimately moved
    /// BOTH come back stale with `fileExists` true. The only thing separating them is where
    /// they landed, so `isInTrash` is the discriminator and `isStale` is used for nothing
    /// except deciding to re-create the bookmark.
    ///
    /// **A bookmark that will not resolve is never evidence of anything.** Resolution also
    /// fails for a network volume whose credentials lapsed, a mount that is hung, a blob
    /// written under a different code signature, and a drive that is simply away. With no
    /// path this session has verified for itself, there is nothing to judge, so that branch
    /// cannot reach `.gone` at all. The path recorded inside the blob is the path as of
    /// bookmark CREATION: for a folder the user had since moved, that path is empty, so
    /// judging against it would prune the folder while alive. It also mistakes a second
    /// drive carrying the same volume name for the first one, and SD cards are all called
    /// `NO NAME`.
    static func verdict(resolution: BookmarkResolution,
                        knownURL: URL?,
                        presence: (URL) -> FolderPresence,
                        isInTrash: (URL) -> Bool,
                        confirmGone: (URL) -> Bool,
                        refreshBookmark: (URL) -> Data?) -> FolderVerdict {
        if let url = resolution.url {
            if isInTrash(url) { return .gone(.trashed) }
            switch presence(url) {
            case .volumeOffline: return .offline
            case .missing: return confirmGone(url) ? .gone(.deleted) : .offline
            case .present:
                let moved = knownURL.map { $0.standardizedFileURL.path != url.standardizedFileURL.path } ?? false
                return .live(url, refreshedBookmark: (resolution.isStale || moved) ? refreshBookmark(url) : nil)
            }
        }
        // Unresolvable. `knownURL` is the session's own, resolved successfully during THIS
        // run, so it is a current identity-to-path mapping rather than a historical one, and
        // it may be judged. At launch there is no such path and the bookmark is simply kept.
        guard let known = knownURL else { return .offline }
        switch presence(known) {
        case .present: return .live(known, refreshedBookmark: refreshBookmark(known))
        case .volumeOffline: return .offline
        case .missing: return confirmGone(known) ? .gone(.deleted) : .offline
        }
    }

    /// Resolve a stored bookmark without side effects.
    ///
    /// `withoutMounting` and `withoutUI` matter: this runs at launch and again every time the
    /// app comes forward, and neither moment may mount a sleeping drive or raise a network
    /// authentication panel behind the user.
    static func resolve(_ data: Data) -> BookmarkResolution {
        var stale = false
        let options: URL.BookmarkResolutionOptions = [.withoutMounting, .withoutUI]
        let url = (try? URL(resolvingBookmarkData: data, options: options.union(.withSecurityScope),
                            relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: options,
                         relativeTo: nil, bookmarkDataIsStale: &stale))
        // `stale` is only meaningful alongside a resolved URL: with none, both attempts threw
        // and whatever either wrote into it says nothing.
        return BookmarkResolution(url: url, isStale: url == nil ? false : stale)
    }

    /// The live rule.
    static func verdict(bookmark: Data, knownURL: URL?) -> FolderVerdict {
        verdict(resolution: resolve(bookmark),
                knownURL: knownURL,
                presence: presence(of:),
                isInTrash: isInTrash(_:),
                confirmGone: parentIsListable(_:),
                refreshBookmark: { url in
                    // Balanced, and that is not housekeeping. The scope is a COUNTED kernel
                    // sandbox extension; this helper runs over every stale folder on every
                    // activation, and once the extension table fills, every later
                    // `startAccessingSecurityScopedResource` in the process returns false
                    // and the app loses access to all folders until relaunch, with no error
                    // anywhere. Stopping only what this call started leaves a live session's
                    // own access untouched.
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    // The same fallback `addFolder` uses: the unbundled dev build has no
                    // sandbox entitlement and refuses a scoped bookmark.
                    return (try? url.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil, relativeTo: nil))
                        ?? (try? url.bookmarkData(includingResourceValuesForKeys: nil, relativeTo: nil))
                })
    }
}
