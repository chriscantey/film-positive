import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// A folder that is gone versus a folder that is merely unreachable.
///
/// Two separate faults are pinned here and it is worth keeping them apart.
///
/// The visible one: `"\(error)"` in `lastError` is drawn by the window as a modal, so a
/// raw error from Refresh on a folder deleted in Finder would put
/// `Error Domain=NSCocoaErrorDomain Code=260 ... NSFilePath=` on screen.
///
/// The dangerous one: a macOS bookmark tracks a file by identity, so trashing a folder
/// MOVES it and the bookmark follows it into `~/.Trash`, where `fileExists` returns true.
/// A launch prune guarded by `fileExists` alone keeps a live handle on the Trash copy, and
/// developing frames there writes sidecars into the Trash for emptying it to destroy.
///
/// Every removal branch is matched by a KEEP branch, because the failure that costs the user
/// most is not a stale row: it is a folder list quietly emptied because a drive was asleep.
final class MissingFolderTests: XCTestCase {

    private var scratch: URL!
    /// Anything this suite puts in the Trash, so tearDown can take it back out.
    private var trashed: [URL] = []

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-missing-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // A store of this test's own. Clearing the key in the standard defaults is not
        // enough: every `swift test` process on the Mac shares that domain, and a second test
        // run adding folders at the same moment can write its bookmark into it between this
        // suite's sweep and its count.
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
        for url in trashed { try? FileManager.default.removeItem(at: url) }
        trashed = []
    }

    @discardableResult
    private func makeFolder(_ name: String, files: [String] = ["1.CR2", "2.CR2"]) throws -> URL {
        let dir = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files { try Data(repeating: 0x42, count: 64).write(to: dir.appendingPathComponent(f)) }
        return dir
    }

    @MainActor
    private func makeModel(verdict: ((Data, URL?) -> FolderVerdict)? = nil) -> AppModel {
        AppModel(service: FailingRenderService(message: "no engine in tests"), folderVerdict: verdict)
    }

    /// Moves a folder to the Trash the way Finder does, and remembers where it landed.
    private func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        let landed = try XCTUnwrap(result as URL?)
        trashed.append(landed)
        return landed
    }

    private var storedBookmarkCount: Int { Preferences.load().folderBookmarks.count }

    // MARK: the path rule

    func testTheVolumeRootIsReadFromThePathBecauseTheVolumeMayBeGone() {
        XCTAssertEqual(FolderOnDisk.expectedVolumeRoot(forPath: "/Users/Shared/Desktop/Roll"), "/")
        XCTAssertEqual(FolderOnDisk.expectedVolumeRoot(forPath: "/Volumes/Scans/Rolls/800T"), "/Volumes/Scans")
        XCTAssertEqual(FolderOnDisk.expectedVolumeRoot(forPath: "/Volumes/Scans"), "/Volumes/Scans")
        // Not enough of a path to name a volume: the root volume, which is always mounted.
        XCTAssertEqual(FolderOnDisk.expectedVolumeRoot(forPath: "/Volumes"), "/")
        XCTAssertEqual(FolderOnDisk.expectedVolumeRoot(forPath: "/"), "/")
    }

    func testAPathThatIsThereIsPresentWhateverTheVolumeList() {
        let p = FolderOnDisk.presence(ofPath: "/Volumes/Scans/Rolls",
                                      exists: { _ in true },
                                      mountedVolumePaths: { [] })
        XCTAssertEqual(p, .present)
    }

    func testAnAbsentPathOnAMountedVolumeIsMissing() {
        XCTAssertEqual(FolderOnDisk.presence(ofPath: "/Users/Shared/Desktop/Roll",
                                             exists: { _ in false },
                                             mountedVolumePaths: { ["/"] }),
                       .missing)
        XCTAssertEqual(FolderOnDisk.presence(ofPath: "/Volumes/Scans/Rolls",
                                             exists: { _ in false },
                                             mountedVolumePaths: { ["/", "/Volumes/Scans"] }),
                       .missing)
    }

    /// THE criterion this whole file exists to protect. An ejected drive must never read as
    /// a deleted folder.
    func testAnAbsentPathOnAnUnmountedVolumeIsOfflineAndNeverMissing() {
        XCTAssertEqual(FolderOnDisk.presence(ofPath: "/Volumes/Scans/Rolls/800T",
                                             exists: { _ in false },
                                             mountedVolumePaths: { ["/"] }),
                       .volumeOffline)
        // The volume's own root, unplugged.
        XCTAssertEqual(FolderOnDisk.presence(ofPath: "/Volumes/Scans",
                                             exists: { _ in false },
                                             mountedVolumePaths: { ["/"] }),
                       .volumeOffline)
        // A trailing slash from `mountedVolumeURLs` must not defeat the membership test.
        XCTAssertEqual(FolderOnDisk.presence(ofPath: "/Volumes/Scans/Rolls",
                                             exists: { _ in false },
                                             mountedVolumePaths: { ["/", "/Volumes/Scans/"] }),
                       .missing)
    }

    /// A truncated volume list must not turn an ordinary deleted folder into "offline", or
    /// the home-volume case could never prune at all.
    func testTheRootVolumeIsNeverLookedUp() {
        XCTAssertEqual(FolderOnDisk.presence(ofPath: "/Users/Shared/Desktop/Roll",
                                             exists: { _ in false },
                                             mountedVolumePaths: { [] }),
                       .missing)
    }

    /// A home-directory symlink pointing at an external drive is an ordinary way to keep
    /// rolls handy. Eject the drive and `fileExists` FOLLOWS the link, reporting the
    /// target's absence under the LINK's path, whose volume root is `/`. Without the hop
    /// this is a straight prune of a live folder: the exact case the type exists to stop.
    func testADanglingSymlinkIsJudgedByItsTargetsVolume() {
        let link = "/Users/Shared/Rolls"
        let p = FolderOnDisk.presence(ofPath: link,
                                      exists: { _ in false },
                                      symlinkTarget: { $0 == link ? "/Volumes/Big/Rolls" : nil },
                                      mountedVolumePaths: { ["/"] })
        XCTAssertEqual(p, .volumeOffline, "the link's own path says root volume, the target says ejected drive")
    }

    func testASymlinkToAPathOnAMountedVolumeStillPrunes() {
        let link = "/Users/Shared/Rolls"
        let p = FolderOnDisk.presence(ofPath: link,
                                      exists: { _ in false },
                                      symlinkTarget: { $0 == link ? "/Volumes/Big/Rolls" : nil },
                                      mountedVolumePaths: { ["/", "/Volumes/Big"] })
        XCTAssertEqual(p, .missing)
    }

    func testASymlinkCycleTerminates() {
        let p = FolderOnDisk.presence(ofPath: "/a",
                                      exists: { _ in false },
                                      symlinkTarget: { $0 == "/a" ? "/b" : "/a" },
                                      mountedVolumePaths: { ["/"] })
        XCTAssertEqual(p, .missing, "a cycle ends at the hop limit rather than recursing forever")
    }

    /// The boot volume is reachable as `/Volumes/Macintosh HD` while `mountedVolumeURLs`
    /// reports it as `/`. Membership alone would call every folder stored that way
    /// permanently offline, so none of them could ever be pruned. An existing mount point
    /// settles it.
    func testAVolumeMissingFromTheListButPresentOnDiskCountsAsMounted() {
        let p = FolderOnDisk.presence(ofPath: "/Volumes/Macintosh HD/Users/Shared/Roll",
                                      exists: { $0 == "/Volumes/Macintosh HD" },
                                      mountedVolumePaths: { ["/"] })
        XCTAssertEqual(p, .missing)
    }

    func testTheVolumeNameTestIsCaseInsensitiveLikeTheFilesystem() {
        let p = FolderOnDisk.presence(ofPath: "/Volumes/Scans/Roll",
                                      exists: { _ in false },
                                      mountedVolumePaths: { ["/", "/Volumes/SCANS"] })
        XCTAssertEqual(p, .missing)
    }

    /// A NAS under an automount path reads as the root volume unless it is named, and would
    /// be pruned the moment it went away.
    func testAnAutomountedShareIsTreatedAsItsOwnVolume() {
        XCTAssertEqual(FolderOnDisk.expectedVolumeRoot(forPath: "/net/nas/photos/roll"), "/net/nas")
        XCTAssertEqual(FolderOnDisk.expectedVolumeRoot(forPath: "/private/var/automount/nas/photos"),
                       "/private/var/automount/nas")
        XCTAssertEqual(FolderOnDisk.presence(ofPath: "/net/nas/photos/roll",
                                             exists: { _ in false },
                                             mountedVolumePaths: { ["/"] }),
                       .volumeOffline)
    }

    // MARK: the Trash

    func testTrashIsRecognisedInBothItsForms() throws {
        let home = try XCTUnwrap(try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                             appropriateFor: nil, create: false))
        XCTAssertTrue(FolderOnDisk.isInTrash(home.appendingPathComponent("Cinestill 800T")))
        // An external drive's per-user trash, which is where a roll on external media lands.
        XCTAssertTrue(FolderOnDisk.isInTrash(URL(fileURLWithPath: "/Volumes/Scans/.Trashes/501/Roll")))
        XCTAssertFalse(FolderOnDisk.isInTrash(URL(fileURLWithPath: "/Users/Shared/Desktop/Cinestill 800T")))
        // A folder whose NAME merely mentions the trash is not in it.
        XCTAssertFalse(FolderOnDisk.isInTrash(URL(fileURLWithPath: "/Users/Shared/Trash Rolls/800T")))
    }

    /// The measurement this design rests on, re-run as a test rather than trusted: a bookmark
    /// follows its folder into the Trash, so a `fileExists` guard passes.
    func testABookmarkFollowsItsFolderIntoTheTrashWhichIsWhyFileExistsWasNotEnough() throws {
        let dir = try makeFolder("roll-bookmark-follows")
        let data = try dir.bookmarkData(includingResourceValuesForKeys: nil, relativeTo: nil)
        _ = try trash(dir)

        let resolution = FolderOnDisk.resolve(data)
        let landed = try XCTUnwrap(resolution.url, "the bookmark still resolves after trashing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path),
                      "fileExists is TRUE on the trashed copy: this is the guard that failed")
        XCTAssertTrue(FolderOnDisk.isInTrash(landed), "and this is the test that catches it")
    }

    // MARK: the verdict

    private func verdict(url: URL?, stale: Bool = false, knownURL: URL? = nil,
                         presence: FolderPresence = .present, inTrash: Bool = false,
                         confirmGone: Bool = true,
                         refreshed: Data? = Data([0xFE])) -> FolderVerdict {
        FolderOnDisk.verdict(resolution: .init(url: url, isStale: stale),
                             knownURL: knownURL,
                             presence: { _ in presence },
                             isInTrash: { _ in inTrash },
                             confirmGone: { _ in confirmGone },
                             refreshBookmark: { _ in refreshed })
    }

    func testAResolvedTrashPathIsGoneHoweverHealthyItLooks() {
        let v = verdict(url: URL(fileURLWithPath: "/Users/Shared/.Trash/Roll"), stale: true,
                        presence: .present, inTrash: true)
        XCTAssertEqual(v, .gone(.trashed))
    }

    func testAnUnmountedVolumeIsOfflineAndNotGone() {
        XCTAssertEqual(verdict(url: URL(fileURLWithPath: "/Volumes/Scans/Roll"), presence: .volumeOffline),
                       .offline)
    }

    func testAResolvedButAbsentPathOnAMountedVolumeIsGone() {
        XCTAssertEqual(verdict(url: URL(fileURLWithPath: "/Users/Shared/Roll"), presence: .missing),
                       .gone(.deleted))
    }

    /// Staleness is not a gone signal. Measured: a trashed folder AND a legitimately
    /// moved folder both come back stale with `fileExists` true, so the only thing that can
    /// separate them is where they landed.
    func testAStaleBookmarkOnALivePathIsRefreshedAndKept() {
        let url = URL(fileURLWithPath: "/Users/Shared/Roll")
        XCTAssertEqual(verdict(url: url, stale: true, knownURL: url, presence: .present),
                       .live(url, refreshedBookmark: Data([0xFE])))
    }

    func testAMovedFolderIsFollowedAndRebookmarkedNeverPruned() {
        let moved = URL(fileURLWithPath: "/Users/Shared/Rolls/800T")
        let v = verdict(url: moved, stale: true, knownURL: URL(fileURLWithPath: "/Users/Shared/800T"),
                        presence: .present)
        XCTAssertEqual(v, .live(moved, refreshedBookmark: Data([0xFE])))
    }

    func testAnUnchangedFolderIsNotRebookmarked() {
        let url = URL(fileURLWithPath: "/Users/Shared/Roll")
        XCTAssertEqual(verdict(url: url, stale: false, knownURL: url, presence: .present),
                       .live(url, refreshedBookmark: nil))
    }

    /// An unresolvable bookmark at LAUNCH carries no path, so it cannot be judged. Keeping it
    /// is the only safe answer: a destroyed item and an unplugged drive look identical here.
    func testAnUnresolvableBookmarkWithNoKnownPathIsKept() {
        XCTAssertEqual(verdict(url: nil, knownURL: nil), .offline)
    }

    /// A bookmark that will not resolve is never evidence of anything, so with no path this
    /// session verified for itself the branch cannot reach `.gone` at all. Resolution also
    /// fails for a lapsed network credential, a hung mount and a blob written under another
    /// code signature, and in every one of those the folder is alive.
    func testAnUnresolvableBookmarkAtLaunchIsNeverGoneWhateverThePresenceSays() {
        for p: FolderPresence in [.present, .missing, .volumeOffline] {
            XCTAssertNotEqual(verdict(url: nil, knownURL: nil, presence: p), .gone(.deleted))
            XCTAssertNotEqual(verdict(url: nil, knownURL: nil, presence: p), .gone(.trashed))
        }
        XCTAssertEqual(verdict(url: nil, knownURL: nil, presence: .missing), .offline)
    }

    func testAnUnresolvableBookmarkFallsBackToTheKnownPath() {
        let known = URL(fileURLWithPath: "/Users/Shared/Roll")
        XCTAssertEqual(verdict(url: nil, knownURL: known, presence: .missing), .gone(.deleted))
        XCTAssertEqual(verdict(url: nil, knownURL: known, presence: .volumeOffline), .offline)
        XCTAssertEqual(verdict(url: nil, knownURL: known, presence: .present),
                       .live(known, refreshedBookmark: Data([0xFE])))
    }

    // MARK: refresh

    /// End to end. A failure here leaves the folder in the list and the raw
    /// `NSCocoaErrorDomain Code=260` string in `lastError`.
    @MainActor
    func testRefreshOnADeletedFolderRemovesItAndSaysSoInWords() throws {
        let dir = try makeFolder("Cinestill 800T")
        let model = makeModel()
        let session = try XCTUnwrap(model.addFolder(dir))
        XCTAssertEqual(storedBookmarkCount, 1)

        try FileManager.default.removeItem(at: dir)
        model.rescan(session.id)

        XCTAssertTrue(model.folders.isEmpty, "the folder leaves the sidebar")
        XCTAssertNil(model.lastError, "and raises no alert")
        let notice = try XCTUnwrap(model.notice)
        XCTAssertEqual(notice, "Cinestill 800T is no longer on disk. Removed from the list.")
        XCTAssertEqual(storedBookmarkCount, 0, "and the bookmark is gone, so a relaunch does not resurrect it")
    }

    /// The anti-criterion, read off the string the user would actually see.
    @MainActor
    func testNoRawNSErrorReachesTheUserOnAnyFolderPath() throws {
        let dir = try makeFolder("roll-raw-error")
        let model = makeModel()
        let session = try XCTUnwrap(model.addFolder(dir))
        try FileManager.default.removeItem(at: dir)
        model.rescan(session.id)

        for text in [model.notice, model.lastError].compactMap({ $0 }) {
            for noise in ["Error Domain", "NSCocoaErrorDomain", "NSFilePath", "Code=260", "UserInfo="] {
                XCTAssertFalse(text.contains(noise), "\(noise) reached the user: \(text)")
            }
        }
    }

    /// The KEEP direction of refresh. Injected, because a test cannot unplug a drive.
    @MainActor
    func testRefreshOnAnOfflineVolumeKeepsTheFolderAndExplainsWhy() throws {
        let dir = try makeFolder("roll-on-a-sleeping-drive")
        let model = makeModel()
        let session = try XCTUnwrap(model.addFolder(dir))
        model.folderVerdict = { _, _ in .offline }

        model.rescan(session.id)

        XCTAssertEqual(model.folders.count, 1, "an unmounted volume NEVER removes a folder")
        XCTAssertEqual(storedBookmarkCount, 1)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.notice, "roll-on-a-sleeping-drive is on a drive that is not connected. Kept in the list.")
    }

    /// A read that fails for any other reason keeps the folder and reports one sentence.
    @MainActor
    func testAScanFailureKeepsTheFolderAndReportsOneReadableSentence() throws {
        let dir = try makeFolder("roll-unreadable")
        let model = makeModel()
        let session = try XCTUnwrap(model.addFolder(dir))
        // Present as far as the verdict is concerned, unreadable to `scan`.
        model.folderVerdict = { _, url in .live(url ?? dir, refreshedBookmark: nil) }
        try FileManager.default.removeItem(at: dir)

        model.rescan(session.id)

        XCTAssertEqual(model.folders.count, 1, "a failed read is not a reason to forget a folder")
        let text = try XCTUnwrap(model.lastError)
        XCTAssertTrue(text.hasPrefix("Could not read roll-unreadable: "), text)
        XCTAssertFalse(text.contains("Error Domain"), text)
    }

    // MARK: the activation sweep

    @MainActor
    func testTheSweepRemovesAFolderDeletedWhileTheAppWasInTheBackground() throws {
        let keep = try makeFolder("roll-keep")
        let gone = try makeFolder("roll-gone")
        let model = makeModel()
        model.addFolder(keep)
        let goneSession = try XCTUnwrap(model.addFolder(gone))
        model.selectedFolderID = goneSession.id
        model.selection = Set(goneSession.frames.map(\.id))

        try FileManager.default.removeItem(at: gone)
        let removed = model.sweepFolders()

        XCTAssertEqual(removed, ["roll-gone"])
        XCTAssertEqual(model.folders.map(\.name), ["roll-keep"])
        XCTAssertEqual(model.notice, "roll-gone is no longer on disk. Removed from the list.")
        XCTAssertNil(model.lastError)
        XCTAssertEqual(storedBookmarkCount, 1)
        // The pruned folder was the selected one, so the view moves on rather than pointing
        // at nothing (the same thing a folder change already does).
        XCTAssertEqual(model.selectedFolderID, model.folders.first?.id)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.cursor)
        XCTAssertNil(model.viewerFrameID)
    }

    @MainActor
    func testTheSweepIsSilentAndChangesNothingWhenEveryFolderIsThere() throws {
        let dir = try makeFolder("roll-fine")
        let model = makeModel()
        model.addFolder(dir)
        XCTAssertEqual(model.sweepFolders(), [])
        XCTAssertNil(model.notice, "nothing happened, so nothing is said")
        XCTAssertEqual(model.folders.count, 1)
    }

    /// The sweep runs every time the app comes forward, so this is the branch that would do
    /// the most damage if it were wrong.
    @MainActor
    func testTheSweepNeverPrunesAnOfflineVolumeAndNeverNagsAboutIt() throws {
        let dir = try makeFolder("roll-offline")
        let model = makeModel()
        model.addFolder(dir)
        model.folderVerdict = { _, _ in .offline }

        XCTAssertEqual(model.sweepFolders(), [])
        XCTAssertEqual(model.folders.count, 1)
        XCTAssertEqual(storedBookmarkCount, 1)
        XCTAssertNil(model.notice, "a sleeping drive is not news, every time he switches apps")
    }

    @MainActor
    func testTheSweepRemovesAFolderTrashedWhileTheAppWasRunning() throws {
        let dir = try makeFolder("roll-trashed-live")
        let model = makeModel()
        model.addFolder(dir)

        _ = try trash(dir)
        XCTAssertEqual(model.sweepFolders(), ["roll-trashed-live"])
        XCTAssertTrue(model.folders.isEmpty)
        XCTAssertEqual(model.notice, "roll-trashed-live is in the Trash. Removed from the list.")
        XCTAssertEqual(storedBookmarkCount, 0)
    }

    /// A volume coming back from sleep appears in the mounted list while I/O against it is
    /// still failing, so every path on it reads absent at once. One unreadable parent is a
    /// fact about the storage, not about a folder, and nothing may be removed on it.
    @MainActor
    func testNothingIsPrunedWhileTheContainingDirectoryWillNotEvenList() throws {
        let dir = try makeFolder("roll-on-a-waking-drive")
        let model = makeModel()
        model.addFolder(dir)
        model.folderVerdict = { bookmark, url in
            FolderOnDisk.verdict(resolution: .init(url: url, isStale: false),
                                 knownURL: url,
                                 presence: { _ in .missing },
                                 isInTrash: { _ in false },
                                 confirmGone: { _ in false },   // the parent will not list
                                 refreshBookmark: { _ in nil })
        }

        XCTAssertEqual(model.sweepFolders(), [])
        XCTAssertEqual(model.folders.count, 1, "an absence the storage cannot confirm is not a deletion")
        XCTAssertNil(model.notice)
    }

    /// The real `parentIsListable` wired into a real sweep, with nothing injected.
    ///
    /// Every other confirmation test hands `confirmGone` in as a closure, so this is the one
    /// test that exercises the shipped implementation through the sweep.
    ///
    /// Both directions, against the real filesystem: a folder whose parent still lists is
    /// pruned, and a folder whose whole parent tree went with it is kept.
    @MainActor
    func testTheRealConfirmationRunsInsideASweepInBothDirections() throws {
        let outer = scratch.appendingPathComponent("outer")
        let nested = outer.appendingPathComponent("roll-nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 64).write(to: nested.appendingPathComponent("1.CR2"))
        let plain = try makeFolder("roll-plain")

        let model = makeModel()
        model.addFolder(nested)
        model.addFolder(plain)
        XCTAssertEqual(model.folders.count, 2)

        // Parent survives: a real deletion, confirmed, pruned.
        try FileManager.default.removeItem(at: plain)
        XCTAssertEqual(model.sweepFolders(), ["roll-plain"])

        // Parent goes too: the absence is a fact about the storage, so nothing is removed.
        try FileManager.default.removeItem(at: outer)
        XCTAssertEqual(model.sweepFolders(), [],
                       "with the containing directory gone as well, the sweep declines to decide")
        XCTAssertEqual(model.folders.map(\.name), ["roll-nested"])
    }

    func testParentIsListableSeparatesADeletedFolderFromAnUnreadableOne() throws {
        let dir = try makeFolder("roll-parent-check")
        try FileManager.default.removeItem(at: dir)
        XCTAssertTrue(FolderOnDisk.parentIsListable(dir), "the scratch parent still lists, so the deletion is real")
        XCTAssertFalse(FolderOnDisk.parentIsListable(URL(fileURLWithPath: "/no-such-volume/no-such-dir/roll")))
    }

    @MainActor
    func testTheSweepStandsDownWhileASheetIsUp() throws {
        let dir = try makeFolder("roll-sheet-guard")
        let model = makeModel()
        model.addFolder(dir)
        try FileManager.default.removeItem(at: dir)

        model.showsExportSheet = true
        XCTAssertEqual(model.sweepFoldersIfIdle(), [], "a sheet is bound to a folder id: do not pull it out")
        XCTAssertEqual(model.folders.count, 1)

        model.showsExportSheet = false
        XCTAssertEqual(model.sweepFoldersIfIdle(), ["roll-sheet-guard"], "and it runs once the sheet is gone")
    }

    /// `didBecomeActive` fires at launch too, and can fire twice in a second.
    ///
    /// TWO casualties. With one folder the first sweep empties the list and the second call
    /// returns `[]` because there is nothing left to iterate, whether the debounce exists or
    /// not. A second folder that goes missing between the two calls is what makes the second
    /// call have something to find, so silence can only mean the debounce.
    @MainActor
    func testTheSweepIsDebounced() throws {
        let first = try makeFolder("roll-debounce-a")
        let second = try makeFolder("roll-debounce-b")
        let model = makeModel()
        model.addFolder(first)
        model.addFolder(second)

        try FileManager.default.removeItem(at: first)
        let now = Date()
        XCTAssertEqual(model.sweepFoldersIfIdle(now: now), ["roll-debounce-a"])
        XCTAssertEqual(model.folders.count, 1)

        // Now there IS something for a second sweep to find.
        try FileManager.default.removeItem(at: second)
        XCTAssertEqual(model.sweepFoldersIfIdle(now: now.addingTimeInterval(0.5)), [],
                       "the second activation inside two seconds does not re-run it")
        XCTAssertEqual(model.folders.count, 1, "and the second casualty is still listed")

        // Past the window it runs again, so the debounce delays and never disables.
        XCTAssertEqual(model.sweepFoldersIfIdle(now: now.addingTimeInterval(2.5)), ["roll-debounce-b"])
    }

    /// Removing the row is not by itself what makes the Trash case safe: a sidecar write
    /// still sitting in the 400 ms debounce would land in the folder the app has just
    /// stopped believing in, and in the Trash case that write dies when the Trash is
    /// emptied. `prune` cancels those writes and drops the security scope before it
    /// shortens the list, and `scheduleSave`'s own `frame(id)` guard backs it up.
    ///
    /// Discriminating on purpose: the folder is left ON DISK, so a write that was not
    /// stopped would succeed and be visible. Trashing it first would make the test pass
    /// whatever the code did, since the original path would be gone either way.
    @MainActor
    func testAPrunedFoldersQueuedSidecarWriteNeverLands() throws {
        let dir = try makeFolder("roll-queued-write")
        let model = makeModel()
        let session = try XCTUnwrap(model.addFolder(dir))
        let frame = try XCTUnwrap(session.frames.first)
        model.apply({ SidecarEdits.setEnhance($0, EnhanceSettings()) }, to: frame.id, actionName: "Enhance")

        model.folderVerdict = { _, _ in .gone(.trashed) }
        model.sweepFolders()
        XCTAssertTrue(model.folders.isEmpty)

        // Well past the 400 ms debounce.
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let written = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.lowercased().hasSuffix(".xmp") } ?? []
        XCTAssertEqual(written, [], "no sidecar is written for a folder that has been pruned")
    }

    // MARK: launch

    /// Folders deleted in Finder stay gone after a relaunch, even though the bookmark
    /// resolves into the Trash and `fileExists` says true.
    @MainActor
    func testATrashedFolderDoesNotComeBackOnRelaunchAndItsBookmarkIsForgotten() throws {
        let keep = try makeFolder("roll-keep")
        let gone = try makeFolder("roll-trashed")
        let first = makeModel()
        first.addFolder(keep)
        first.addFolder(gone)
        XCTAssertEqual(storedBookmarkCount, 2)

        _ = try trash(gone)

        let relaunched = makeModel()
        XCTAssertEqual(relaunched.folders.map(\.name), ["roll-keep"],
                       "a folder in the Trash is gone, however well its bookmark resolves")
        XCTAssertNil(relaunched.lastError, "and the drop is silent at launch")
        XCTAssertNil(relaunched.notice)
        XCTAssertEqual(storedBookmarkCount, 1, "nothing lingers in prefs")
    }

    /// A folder deleted outright between launches shows no session, which is what the user
    /// sees. Its bookmark is KEPT, deliberately: the blob will not resolve, and an
    /// unresolvable blob is also what a lapsed network credential and an unplugged drive
    /// look like. Removing it on that evidence is how a live folder gets forgotten.
    @MainActor
    func testAHardDeletedFolderShowsNoSessionButItsBookmarkIsNotDiscarded() throws {
        let keep = try makeFolder("roll-keep")
        let gone = try makeFolder("roll-deleted-outright")
        let first = makeModel()
        first.addFolder(keep)
        first.addFolder(gone)
        XCTAssertEqual(storedBookmarkCount, 2)

        try FileManager.default.removeItem(at: gone)

        let relaunched = makeModel()
        XCTAssertEqual(relaunched.folders.map(\.name), ["roll-keep"])
        XCTAssertNil(relaunched.lastError, "still silent at launch")
        // The assertion that makes this test about what its NAME says. Without it, pruning
        // and keeping both produce "no session and a silent launch".
        XCTAssertEqual(storedBookmarkCount, 2, "the unresolvable bookmark is KEPT, not discarded")
    }

    /// The negative test for following a move: a folder moved rather than trashed keeps
    /// working, at its new path, with a refreshed bookmark.
    @MainActor
    func testAMovedFolderComesBackAtItsNewPathWithAFreshBookmark() throws {
        let dir = try makeFolder("roll-to-move")
        let first = makeModel()
        first.addFolder(dir)
        let originalBookmark = Preferences.load().folderBookmarks.first

        let moved = scratch.appendingPathComponent("roll-moved-elsewhere")
        try FileManager.default.moveItem(at: dir, to: moved)

        let relaunched = makeModel()
        XCTAssertEqual(relaunched.folders.map(\.name), ["roll-moved-elsewhere"],
                       "a move is not a deletion: the bookmark is supposed to follow it")
        XCTAssertEqual(relaunched.folders.first?.url.standardizedFileURL.path,
                       moved.standardizedFileURL.path)
        XCTAssertEqual(relaunched.folders.first?.frames.count, 2, "and it still reads")
        XCTAssertNotEqual(Preferences.load().folderBookmarks.first, originalBookmark,
                          "the stale bookmark is re-created rather than left to die")
    }

    /// The launch half of the keep rule: a save triggered by a DIFFERENT folder being dropped
    /// must still write the unreachable one into the list, or it is lost for good.
    @MainActor
    func testAnUnreachableBookmarkSurvivesALaunchThatPrunesADifferentFolder() throws {
        let gone = try makeFolder("roll-gone")
        let offline = try makeFolder("roll-offline")
        let first = makeModel()
        let goneSession = try XCTUnwrap(first.addFolder(gone))
        first.addFolder(offline)
        XCTAssertEqual(storedBookmarkCount, 2)
        let goneBookmark = goneSession.bookmark

        try FileManager.default.removeItem(at: gone)

        // One folder genuinely gone, the other on a drive that is not mounted.
        let relaunched = makeModel(verdict: { data, _ in
            data == goneBookmark ? .gone(.deleted) : .offline
        })

        XCTAssertTrue(relaunched.folders.isEmpty, "the offline one has no session while its drive is away")
        XCTAssertEqual(storedBookmarkCount, 1, "but its bookmark is still there for when the drive returns")
        XCTAssertNotEqual(Preferences.load().folderBookmarks.first, goneBookmark)
    }

    // MARK: a vanished file under a render

    @MainActor
    func testAVanishedFileReachesTheBannerAndNotTheAlert() throws {
        let model = makeModel()
        let sentence = "IMG_0001.CR2 is no longer on disk."
        model.renders.onFileVanished?(sentence)
        XCTAssertEqual(model.notice, sentence)
        XCTAssertNil(model.renders.lastError, "a file the user deleted is not an engine failure")
        XCTAssertNil(model.lastError)
    }

    /// And the criterion it must not trample: a raw the engine REFUSED still reports in full
    /// The file is there, so the vanished branch does not apply.
    @MainActor
    func testAnEngineFailureOnAFileThatIsStillThereKeepsItsCompleteText() throws {
        let dir = try makeFolder("roll-corrupt", files: [])
        let raw = dir.appendingPathComponent("IMG_0001.CR2")
        try Data(repeating: 0xAB, count: 4096).write(to: raw)
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path),
                      "the whole point: present, and refused by the engine")
        XCTAssertEqual(FolderOnDisk.presence(of: raw), .present)
    }
}
