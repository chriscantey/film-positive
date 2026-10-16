import XCTest
import FilmSidecar
@testable import FilmPositive

/// The Tone row's WORDS: one constant for the third setting's name, and one help text per
/// setting.
///
/// Two separate guarantees, and the second one is the reason this file scans source rather
/// than only calling functions. The third tone may be renamed, and a rename is only one
/// edit if no other file spells the word. A unit test on `ToneNames.third` cannot see a
/// stray `Text("Print")` three files away, which is exactly the thing that would survive
/// the rename and go out looking wrong.
final class ToneNamesTests: XCTestCase {

    // MARK: the name lives in one place

    /// The stored value is the contract with every sidecar already on disk and must not
    /// follow the display name anywhere.
    func testTheSidecarValueIsNotTheDisplayName() {
        XCTAssertEqual(ToneMode.print.rawValue, "print",
                       "the stored value is what old files read; only the display string may change")
        XCTAssertEqual(ToneMode.none.rawValue, "none")
        XCTAssertEqual(ToneMode.flat.rawValue, "flat")
    }

    func testEveryModeHasANameAndTheyAreDistinct() {
        let names = ToneNames.all.map { $0.displayName }
        XCTAssertEqual(names.count, 3)
        XCTAssertEqual(Set(names).count, 3, "two settings shared a name")
        for name in names {
            XCTAssertFalse(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        XCTAssertEqual(ToneMode.print.displayName, ToneNames.third)
    }

    /// The scan. Every user-facing occurrence of the third tone's name in the app target
    /// has to come from the constant, so the literal appears in exactly one file:
    /// `ToneNames.swift`, where it is defined. Comments are allowed everywhere, because
    /// prose explaining the setting is not what a rename has to chase.
    ///
    /// It searches for the CURRENT value of `ToneNames.third` rather than a hardcoded
    /// "Print", so the test still guards the rule after a rename.
    func testTheThirdToneNameAppearsInNoOtherSourceFile() throws {
        try assertNameIsSpelledOnlyInToneNames(ToneNames.third)
    }

    private func assertNameIsSpelledOnlyInToneNames(_ word: String) throws {
        var offenders: [String] = []
        for file in try Self.appSources() {
            guard file.lastPathComponent != "ToneNames.swift" else { continue }
            let code = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
            for (n, line) in code.components(separatedBy: "\n").enumerated() where Self.mentions(word, in: line) {
                offenders.append("\(file.lastPathComponent):\(n + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [],
                       "the third tone's name is spelled outside ToneNames.swift, so a rename would miss it")
    }

    /// It must not fire on a longer word that merely contains the name, or a rename back
    /// to "Print" would trip over `prettyPrinted` in the look store.
    func testTheScanIgnoresALongerWord() {
        XCTAssertFalse(Self.mentions("Print", in: "enc.outputFormatting = [.prettyPrinted]"))
        XCTAssertTrue(Self.mentions("Print", in: "Text(\"Print\")"))
        XCTAssertFalse(Self.mentions("Bold", in: ".fontWeight(.semiBoldish)"))
    }

    /// The scan is only worth having if it can fire. A detector proven on a clean tree has
    /// not been proven at all, so hand it a file that does spell the word.
    func testTheScanCatchesAStrayLiteral() {
        let hostile = """
            Text("\(ToneNames.third)").tag(ToneMode.print)   // a comment naming \(ToneNames.third) is fine
            // Text("\(ToneNames.third)") on a commented-out line is fine too
            """
        let stripped = Self.strippingComments(hostile)
        let hits = stripped.components(separatedBy: "\n").filter { Self.mentions(ToneNames.third, in: $0) }
        XCTAssertEqual(hits.count, 1, "the comment stripper either ate the real line or kept a comment")
    }

    // MARK: the help texts

    /// The Tone row's info icon is the one place the tones are explained, in one line that
    /// names every setting by its display name. The segmented control carries no per-setting
    /// text.
    func testTheInfoLineNamesEverySetting() {
        let text = ToneNames.infoHover
        for mode in ToneNames.all {
            XCTAssertTrue(text.contains(mode.displayName), "\(mode.displayName) is missing")
        }
        XCTAssertTrue(text.hasSuffix("."), "the info line is a sentence")
    }

    /// No technical detail in the Tone help. The measured black, a bounded exponent and the
    /// operator are what the render log is for.
    func testTheHelpTextsCarryNoNumbers() {
        for text in [ToneNames.infoHover, ToneNames.infoPopover, InspectorView.toneMixedHelp] {
            XCTAssertNil(text.rangeOfCharacter(from: .decimalDigits), "a number: \(text)")
            for jargon in ["exponent", "operator", "gamma", "curve", "LUT", "scene-referred"] {
                XCTAssertFalse(text.lowercased().contains(jargon.lowercased()),
                               "jargon (\(jargon)) in: \(text)")
            }
        }
    }

    /// American spelling in everything the Tone row shows.
    func testTheHelpTextsUseAmericanSpelling() {
        for text in [ToneNames.infoHover, ToneNames.infoPopover, InspectorView.toneMixedHelp] {
            XCTAssertFalse(text.lowercased().contains("colour"))
            XCTAssertFalse(text.lowercased().contains("grey"))
        }
    }

    // MARK: scanning

    /// Whole words only. A name like "Print" is a substring of `prettyPrinted`, and a
    /// scan that cannot tell those apart fails on a file it has no business reading.
    static func mentions(_ word: String, in line: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b") else {
            return line.contains(word)
        }
        return re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func appSources() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)     // Tests/FilmPositiveAppTests/<this file>
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let target = root.appendingPathComponent("Sources/FilmPositive")
        var out: [URL] = []
        let walker = FileManager.default.enumerator(at: target, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if url.pathExtension == "swift" { out.append(url) }
        }
        XCTAssertGreaterThan(out.count, 10, "the source scan found almost nothing: wrong path?")
        return out
    }

    /// Drops `//` line comments and `/* */` blocks while leaving string literals intact,
    /// including multi-line ones, so a URL inside a string does not truncate the line and
    /// a `"""` block is never mistaken for a comment.
    static func strippingComments(_ source: String) -> String {
        var out = ""
        var chars = Array(source)
        var i = 0
        var inLine = false, inBlock = false, inString = false, inMultiline = false
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            let third: Character? = i + 2 < chars.count ? chars[i + 2] : nil
            if inLine {
                if c == "\n" { inLine = false; out.append(c) }
                i += 1; continue
            }
            if inBlock {
                if c == "*" && next == "/" { inBlock = false; i += 2; continue }
                if c == "\n" { out.append(c) }
                i += 1; continue
            }
            if inMultiline {
                out.append(c)
                if c == "\"" && next == "\"" && third == "\"" {
                    out.append("\""); out.append("\""); inMultiline = false; i += 3; continue
                }
                i += 1; continue
            }
            if inString {
                out.append(c)
                if c == "\\" { if let n = next { out.append(n) }; i += 2; continue }
                if c == "\"" { inString = false }
                i += 1; continue
            }
            if c == "\"" && next == "\"" && third == "\"" {
                out.append("\"\"\""); inMultiline = true; i += 3; continue
            }
            if c == "\"" { out.append(c); inString = true; i += 1; continue }
            if c == "/" && next == "/" { inLine = true; i += 2; continue }
            if c == "/" && next == "*" { inBlock = true; i += 2; continue }
            out.append(c)
            i += 1
        }
        return out
    }
}
