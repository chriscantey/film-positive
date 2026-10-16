import XCTest
import FilmPositiveCore
import FilmSidecar
@testable import FilmPositive

/// The three Enhance group titles read as one family, and one of them is called Light, not
/// Tone.
///
/// Both halves are source scans, because neither can be reached from a plain type: a
/// SwiftUI modifier chain is not inspectable at runtime, so the only way to pin "every
/// group title goes through one helper in one style" is to read the file. Two different
/// styles in one header block show "Enhance" bold, a group title tiny under it, then
/// "Color" and "Detail" larger.
final class EnhanceGroupHeaderTests: XCTestCase {

    private static let inspectorPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/FilmPositive/UI/Inspector/InspectorView.swift")

    /// The file with every `//` line comment stripped, because a scan whose marker can
    /// appear as prose has no detector: the doc comment on `groupTitle` names the pattern
    /// this forbids. Code only.
    private func inspectorSource() throws -> String {
        let raw = try String(contentsOf: Self.inspectorPath, encoding: .utf8)
        // Canary: a scan that cannot read its subject reports exactly what a clean scan
        // reports, and the failure direction is toward PASS. Prove the read worked against
        // something certainly present before asserting anything about absence.
        XCTAssertTrue(raw.contains("private func enhanceSections()"),
                      "read the wrong file or an empty one: every assertion below would be meaningless")

        let code = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<comment.lowerBound])
            }
            .joined(separator: "\n")
        XCTAssertTrue(code.contains("private func enhanceSections()"),
                      "the comment stripper ate code: every assertion below would be meaningless")
        let canary = "histogram of forty frames is not one thing"
        XCTAssertTrue(raw.contains(canary), "the canary comment is gone from InspectorView, so pick another")
        XCTAssertFalse(code.contains(canary),
                       "the comment stripper did not strip comments, so prose can satisfy a code assertion")
        return code
    }

    /// One helper, one style. A bare `Text(group.rawValue)` in the header block is the
    /// defect: it puts one group title in a different style from the others.
    func testEveryGroupTitleGoesThroughTheOneHelper() throws {
        let source = try inspectorSource()

        XCTAssertEqual(source.components(separatedBy: "Text(group.rawValue)").count - 1, 1,
                       "the group title is printed in more than one place, so the three can drift apart again")
        XCTAssertEqual(source.components(separatedBy: "groupTitle(group)").count - 1, 1,
                       "the header should call groupTitle(group) once, outside the first-group branch, so all three go through it")
        XCTAssertTrue(source.contains("private func groupTitle(_ group: EnhanceControl.Group)"),
                      "the one helper that owns the group title style is gone")
    }

    /// A subtitle weight between the section title above it and the slider labels below
    /// it. Not `.caption`, which is the size that makes a group title look crushed.
    func testTheGroupTitleStyleIsSubheadlineSemiboldSecondary() throws {
        let source = try inspectorSource()
        guard let range = source.range(of: "private func groupTitle(_ group: EnhanceControl.Group)") else {
            return XCTFail("no groupTitle helper to check the style of")
        }
        // The helper's own body and nothing after it: `sectionHeader` sits a few lines
        // below and legitimately puts `.caption` on its Reset button, so a fixed-length
        // window would read that as this helper's style.
        let fromSignature = String(source[range.lowerBound...])
        guard let end = fromSignature.range(of: "\n    }") else {
            return XCTFail("could not find the end of the groupTitle body")
        }
        let body = String(fromSignature[..<end.lowerBound])

        XCTAssertTrue(body.contains(".font(.subheadline.weight(.semibold))"),
                      "group titles want a subtitle weight, not body and not caption: \(body)")
        XCTAssertTrue(body.contains(".foregroundStyle(.secondary)"),
                      "group titles are secondary to the section title: \(body)")
        XCTAssertFalse(body.contains(".caption"),
                       "a caption on a group title is the reported defect")
    }

    /// Same style is not the same treatment. A grouped Form gives a Section's header its own
    /// band and its own gap above it, so a group title only gets those if its group opens a
    /// Section. Sharing a header block with the Enhance title, "Light" gets neither: it sits
    /// 19pt under Enhance where "Color" and "Detail" sit 87pt under the rows above them.
    ///
    /// So the thing to pin is the structure: the loop's header block prints the group title
    /// and NOTHING else, which is what makes the three identical.
    func testTheGroupLoopHeaderPrintsOnlyTheGroupTitle() throws {
        let source = try inspectorSource()

        guard let range = source.range(of: "private func enhanceSections()") else {
            return XCTFail("no enhanceSections to check the shape of")
        }
        let fromSignature = String(source[range.lowerBound...])
        guard let end = fromSignature.range(of: "\n    }") else {
            return XCTFail("could not find the end of enhanceSections")
        }
        let body = String(fromSignature[..<end.lowerBound])

        XCTAssertFalse(body.contains("sectionHeader("),
                       "the Enhance title belongs in its own Section, not in the first group's header, or that group gets no band and no gap: \(body)")
        XCTAssertFalse(body.contains("allCases.first"),
                       "a branch on the first group inside the loop is how the three stopped being identical: \(body)")
    }

    /// The Enhance line keeps its own Section, and that Section holds the Looks row so it is
    /// never empty. Empty, it would sit under the histogram's Section, which is also empty
    /// with the histogram off, and two empty Sections back to back draw "Enhance" as small
    /// grey text instead of a heading.
    func testTheEnhanceTitleSectionHoldsLooksSoItIsNeverEmpty() throws {
        let source = try inspectorSource()

        XCTAssertTrue(source.contains("private func enhanceTitleSection()"),
                      "the Enhance title needs a Section of its own for the three groups to be identical")
        XCTAssertTrue(source.contains("enhanceTitleSection()\n                    enhanceSections()"),
                      "the Enhance title Section has to be placed immediately above the group Sections")

        guard let range = source.range(of: "private func enhanceTitleSection()") else {
            return XCTFail("no enhanceTitleSection to check")
        }
        let fromSignature = String(source[range.lowerBound...])
        guard let end = fromSignature.range(of: "\n    }") else {
            return XCTFail("could not find the end of enhanceTitleSection")
        }
        let body = String(fromSignature[..<end.lowerBound])

        XCTAssertTrue(body.contains("sectionHeader(\"Enhance\", resetTitle: \"Reset\""),
                      "the Enhance title and its Reset stay on one line, as the Section's header: \(body)")
        XCTAssertTrue(body.contains("LooksRow(applied: summary.look)"),
                      "the Looks row keeps this Section from ever being empty: \(body)")
        XCTAssertFalse(body.contains("EmptyView()"), "an empty Enhance Section is the reported defect: \(body)")
        XCTAssertFalse(source.contains("enhanceTitleGap"), "the hand-paid gap went with the empty Section")
    }

    /// The Enhance group is Light. Positive keeps Tone, which is the paper curve (None,
    /// Flat, Bold) and a different thing entirely.
    func testTheFirstEnhanceGroupIsCalledLight() {
        XCTAssertEqual(EnhanceControl.Group.tone.rawValue, "Light")
        XCTAssertEqual(EnhanceControl.Group.allCases.map(\.rawValue), ["Light", "Color", "Detail", "Vignette"])
        XCTAssertFalse(EnhanceControl.Group.allCases.map(\.rawValue).contains("Tone"),
                       "the Enhance group must not share a title with the Develop section's Tone row")
    }
}

/// Looks is the first group inside Enhance, it has no Reset of its own, and the
/// histogram sits directly under Frame. The export modes say what they do.
final class LooksInsideEnhanceTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testTheInspectorOrderIsFrameHistogramEnhance() throws {
        let s = try source("Sources/FilmPositive/UI/Inspector/InspectorView.swift")
        XCTAssertFalse(s.contains("looksSection("), "Looks is no longer a section of its own")
        XCTAssertFalse(s.contains("sectionHeader(\"Looks\""), "Looks has no Reset of its own; Enhance's Reset clears the same layer")
        guard let frame = s.range(of: "frameSection()\n"),
              let hist = s.range(of: "histogramSection(leadFrame)"),
              let title = s.range(of: "enhanceTitleSection()\n                    enhanceSections()") else {
            return XCTFail("inspector body order not found")
        }
        XCTAssertTrue(frame.lowerBound < hist.lowerBound && hist.lowerBound < title.lowerBound)
    }

    func testLooksIsTheFirstRowUnderEnhance() throws {
        let s = try source("Sources/FilmPositive/UI/Inspector/InspectorView.swift")
        guard let start = s.range(of: "private func enhanceTitleSection()"),
              let groups = s.range(of: "private func enhanceSections()") else {
            return XCTFail("enhanceTitleSection or enhanceSections missing")
        }
        guard let looks = s.range(of: "LooksRow(applied: summary.look)") else { return XCTFail("no Looks row") }
        XCTAssertTrue(start.lowerBound < looks.lowerBound, "Looks sits in the Enhance title Section")
        let title = String(s[start.lowerBound...])
        let titleEnd = title.range(of: "\n    }")!.lowerBound
        XCTAssertTrue(title[..<titleEnd].contains("LooksRow("), "Looks is the first row under Enhance, above Light, Color and Detail")
        XCTAssertFalse(String(s[groups.lowerBound...]).prefix(600).contains("LooksRow("), "not repeated in the group loop")
        XCTAssertEqual(s.components(separatedBy: "LooksRow(").count - 1, 1, "one Looks row in the inspector")
    }

    /// The mode is an Enhancements switch with the sparkles icon, not a Mode picker.
    func testEnhancementsIsASwitch() throws {
        let s = try source("Sources/FilmPositive/UI/Export/ExportSheet.swift")
        XCTAssertTrue(s.contains("Toggle(isOn: enhancementsBinding)"))
        XCTAssertTrue(s.contains("Self.infoTitle(\"Enhancements\", Self.blurb(mode)"))
        XCTAssertTrue(s.contains("Image(systemName: \"sparkles\")"))
        XCTAssertFalse(s.contains("Label(\"Mode\""), "Mode is gone as a row")
        XCTAssertFalse(s.contains("wand.and.stars"))
        XCTAssertFalse(s.contains("\"With Look\""))
        XCTAssertEqual(ExportSheet.blurb(.neutral), "Off: the plain positive, for editing elsewhere.")
        XCTAssertEqual(ExportSheet.blurb(.withLook), "On: each frame's Enhance settings are baked in.")
    }

    /// Every export option has its line, Color included, on the row's info icon, for the
    /// color space currently chosen.
    func testColorHasAFooterLine() throws {
        XCTAssertTrue(ExportSheet.blurb(.sRGB).hasPrefix("sRGB: "))
        XCTAssertTrue(ExportSheet.blurb(.displayP3).hasPrefix("Display P3: "))
        let s = try source("Sources/FilmPositive/UI/Export/ExportSheet.swift")
        XCTAssertTrue(s.contains("Self.infoTitle(\"Color\", Self.blurb(colorSpace)"))
    }

    /// Each row explains its CURRENT choice on an info icon after its label, the naming
    /// sentence rides on To, and the progress row lives in the button bar.
    func testTheExportExplanationsLiveOnInfoIcons() throws {
        let s = try source("Sources/FilmPositive/UI/Export/ExportSheet.swift")
        for call in ["Self.infoTitle(\"Enhancements\", Self.blurb(mode)",
                     "Self.infoTitle(\"Format\", Self.blurb(format.family)",
                     "Self.infoTitle(\"Quality\", Self.qualityBlurb(format)",
                     "Self.infoTitle(\"Color\", Self.blurb(colorSpace)",
                     "Self.infoTitle(\"To\", Self.namingText"] {
            XCTAssertTrue(s.contains(call), "missing: \(call)")
        }
        XCTAssertTrue(s.contains("InfoGlyph(text: info"), "the one shared info icon")
        // No footer at all: the progress sits in the button bar, so the form never changes
        // height.
        XCTAssertFalse(s.contains("} footer: {"), "the options card has a footer again")
        let bar = try XCTUnwrap(s.components(separatedBy: "private var buttons: some View").dropFirst().first)
        XCTAssertTrue(bar.contains("if running {\n                ProgressView"), "the progress row is in the button bar")
        XCTAssertFalse(s.contains("Text(Self.namingText"), "the naming sentence is printed on the sheet")
        XCTAssertEqual(ExportSheet.namingText, "Files take the scan's name and replace an earlier export.")
    }

    /// The To row's path is width-capped so it truncates on the label's line.
    func testThePathIsCappedSoToStaysOnOneLine() throws {
        let s = try source("Sources/FilmPositive/UI/Export/ExportSheet.swift")
        XCTAssertTrue(s.contains(".frame(maxWidth: Self.pathWidth, alignment: .trailing)"))
        XCTAssertLessThanOrEqual(ExportSheet.pathWidth, 240)
    }

    /// The To row after the export is one line too, truncated in the middle so the folder at
    /// the tail survives a long path, with the whole path on hover.
    func testTheResultsPathIsOneLineWithTheTailKept() throws {
        let s = try source("Sources/FilmPositive/UI/Export/ExportSheet.swift")
        XCTAssertTrue(s.contains(".frame(maxWidth: Self.summaryPathWidth, alignment: .trailing)"))
        XCTAssertFalse(s.contains("LabeledContent(\"To\", value: folder.path)"))
        XCTAssertLessThanOrEqual(ExportSheet.summaryPathWidth, 360)
    }

    /// No user-facing copy names another product as a destination or claims what we
    /// have not measured. Checked on the strings the app actually shows, not on source.
    func testNoCopyNamesAnotherProductOrAnUnmeasuredClaim() {
        var copy: [String] = ExportMode.allCases.map { ExportSheet.blurb($0) }
        copy += ExportFamily.allCases.map { ExportSheet.blurb($0) }
        copy += ExportFamily.allCases.flatMap(\.options).map { ExportSheet.qualityBlurb($0) }
        copy += ExportColorSpace.allCases.map { ExportSheet.blurb($0) }
        copy += [ExportSheet.namingText]
        copy += [InspectorView.toneMixedHelp, InspectorView.stockOneHelp, InspectorView.stockMixedHelp]
        copy += ShippedLooks.all.map(\.blurb)
        // The two wands' words (their hover help), the Tone info icon's, and a rejected
        // profile's message.
        copy += [AutoEnhanceButton.help, NeutraliseCastButton.help]
        copy += [ToneNames.infoHover, ToneNames.infoPopover]
        copy += [ProfilePackage.PackageError.filmlabDerived("x").description]
        XCTAssertGreaterThan(copy.count, 20, "canary: the copy list is not empty")
        for line in copy {
            for banned in ["Photos", "Apple", "FilmLab", "Lightroom", "grading tool", "best hand-off", "right hand-off", "visually identical"] {
                XCTAssertFalse(line.contains(banned), "\(banned) in: \(line)")
            }
            XCTAssertFalse(line.contains("\u{2014}"), "em-dash in: \(line)")
            XCTAssertFalse(line.contains(";"), "semicolon in: \(line)")
        }
    }

    /// The two wands' hover texts stay short.
    func testTheWandAndNeutralizeTextsAreShort() {
        for text in [AutoEnhanceButton.help, NeutraliseCastButton.help] {
            XCTAssertLessThanOrEqual(text.count, 180, text)
        }
    }
}
