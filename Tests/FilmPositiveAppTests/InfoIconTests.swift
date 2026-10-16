import XCTest
@testable import FilmPositive

/// The info icons that sit near each other in the inspector are one size and one popover.
/// Every plain info icon is `InfoGlyph`, and the Base row's, which swaps to a warning mark,
/// is drawn at its size.
final class InfoIconTests: XCTestCase {

    /// `InfoGlyph` is the only view that draws a plain info icon, so there is no second copy
    /// to drift in size or popover width.
    func testInfoGlyphIsTheOnlyPlainInfoIcon() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FilmPositive")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20, "the source walk found the sources")
        var drawers: [String] = []
        for url in files {
            let s = try String(contentsOf: url, encoding: .utf8)
            if s.contains("Image(systemName: \"info.circle\")") { drawers.append(url.lastPathComponent) }
        }
        XCTAssertEqual(drawers, ["InfoGlyph.swift"])

        let metadata = try repoSource("Sources/FilmPositive/UI/Inspector/MetadataRows.swift")
        // The Metadata section has no icon of its own. Its rows' icons stay, through
        // `RowLabel`, which draws `InfoGlyph`.
        XCTAssertFalse(metadata.contains("\"metadata.info\""))
        XCTAssertTrue(metadata.contains("InfoGlyph(text: info, identifier: identifier)"))
        // The two wands carry their own hover help and no info icon.
        let auto = try repoSource("Sources/FilmPositive/UI/Inspector/AutoEnhanceButton.swift")
        XCTAssertTrue(auto.contains("struct NeutraliseCastButton"), "canary: read the wand file")
        XCTAssertFalse(auto.contains("InfoGlyph("), "an info icon is back beside a wand")
    }

    /// The Tone row reads label, info icon, control, the Base row's shape, through
    /// `InfoGlyph` so it is the same size. The words live in `ToneNames` and say Bold, never
    /// Print. The label is the Tone title button (`DevelopRowTitle`), and the icon is its
    /// sibling.
    func testToneCarriesAnInfoIcon() throws {
        let s = try repoSource("Sources/FilmPositive/UI/Inspector/InspectorView.swift")
        XCTAssertNotNil(s.range(of: "DevelopRowTitle(row: .tone,"), "the Tone title")
        XCTAssertEqual(DevelopRow.tone.title, "Tone")
        XCTAssertEqual(DevelopRow.tone.symbol, "dial.medium")
        let label = try XCTUnwrap(s.range(of: "lit: DevelopRow.tone.lit(summary)) { model.toggleDevelopRow(.tone) }"))
        // The icon is `ToneInfoButton`, which draws `InfoGlyph` with the tone words while no
        // shown frame is thin and the warning mark while one is.
        let info = try XCTUnwrap(s.range(of: "ToneInfoButton(thin: ToneThin.status(stretchReadings))",
                                          range: label.upperBound..<s.endIndex))
        let button = try repoSource("Sources/FilmPositive/UI/Inspector/ToneThinInfo.swift")
        XCTAssertTrue(button.contains("InfoGlyph(text: ToneNames.infoHover, identifier: \"positive.toneInfo\","),
                      "not thin, the plain tone icon")
        let picker = try XCTUnwrap(s.range(of: "Picker(\"Tone\", selection: toneBinding)"))
        XCTAssertLessThan(label.lowerBound, info.lowerBound, "the word, then the icon")
        XCTAssertLessThan(info.lowerBound, picker.lowerBound, "the icon, then the control")
        XCTAssertFalse(s[label.upperBound..<info.lowerBound].contains(where: { !$0.isWhitespace }),
                       "the icon follows the word directly, as Base's does")
        XCTAssertTrue(s[picker.lowerBound...].prefix(600).contains(".labelsHidden()"),
                      "the row's Label is the only Tone label")
        XCTAssertTrue(button.contains("popover: ToneNames.infoPopover"),
                      "the popover words ride on the icon")

        XCTAssertEqual(ToneNames.infoHover, "None is the plain scan, Flat is even and editable, Bold adds contrast.")
        let popover = ToneNames.infoPopover
        XCTAssertLessThanOrEqual(popover.components(separatedBy: ". ").count, 2, "at most two sentences")
        XCTAssertTrue(popover.contains("Flat") && popover.contains("Bold"), popover)
        for text in [ToneNames.infoHover, popover] {
            XCTAssertFalse(text.contains("Print"), "Bold is the word a person sees: \(text)")
            XCTAssertFalse(text.contains(";") || text.contains("\u{2014}"), text)
            XCTAssertLessThanOrEqual(text.count, 180, text)
        }
    }

    /// The Base row's icon changes symbol with the source, so it keeps its own button, and
    /// matches `InfoGlyph` in size and popover width.
    func testTheBaseInfoIconMatchesInfoGlyph() throws {
        let glyph = try repoSource("Sources/FilmPositive/UI/Shared/InfoGlyph.swift")
        let base = try repoSource("Sources/FilmPositive/UI/Inspector/BaseInfoButton.swift")
        XCTAssertTrue(glyph.contains(".font(.caption)"))
        XCTAssertTrue(base.contains(".font(.caption)"), "the Base info icon is the caption size")
        XCTAssertTrue(glyph.contains(".frame(width: 220, alignment: .leading)"))
        XCTAssertTrue(base.contains(".frame(width: 220, alignment: .leading)"), "and the same popover width")
    }
}
