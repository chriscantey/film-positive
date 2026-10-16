import XCTest
import AppKit
@testable import FilmPositive

/// THE SHORTCUTS PANEL CANNOT DRIFT FROM THE MENUS, because drift is a build failure.
///
/// Every shortcuts panel in every app dies the same way: somebody adds a command and forgets
/// the doc, and nobody notices for a year because nothing checks. This reads the Commands
/// block and fails when the panel and the code disagree.
///
/// WHY IT EXCLUDES `.defaultAction` AND `.cancelAction`, which is the part worth reading
/// before anyone rewrites this the obvious way. The naive enumeration is
///
///     grep -rhoE '\.keyboardShortcut\([^)]*\)' --include=*.swift Sources/ | sort -u
///
/// and it returns 19, which is wrong twice over. `sort -u` collapses every command that
/// shares a shortcut STRING, and the set mixes menu commands with sheet buttons: 8
/// `.defaultAction` and 5 `.cancelAction` calls collapse into two entries. Counted properly
/// there are 18 menu commands in the Commands block and 13 dialog buttons everywhere else.
///
/// A test built on that grep would force the panel to list Return as "Done" and Escape as
/// "Cancel", which are macOS dialog conventions every app already has. So the reference set
/// is the Commands block with the two dialog roles excluded BY CONSTRUCTION rather than by an
/// allowlist that would itself go stale.
final class ShortcutCatalogTests: XCTestCase {

    private struct MenuCommand: Hashable {
        var label: String
        var keys: String
    }

    private var commandsFile: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FilmPositive/App/FilmPositiveApp.swift")
    }

    /// Every `Button` or `Toggle` in the Commands block that carries a shortcut, paired with
    /// the shortcut as the menu bar would draw it.
    ///
    /// The label is taken from the nearest preceding `Button(` or `Toggle(` line rather than
    /// from the same line, because several of them span lines and one is a ternary with two
    /// labels. All the string literals on that line are kept, so "Open Frame" and "Back to
    /// Grid" both count as covered.
    private func parseMenuCommands() throws -> Set<MenuCommand> {
        let text = try String(contentsOf: commandsFile, encoding: .utf8)
        var pending: [String] = []
        var out: Set<MenuCommand> = []
        var dialogRoles = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Button(") || t.hasPrefix("Toggle(") {
                let literals = t.split(separator: "\"").enumerated()
                    .filter { $0.offset % 2 == 1 }.map { String($0.element) }
                if !literals.isEmpty { pending = literals }
            }
            guard t.contains(".keyboardShortcut(") else { continue }
            if t.contains(".defaultAction") || t.contains(".cancelAction") {
                dialogRoles += 1
                continue
            }
            guard let keys = Self.render(t), let label = pending.first else { continue }
            for l in pending { out.insert(MenuCommand(label: l, keys: keys)) }
            _ = label
        }
        XCTAssertEqual(dialogRoles, 0, "a dialog role appeared inside the Commands block, which is new")
        return out
    }

    /// `.keyboardShortcut("d", modifiers: [.command])` as the menu bar draws it, `⌘D`.
    /// Modifiers in Apple's order, control then option then shift then command.
    private static func render(_ line: String) -> String? {
        var mods = ""
        if line.contains(".control") { mods += "⌃" }
        if line.contains(".option") { mods += "⌥" }
        if line.contains(".shift") { mods += "⇧" }
        if line.contains(".command") { mods += "⌘" }
        if line.contains(".return") { return mods + "↩" }
        if line.contains("(.delete") { return mods + "⌫" }
        guard let open = line.range(of: ".keyboardShortcut(\"") else { return nil }
        let rest = line[open.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        let key = String(rest[rest.startIndex..<close])
        return mods + (key.count == 1 && key.first!.isLetter ? key.uppercased() : key)
    }

    // MARK: the canaries, first, because a parser that finds nothing passes everything

    /// A scan that cannot run reports exactly what a clean scan reports, and the failure
    /// direction is toward PASS. So prove the parser reads the file and finds known commands
    /// before believing anything it says about coverage.
    func testTheParserActuallyReadsTheCommandsBlock() throws {
        let found = try parseMenuCommands()
        XCTAssertGreaterThanOrEqual(found.count, 15,
                                    "the parser found \(found.count) commands, so it is not reading the file")
        XCTAssertTrue(found.contains(MenuCommand(label: "Develop", keys: "⌘D")),
                      "canary: Develop is ⌘D and the parser must see it")
        XCTAssertTrue(found.contains(MenuCommand(label: "Show Histogram", keys: "⌘Y")),
                      "canary: a Toggle must parse too")
        XCTAssertTrue(found.contains(MenuCommand(label: "Reset Develop", keys: "⇧⌘R")),
                      "canary: a Button with two modifiers must parse too")
        XCTAssertTrue(found.contains(MenuCommand(label: "Back to Grid", keys: "⌘↩")),
                      "canary: both halves of the ternary label, and the .return key")
        XCTAssertTrue(found.contains(MenuCommand(label: "Move to Trash", keys: "⌘⌫")),
                      "canary: a named key (.delete) must parse, or the command is invisible to this test")
    }

    /// The Commands block IS the whole set. Every other shortcut in the tree is a dialog
    /// button, so if one ever appears in a view this fails and the panel's reference set has
    /// to be reconsidered rather than silently becoming incomplete.
    func testNoShortcutLivesOutsideTheCommandsBlock() throws {
        let root = commandsFile.deletingLastPathComponent().deletingLastPathComponent()
        var strays: [String] = []
        var dialogButtons = 0
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "FilmPositiveApp.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains(".keyboardShortcut(") {
                if line.contains(".defaultAction") || line.contains(".cancelAction") {
                    dialogButtons += 1
                } else {
                    strays.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertGreaterThan(dialogButtons, 5, "canary: the walk found no dialog buttons, so it is not reading")
        XCTAssertEqual(strays, [], "a shortcut outside the Commands block: the panel cannot see it")
    }

    /// No menu command takes a key the system already owns. Option Command H is Hide Others,
    /// and a command on it takes the key from the app menu's own item.
    func testNoCommandTakesASystemReservedKey() throws {
        let reserved: Set<String> = ["⌥⌘H", "⌘H", "⌘Q", "⌘M", "⌘W", "⌘,", "⌃⌘F", "⌘`", "⌘Space", "⇧⌘/"]
        let taken = try parseMenuCommands().filter { reserved.contains($0.keys) }
        XCTAssertEqual(taken.map { "\($0.label) \($0.keys)" }.sorted(), [])
    }

    /// And no two menu commands share a key, which SwiftUI resolves by silently dropping one.
    func testNoTwoMenuCommandsShareAKey() throws {
        var byKey: [String: Set<String>] = [:]
        for c in try parseMenuCommands() { byKey[c.keys, default: []].insert(c.label) }
        // "Open Frame" and "Back to Grid" are one ternary item, so they legitimately share ⌘↩.
        let clashes = byKey.filter { $0.value.count > 1 && $0.value != ["Open Frame", "Back to Grid"] }
        XCTAssertEqual(clashes.keys.sorted(), [])
    }

    // MARK: the rule

    /// EVERY menu command appears in the panel, with the same keys.
    func testThePanelListsEveryMenuCommand() throws {
        let covered = ShortcutCatalog.coveredMenuCommands
        var missing: [String] = []
        for command in try parseMenuCommands() where !covered.contains(command.label) {
            missing.append("\(command.label) (\(command.keys))")
        }
        XCTAssertEqual(missing.sorted(), [],
                       "menu commands with no row in ShortcutCatalog. Add them, or the panel is lying.")
    }

    /// And with the SAME KEYS, which is the half a membership check misses: renaming a key on
    /// an existing command would pass the test above and ship a panel that teaches the wrong
    /// press.
    func testEveryCommandsKeysAppearOnTheRowThatClaimsIt() throws {
        for command in try parseMenuCommands() {
            let rows = ShortcutCatalog.groups.flatMap(\.rows).filter { $0.menuCommands.contains(command.label) }
            guard let row = rows.first else { continue }   // covered by the test above
            XCTAssertTrue(row.keys.contains(command.keys),
                          "\(command.label) is \(command.keys) in the menu but the panel shows \"\(row.keys)\"")
        }
    }

    /// The panel does NOT claim a command that does not exist. A row pointing at a
    /// deleted menu item is the same defect facing the other way.
    func testThePanelClaimsNoMenuCommandThatIsGone() throws {
        let real = Set(try parseMenuCommands().map(\.label))
        let claimed = ShortcutCatalog.coveredMenuCommands
        XCTAssertEqual(claimed.subtracting(real).sorted(), [],
                       "the panel names menu commands the app no longer defines")
    }

    // MARK: the panel itself

    /// The groups lead with what nothing teaches. The hidden things come first and the obvious
    /// ones last, so the order is content, not decoration.
    func testTheGroupsLeadWithWhatNothingTeaches() {
        let titles = ShortcutCatalog.groups.map(\.title)
        XCTAssertEqual(titles.first, "Sliders", "the least discoverable group leads")
        XCTAssertEqual(titles.last, "The usual ones", "and the universal ones sit last")
        XCTAssertEqual(Set(titles).count, titles.count, "two groups share a title")

        // The leading group is pure gesture: nothing in it is reachable from a menu, which is
        // what "nothing teaches them" means and why it goes first.
        let first = try! XCTUnwrap(ShortcutCatalog.groups.first)
        XCTAssertTrue(first.rows.allSatisfy { $0.menuCommands.isEmpty },
                      "a menu command crept into the group that exists for things menus cannot show")
    }

    /// No empty rows and no empty groups, which a data-driven panel makes easy to ship.
    func testEveryRowSaysSomething() {
        XCTAssertGreaterThan(ShortcutCatalog.rowCount, 20)
        for group in ShortcutCatalog.groups {
            XCTAssertFalse(group.title.isEmpty)
            XCTAssertFalse(group.rows.isEmpty, "\(group.title) is an empty group")
            for row in group.rows {
                XCTAssertFalse(row.keys.trimmingCharacters(in: .whitespaces).isEmpty)
                XCTAssertFalse(row.what.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// THE ROWS ARE ALL ONE LINE HIGH, both columns, which is the difference between a table
    /// and a ragged list.
    ///
    /// A hardcoded 118 pt key column does not fit "Click the number", so that one row wraps
    /// its key onto two lines and stands 32 pt tall where every other row is 16. Nothing
    /// clips, so it reads as an uneven gap rather than as a defect. The fix matches the
    /// inspector's green axis label: the content sets the geometry and a test holds the
    /// other end.
    ///
    /// Deriving the key width removes one failure and creates its mirror: a longer key now
    /// squeezes the DESCRIPTIONS until they wrap instead. So both ends are asserted against
    /// the sheet's real width.
    func testTheKeyColumnAndTheLongestDescriptionBothFit() {
        let sheetWidth: CGFloat = 560
        let horizontalPadding: CGFloat = 20 * 2   // the ScrollView content's own padding
        let rowPadding: CGFloat = 12 * 2          // ShortcutLine's horizontal padding
        let columnGap: CGFloat = 14               // the HStack spacing

        let available = sheetWidth - horizontalPadding - rowPadding - columnGap
        let needed = ShortcutCatalog.keyColumnWidth + ShortcutCatalog.widestDescriptionWidth

        XCTAssertGreaterThan(ShortcutCatalog.keyColumnWidth, 0, "canary: the measurement returned nothing")
        XCTAssertLessThanOrEqual(needed, available,
                                 "the widest key (\(ShortcutCatalog.keyColumnWidth) pt) plus the widest "
                                 + "description (\(ShortcutCatalog.widestDescriptionWidth) pt) is "
                                 + "\(needed) pt against \(available) pt of room, so a row wraps")
    }

    /// The derived width is derived, not a constant somebody pasted back in. If the
    /// widest key changes, the width changes with it.
    func testTheKeyColumnFitsTheWidestKeyItActuallyHolds() {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                                               weight: .regular)
        for row in ShortcutCatalog.groups.flatMap(\.rows) {
            let w = (row.keys as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(w, ShortcutCatalog.keyColumnWidth,
                                     "\"\(row.keys)\" is \(w) pt and the column is only "
                                     + "\(ShortcutCatalog.keyColumnWidth) pt, so it wraps")
        }
    }

    /// The panel lists ITSELF. It has a shortcut, so the rule above applies to it like any
    /// other command, and that is a pleasant consequence of wiring ⌘/ rather than a special
    /// case: the test would have failed if the row had been forgotten.
    func testThePanelListsItsOwnShortcut() {
        XCTAssertTrue(ShortcutCatalog.coveredMenuCommands.contains("Keyboard Shortcuts"))
        let row = ShortcutCatalog.groups.flatMap(\.rows).first { $0.menuCommands.contains("Keyboard Shortcuts") }
        XCTAssertEqual(row?.keys, "⌘/")
    }
}
