import Foundation
import FilmSidecar
import FilmPositiveCore

/// The user's own look presets and the shipped ids they have hidden.
///
/// Deliberately a plain value type with no SwiftUI and no `AppModel` in it, so the whole of
/// save, hide, restore, export and import is testable without a window (see
/// `Tests/FilmPositiveLooksTests/LookStoreTests.swift`).
///
/// Two files, both in Application Support, never in a sidecar and never per image:
///
/// - `UserLooks.fplooks` is a plain `LookFile` document written by `LookFile.encode`, so the
///   user's own store is itself a valid export and anything exported can be dropped back in.
/// - `HiddenLooks.json` holds the hidden shipped ids. This is the one piece that would fit
///   in `Preferences` instead.
///
/// Nothing in here throws away a file it cannot read. A corrupt store is moved aside with a
/// timestamped name and reported, because a decode failure must never present as an empty
/// preset list that then gets saved over.
struct LookStore {
    static let userLooksFileName = "UserLooks.\(LookFile.fileExtension)"
    static let hiddenFileName = "HiddenLooks.json"

    /// The Application Support directory this store reads and writes.
    let directory: URL

    private(set) var userLooks: [Look] = []
    private(set) var hiddenIDs: Set<String> = []

    init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/Film Positive`, created if it is not there yet.
    static func defaultDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("Film Positive", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var userLooksURL: URL { directory.appendingPathComponent(Self.userLooksFileName) }
    var hiddenURL: URL { directory.appendingPathComponent(Self.hiddenFileName) }

    // MARK: what the row shows

    /// The shipped set minus anything hidden, then the user's own, in save order.
    /// Ids are unique across the two, which is what lets the row use `ForEach` over this
    /// directly.
    var looks: [Look] {
        ShippedLooks.all.filter { !hiddenIDs.contains($0.id) } + userLooks
    }

    /// Every look including hidden ones. The Delete submenu offers `looks`, this is for
    /// counting what a reset would bring back.
    var allLooks: [Look] { ShippedLooks.all + userLooks }

    var hiddenLooks: [Look] { ShippedLooks.all.filter { hiddenIDs.contains($0.id) } }

    func look(_ id: String) -> Look? { allLooks.first { $0.id == id } }

    /// A look whose saturation is pinned to the floor is a black and white look. Read off the
    /// settings rather than an id list so another one needs no edit here. The black and white
    /// looks are ordinary one-tap buttons in the row, nothing more.
    static func isMonochrome(_ look: Look) -> Bool { look.settings.saturation <= -1.0 }

    var monochromeLooks: [Look] { looks.filter(Self.isMonochrome) }

    // MARK: load

    /// Reads both files. A missing file is the normal first-run state and is not a problem.
    /// A file that exists and will not decode is moved aside and reported, never deleted and
    /// never silently replaced by an empty list.
    @discardableResult
    mutating func load() -> [Problem] {
        var problems: [Problem] = []
        userLooks = []
        hiddenIDs = []

        if let data = Self.read(userLooksURL) {
            do {
                userLooks = try LookFile.decode(data).map { normalized($0) }
                userLooks = Self.deduplicated(userLooks)
            } catch {
                problems.append(moveAside(userLooksURL, error))
            }
        }

        if let data = Self.read(hiddenURL) {
            do {
                hiddenIDs = Set(try JSONDecoder().decode(HiddenFile.self, from: data).hidden)
            } catch {
                problems.append(moveAside(hiddenURL, error))
            }
        }
        return problems
    }

    struct Problem: Equatable {
        var file: URL
        var movedTo: URL?
        var message: String
    }

    // MARK: save, delete, restore

    enum StoreError: Error, CustomStringConvertible, Equatable {
        case emptyName
        case unknownLook(String)

        var description: String {
            switch self {
            case .emptyName: return "a look needs a name"
            case .unknownLook(let id): return "no look with id \(id)"
            }
        }
    }

    /// Save Look: the current enhance values under a name the user typed. Saving
    /// again under the same name replaces that preset in place rather than piling up copies.
    /// A name that slugs onto a shipped id gets a suffix, so a user look can never shadow a
    /// shipped one.
    @discardableResult
    mutating func saveLook(named rawName: String, settings: EnhanceSettings) throws -> Look {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError.emptyName }
        let base = Self.slug(name)
        let settings = Self.quantized(settings)

        if let index = userLooks.firstIndex(where: { $0.id == base }) {
            userLooks[index].name = name
            userLooks[index].settings = settings
            try writeUserLooks()
            return userLooks[index]
        }
        let id = uniqueID(base: base)
        let look = Look(id: id, name: name, blurb: "Your own look.", settings: settings, shipped: false)
        userLooks.append(look)
        try writeUserLooks()
        return look
    }

    enum Deletion: Equatable {
        /// A shipped preset was hidden and a reset brings it back.
        case hidden(Look)
        /// A user preset was removed from the store file.
        case removed(Look)
    }

    /// Delete. A shipped preset is hidden, because the bundle still holds it and
    /// Reset Presets has to be able to bring it back. A user preset is genuinely removed,
    /// because nothing else holds a copy and a preset the user can never delete is a bug.
    @discardableResult
    mutating func delete(_ id: String) throws -> Deletion {
        if let shipped = ShippedLooks.look(id) {
            hiddenIDs.insert(id)
            try writeHidden()
            return .hidden(shipped)
        }
        guard let index = userLooks.firstIndex(where: { $0.id == id }) else {
            throw StoreError.unknownLook(id)
        }
        let removed = userLooks.remove(at: index)
        try writeUserLooks()
        return .removed(removed)
    }

    /// Reset Presets: every hidden shipped preset comes back. User presets are not
    /// touched, because a reset of the shipped set must not resurrect something the user
    /// deleted on purpose. Idempotent.
    @discardableResult
    mutating func restoreAll() throws -> [Look] {
        let restored = hiddenLooks
        guard !hiddenIDs.isEmpty else { return [] }
        hiddenIDs.removeAll()
        try writeHidden()
        return restored
    }

    // MARK: export and import

    /// What Export Looks writes: everything the row currently shows, shipped and user alike,
    /// as one `.fplooks` document. Exporting only the user's own would write an empty file on
    /// a fresh install, and a file that carries the shipped ones round-trips cleanly because
    /// import matches them by id instead of duplicating them.
    func exportData() throws -> Data {
        try LookFile.encode(looks)
    }

    struct ImportResult: Equatable {
        /// New user presets.
        var added: [Look] = []
        /// A user preset with the same id whose contents changed.
        var replaced: [Look] = []
        /// A hidden shipped preset that the file carries unchanged, so importing brings it back.
        var restored: [Look] = []
        /// Already present, identical, nothing to do. This is what makes a re-import a no-op.
        var unchanged: [Look] = []

        var changedCount: Int { added.count + replaced.count + restored.count }
        var isEmptyChange: Bool { changedCount == 0 }
        /// The names to list back to the user, newly added first.
        var listed: [Look] { added + replaced + restored }
    }

    /// Import Looks. Everything stored is a user look. An incoming look whose id is
    /// a shipped id is matched against the bundle rather than stored: identical means nothing
    /// to do (and un-hides it if it was hidden), different means it is kept as a new user
    /// preset under a suffixed id, so an edited copy of Pop never shadows the real Pop.
    @discardableResult
    mutating func importLooks(from data: Data) throws -> ImportResult {
        let incoming = try LookFile.decode(data)
        var result = ImportResult()

        for raw in incoming {
            let look = normalized(raw)

            if let shipped = ShippedLooks.look(look.id) {
                if shipped.settings == look.settings {
                    if hiddenIDs.remove(look.id) != nil {
                        result.restored.append(shipped)
                    } else {
                        result.unchanged.append(shipped)
                    }
                } else {
                    let copy = Look(id: uniqueID(base: look.id), name: look.name, blurb: look.blurb,
                                    settings: look.settings, shipped: false)
                    userLooks.append(copy)
                    result.added.append(copy)
                }
                continue
            }

            if let index = userLooks.firstIndex(where: { $0.id == look.id }) {
                if userLooks[index] == look {
                    result.unchanged.append(look)
                } else {
                    userLooks[index] = look
                    result.replaced.append(look)
                }
                continue
            }

            userLooks.append(look)
            result.added.append(look)
        }

        if !result.added.isEmpty || !result.replaced.isEmpty { try writeUserLooks() }
        if !result.restored.isEmpty { try writeHidden() }
        return result
    }

    // MARK: disk

    private func writeUserLooks() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.writeAtomically(try LookFile.encode(userLooks), to: userLooksURL)
    }

    private func writeHidden() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(HiddenFile(version: 1, hidden: hiddenIDs.sorted()))
        try Self.writeAtomically(data, to: hiddenURL)
    }

    /// Same discipline as the sidecar writes: a crash cannot leave half a file behind.
    private static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    private static func read(_ url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func moveAside(_ url: URL, _ error: Error) -> Problem {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let target = url.appendingPathExtension("broken-\(stamp)")
        let moved = (try? FileManager.default.moveItem(at: url, to: target)) != nil
        return Problem(file: url, movedTo: moved ? target : nil,
                       message: "\(url.lastPathComponent) could not be read (\(error)). "
                              + (moved ? "It was kept as \(target.lastPathComponent)." : "It was left in place."))
    }

    private struct HiddenFile: Codable {
        var version: Int
        var hidden: [String]
    }

    // MARK: ids

    /// Anything this store holds is a user look, whatever a file claimed.
    private func normalized(_ look: Look) -> Look {
        Look(id: look.id, name: look.name, blurb: look.blurb, settings: look.settings, shipped: false)
    }

    private static func deduplicated(_ looks: [Look]) -> [Look] {
        var seen: Set<String> = []
        return looks.filter { seen.insert($0.id).inserted }
    }

    /// An id not taken by a shipped look or an existing user look.
    private func uniqueID(base: String) -> String {
        let taken = Set(allLooks.map(\.id))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// A slider dragged by hand carries more precision than the sidecar keeps, and the
    /// sidecar rounds to four decimals on the way to disk. Rounding a saved look the same way
    /// means applying it and reloading the frame gives back exactly the same numbers, so the
    /// look stays highlighted across a relaunch.
    static func quantized(_ s: EnhanceSettings) -> EnhanceSettings {
        // Through the controls rather than by wire index, so a field this app retired
        // comes out of a saved look as 0 instead of being carried along.
        var out = EnhanceSettings()
        for c in EnhanceControl.all { out[keyPath: c.path] = (s[keyPath: c.path] * 10_000).rounded() / 10_000 }
        // Levels and Curves are not sliders and ride along, at the file's grain.
        out.levels = s.levels
        out.curves = s.curves
        return out.toneQuantized
    }

    /// "Hard Candy 2" becomes "hard-candy-2". Letters and digits survive, everything else
    /// collapses to a single hyphen.
    static func slug(_ name: String) -> String {
        var out = ""
        var pendingHyphen = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingHyphen, !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.append(ch)
            } else if !out.isEmpty {
                pendingHyphen = true
            }
        }
        return out.isEmpty ? "look" : out
    }
}
