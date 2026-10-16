import XCTest
@testable import FilmPositive

/// Both Autos draw the one wand view, and it sits right after its title, Enhance's with Reset
/// alone at the right. No caption word remains in the app.
///
/// Source scans, because a SwiftUI modifier chain cannot be read at runtime. Each file read
/// is canaried first, so a scan that read nothing cannot pass.
final class AutoWandTests: XCTestCase {

    private func code(_ path: String, canary: String) throws -> String {
        let raw = try repoSource(path)
        XCTAssertTrue(raw.contains(canary), "read the wrong file or an empty one: \(path)")
        // Line comments out, so prose naming a pattern cannot satisfy or trip an assertion.
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
    }

    /// The same symbol and the same size, because both Autos are one view.
    func testBothAutosAreTheOneWand() throws {
        XCTAssertEqual(AutoWandButton.symbol, "wand.and.stars")
        let s = try code("Sources/FilmPositive/UI/Inspector/AutoEnhanceButton.swift",
                         canary: "struct AutoWandButton")
        XCTAssertTrue(s.contains("AutoWandButton(lit: model.autoEnhanceLit, help: Self.help)"))
        XCTAssertTrue(s.contains("AutoWandButton(lit: model.colorAutoLit, help: Self.help)"))
        XCTAssertEqual(s.components(separatedBy: "Image(systemName:").count - 1, 1,
                       "one glyph drawer, so the two wands cannot drift apart in size")
        XCTAssertTrue(s.contains(".accessibilityLabel(\"Auto\")"), "both read Auto to Accessibility")
        XCTAssertFalse(s.contains("AutoTextButton(lit:"), "neither Auto is the caption word any more")
    }

    /// No info icon beside either wand, and each wand's hover help is its whole explanation,
    /// short and plain.
    func testTheWandsCarryTheirOwnHelp() throws {
        let s = try code("Sources/FilmPositive/UI/Inspector/AutoEnhanceButton.swift",
                         canary: "struct NeutraliseCastButton")
        XCTAssertFalse(s.contains("InfoGlyph("), "no info icon beside a wand")
        XCTAssertFalse(s.contains(".popover("), "the hover help is the only surface")
        XCTAssertEqual(AutoEnhanceButton.help, "Auto-adjust light and color. Click again to clear.")
        XCTAssertEqual(NeutraliseCastButton.help, "Remove a color cast. Click again to clear.")
        for help in [AutoEnhanceButton.help, NeutraliseCastButton.help] {
            XCTAssertLessThanOrEqual(help.count, 100, "short: \(help)")
            XCTAssertFalse(help.contains(";") || help.contains("\u{2014}"), help)
        }
    }

    /// The Enhance header reads title, wand, Spacer, Reset, and the Color group's header reads
    /// title, wand, Spacer, both at the same 6 pt spacing.
    func testTheWandsSitBesideTheirTitles() throws {
        let s = try code("Sources/FilmPositive/UI/Inspector/InspectorView.swift",
                         canary: "private func sectionHeader(")
        let headerStart = try XCTUnwrap(s.range(of: "private func sectionHeader(")).lowerBound
        let header = String(s[headerStart...].prefix(900))
        let stack = try XCTUnwrap(header.range(of: "HStack(spacing: 6) {"))
        let title = try XCTUnwrap(header.range(of: "Self.sectionTitle(title)"))
        let wand = try XCTUnwrap(header.range(of: "if let accessory { accessory }"))
        let spacer = try XCTUnwrap(header.range(of: "Spacer()"))
        let reset = try XCTUnwrap(header.range(of: "Button(resetTitle, action: action)"))
        for (a, b, why) in [(stack, title, "the header stack holds the title"),
                            (title, wand, "the wand follows the title"),
                            (wand, spacer, "the wand sits before the Spacer, not at the right"),
                            (spacer, reset, "Reset alone at the right")] {
            XCTAssertLessThan(a.lowerBound, b.lowerBound, why)
        }
        XCTAssertTrue(s.contains("accessory: AnyView(AutoEnhanceButton())"))
        XCTAssertFalse(s.contains("trailing: AnyView(AutoEnhanceButton())"), "the wand is back at the right")

        let groupsStart = try XCTUnwrap(s.range(of: "private func enhanceSections()")).lowerBound
        let groups = String(s[groupsStart...].prefix(2500))
        let groupStack = try XCTUnwrap(groups.range(of: "HStack(spacing: 6) {"))
        let groupTitle = try XCTUnwrap(groups.range(of: "groupTitle(group)"))
        let colourWand = try XCTUnwrap(groups.range(of: "NeutraliseCastButton()"))
        let colourSpacer = try XCTUnwrap(groups.range(of: "Spacer(minLength: 0)"))
        XCTAssertLessThan(groupStack.lowerBound, groupTitle.lowerBound)
        XCTAssertLessThan(groupTitle.lowerBound, colourWand.lowerBound, "the Color wand follows its title")
        XCTAssertLessThan(colourWand.lowerBound, colourSpacer.lowerBound, "and sits before the Spacer")
    }

    /// Neither the caption-word component nor an Adjust word survives anywhere in the app. The
    /// row titles fold the sliders.
    func testNoCaptionWordRemains() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FilmPositive")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20, "the source walk found the sources")
        var uses: [String] = []
        var canary = 0
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("DevelopRowTitle(row: .tone,") { canary += 1 }
            for line in text.split(separator: "\n")
            where line.contains("AutoTextButton") || line.contains("PositiveNames.adjust") {
                uses.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        XCTAssertEqual(canary, 1, "the walk read the inspector, where the titles live")
        XCTAssertEqual(uses, [], "the Adjust word or its component is back")
    }
}
