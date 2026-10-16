import XCTest
import SwiftUI
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The Base and Tone titles fold their sliders, and a title reads lit while its row is in
/// use. Stock is a plain row with no fold (`PlainStockRowTests`).
final class DevelopRowTitleTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    /// The inspector source with line comments out, so prose naming a pattern cannot satisfy
    /// or trip an assertion. Canaried, so a scan that read nothing cannot pass.
    private func inspector() throws -> String {
        let raw = try repoSource("Sources/FilmPositive/UI/Inspector/InspectorView.swift")
        XCTAssertTrue(raw.contains("private func developSection()"), "read the wrong file or an empty one")
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
    }

    @MainActor
    private func seed(_ m: AppModel, _ id: Frame.ID, _ edit: (inout DevelopSettings) -> Void = { _ in }) {
        m.undoManager.beginUndoGrouping()
        m.apply({ s in
            var develop = DevelopSettings(stock: "kodak-gold-200", tone: .flat, autoBalance: true,
                                          base: BaseSettings(mode: .anchor))
            edit(&develop)
            return SidecarEdits.setDevelop(s, develop)
        }, to: id, actionName: "seed")
        m.undoManager.endUndoGrouping()
    }

    // MARK: the fold

    /// Each title toggles its OWN remembered preference and nothing else, saved app-wide,
    /// with no sidecar written and no undo step registered.
    @MainActor
    func testEachTitleTogglesItsPreferenceOnly() throws {
        let (m, ids) = try scratchRollModel(frames: 1, in: scratch)
        seed(m, ids[0])
        m.selection = [ids[0]]
        let sidecar = m.frame(ids[0])?.sidecar
        let undoName = m.undoManager.undoActionName
        let canUndo = m.undoManager.canUndo

        for row in DevelopRow.allCases {
            XCTAssertFalse(row.isOpen(m.prefs), "\(row) is closed by default")
        }
        for row in DevelopRow.allCases {
            let others = DevelopRow.allCases.filter { $0 != row }.map { $0.isOpen(m.prefs) }
            m.toggleDevelopRow(row)
            XCTAssertTrue(row.isOpen(m.prefs), "\(row) opened")
            XCTAssertTrue(row.isOpen(Preferences.load()), "\(row) saved app-wide")
            XCTAssertEqual(DevelopRow.allCases.filter { $0 != row }.map { $0.isOpen(m.prefs) }, others,
                           "\(row) moved another row's fold")
            m.toggleDevelopRow(row)
            XCTAssertFalse(row.isOpen(Preferences.load()), "\(row) closed again")
        }
        XCTAssertEqual(m.frame(ids[0])?.sidecar, sidecar, "no sidecar changed")
        XCTAssertEqual(m.undoManager.undoActionName, undoName, "no undo step")
        XCTAssertEqual(m.undoManager.canUndo, canUndo, "no undo step")
    }

    /// Each title reads its row's existing preference, so a stored fold opens the same rows
    /// it did.
    func testEachTitleReadsItsExistingPreference() {
        var p = Preferences()
        p.showsColourAxes = true
        XCTAssertEqual(DevelopRow.allCases.map { $0.isOpen(p) }, [true, false])
        p = Preferences()
        p.showsToneAdjust = true
        XCTAssertEqual(DevelopRow.allCases.map { $0.isOpen(p) }, [false, true])
    }

    // MARK: the lit rule

    /// Each title is lit exactly when ANY selected frame has that row's values in use, and
    /// by its own row only.
    @MainActor
    func testTheLitRulePerRow() throws {
        let (m, ids) = try scratchRollModel(frames: 2, in: scratch)
        for id in ids { seed(m, id) }
        m.selection = Set(ids)
        XCTAssertEqual(DevelopRow.allCases.map { $0.lit(m.selectionSummary) }, [false, false],
                       "nothing in use, nothing lit")

        let cases: [(DevelopRow, (inout DevelopSettings) -> Void)] = [
            (.base, { $0.colourAxes = ColourAxes(warm: 0, green: -2) }),
            (.tone, { $0.toneAdjust = ToneAdjust(exposure: -0.06, contrast: 1, black: 0.11, white: 0.92) }),
        ]
        for (row, edit) in cases {
            for id in ids { seed(m, id) }
            seed(m, ids[1], edit)
            m.selection = Set(ids)
            let summary = m.selectionSummary
            XCTAssertEqual(DevelopRow.allCases.map { $0.lit(summary) }, DevelopRow.allCases.map { $0 == row },
                           "one frame of two in use lights \(row) and only \(row)")
        }
    }

    /// A closed row is closed, edits or not: with both rows carrying edits and both folds
    /// closed, every title reads lit and no row's sliders are on screen. Opening each
    /// shows them with the edit, closing hides them again, and the lit titles never move.
    @MainActor
    func testAClosedRowWithEditsShowsNoSlidersAndReadsLit() throws {
        let (m, ids) = try scratchRollModel(frames: 1, in: scratch)
        seed(m, ids[0]) {
            $0.colourAxes = ColourAxes(warm: 0, green: -2)
            $0.toneAdjust = ToneAdjust(exposure: -0.06, contrast: 1, black: 0.11, white: 0.92)
        }
        m.selection = [ids[0]]
        let sidecar = m.frame(ids[0])?.sidecar
        let undoName = m.undoManager.undoActionName
        let canUndo = m.undoManager.canUndo

        // The two gates exactly as the inspector asks them, on a color selection.
        func shown(_ row: DevelopRow) -> Bool {
            switch row {
            case .base: return PositiveRows.axesShown(open: m.prefs.showsColourAxes, mono: false)
            case .tone: return ToneAdjustRows.shown(open: m.prefs.showsToneAdjust)
            }
        }
        let lit = { DevelopRow.allCases.map { $0.lit(m.selectionSummary) } }
        XCTAssertEqual(lit(), [true, true], "every row carries an edit")
        XCTAssertEqual(DevelopRow.allCases.map(shown), [false, false], "closed rows show no sliders")

        for row in DevelopRow.allCases {
            m.toggleDevelopRow(row)
            XCTAssertTrue(shown(row), "\(row) open shows its sliders")
            XCTAssertEqual(lit(), [true, true])
            m.toggleDevelopRow(row)
            XCTAssertFalse(shown(row), "\(row) closed again hides them")
            XCTAssertEqual(lit(), [true, true], "\(row) still lit")
        }
        XCTAssertEqual(m.frame(ids[0])?.sidecar, sidecar, "no sidecar changed")
        XCTAssertEqual(m.undoManager.undoActionName, undoName, "no undo step")
        XCTAssertEqual(m.undoManager.canUndo, canUndo, "no undo step")
    }

    /// The inspector gates each row's sliders on its fold and on nothing a frame carries: the
    /// two gate calls name the fold (and mono, for Base), and no in-use flag.
    func testTheInspectorGatesTheSlidersOnTheFoldAlone() throws {
        let s = try inspector()
        for call in ["ToneAdjustRows.shown(open: model.prefs.showsToneAdjust)",
                     "PositiveRows.visibleRows(autoColor: summary.autoBalance, mono: monoSelection,\n                                 axesOpen: model.prefs.showsColourAxes)"] {
            XCTAssertEqual(s.components(separatedBy: call).count - 1, 1, call)
        }
        for gate in ["ToneAdjustRows.shown(", "PositiveRows.visibleRows("] {
            let start = try XCTUnwrap(s.range(of: gate), gate)
            let call = String(s[start.lowerBound...].prefix { $0 != ")" })
            XCTAssertFalse(call.contains("InUse"), "\(gate) reads an in-use flag: \(call)")
        }
    }

    // MARK: the words and ids

    /// Every string as shipped: the titles, the hover help, the accessibility label in the
    /// section titles' form, and the ids on the titles.
    func testTheWordsAndIdsAsShipped() {
        XCTAssertEqual(DevelopRow.allCases.map(\.title), ["Base", "Tone"])
        XCTAssertEqual(DevelopRow.allCases.map(\.symbol), ["swatchpalette", "dial.medium"])
        XCTAssertEqual(DevelopRow.allCases.map(\.identifier), ["positive.adjust", "tone.adjust"])
        XCTAssertEqual(DevelopRow.allCases.map { $0.help(open: false) },
                       ["Show the Base sliders", "Show the Tone sliders"])
        XCTAssertEqual(DevelopRow.allCases.map { $0.help(open: true) },
                       ["Hide the Base sliders", "Hide the Tone sliders"])
        XCTAssertEqual(DevelopRow.allCases.map { $0.accessibilityLabel(open: false) },
                       ["Base, expand", "Tone, expand"])
        XCTAssertEqual(DevelopRow.allCases.map { $0.accessibilityLabel(open: true) },
                       ["Base, collapse", "Tone, collapse"])
        for row in DevelopRow.allCases {
            XCTAssertEqual(row.accessibilityLabel(open: true), SectionFold.accessibilityLabel(row.title, open: true))
            XCTAssertNotNil(NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil), "\(row)")
            for text in [row.help(open: true), row.help(open: false)] {
                XCTAssertFalse(text.contains("Adjust") || text.contains("\u{2014}") || text.contains(";"), text)
            }
        }
    }

    // MARK: the group

    /// The Base rows carry no caption, and neither does any other group: the slider group
    /// has no caption to draw, and the Base pair's own labels are unchanged.
    func testTheBaseRowsCarryNoCaption() throws {
        XCTAssertEqual(ColourAxis.allCases.map(\.label), ["Cool \u{2194} Warm", "Green \u{2194} Magenta"])
        let s = try inspector()
        XCTAssertEqual(s.components(separatedBy: "DevelopSliderGroup {").count - 1, 2, "Base's group and Tone's")
        XCTAssertFalse(s.contains("DevelopSliderGroup(caption:"))
        let raw = try repoSource("Sources/FilmPositive/UI/Inspector/DevelopRowTitle.swift")
        let start = try XCTUnwrap(raw.range(of: "struct DevelopSliderGroup")).lowerBound
        let view = String(raw[start...])
        for absent in ["caption", "Text("] {
            XCTAssertFalse(view.contains(absent), "the group draws \(absent)")
        }
        let raw2 = try repoSource("Sources/FilmPositive/UI/Inspector/InspectorView.swift")
        for word in ["Whole picture", "\"Highlights\""] {
            XCTAssertFalse(raw2.contains(word) || raw.contains(word), word)
        }
    }

    /// Each row's sliders are ONE group under their own title, in the draw order Base, Tone,
    /// and the group lays its rows out itself.
    func testEachRowsSlidersAreOneGroupUnderTheirTitle() throws {
        let s = try inspector()
        var last = s.startIndex
        for (row, rowsCall) in [(DevelopRow.base, "setColourAxis(axis, to: $0)"),
                                (.tone, "ToneAdjustRow(")] {
            let title = try XCTUnwrap(s.range(of: "DevelopRowTitle(row: .\(row.rawValue),", range: last..<s.endIndex))
            let group = try XCTUnwrap(s.range(of: "DevelopSliderGroup {",
                                              range: title.upperBound..<s.endIndex), "\(row) group")
            let rows = try XCTUnwrap(s.range(of: rowsCall, range: group.upperBound..<s.endIndex), "\(row) rows")
            if let next = s.range(of: "DevelopRowTitle(", range: title.upperBound..<s.endIndex) {
                XCTAssertLessThan(group.lowerBound, next.lowerBound, "\(row)'s group sits under its own title")
            }
            last = rows.upperBound
        }
        XCTAssertEqual(s.components(separatedBy: "DevelopSliderGroup {").count - 1, 2)

        let raw = try repoSource("Sources/FilmPositive/UI/Inspector/DevelopRowTitle.swift")
        let start = try XCTUnwrap(raw.range(of: "struct DevelopSliderGroup")).lowerBound
        let view = String(raw[start...])
        XCTAssertTrue(view.contains(".labeledContentStyle(DevelopGroupRowStyle())"),
                      "the group lays its rows out itself, so a label never runs into its track")
        // Both row kinds hold their label to one line, so the track gives up the width the
        // indent takes ("Green ↔ Magenta" wraps to two lines without it).
        for file in ["ColourAxisRow.swift", "ToneAdjustRow.swift"] {
            let row = try repoSource("Sources/FilmPositive/UI/Inspector/\(file)")
            XCTAssertTrue(row.contains(".lineLimit(1)\n                .fixedSize(horizontal: true, vertical: false)"), file)
        }
    }

    /// The group, its row style and its row, from `struct DevelopSliderGroup` up to the label
    /// width key, with line comments out so prose cannot satisfy or trip an assertion.
    /// Canaried on the three types, so a scan that read the wrong span cannot pass.
    private func groupSource() throws -> String {
        let raw = try repoSource("Sources/FilmPositive/UI/Inspector/DevelopRowTitle.swift")
        let start = try XCTUnwrap(raw.range(of: "struct DevelopSliderGroup<Rows: View>: View {")).lowerBound
        let end = try XCTUnwrap(raw.range(of: "struct DevelopLabelWidth: PreferenceKey")).lowerBound
        let span = String(raw[start..<end]).split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
        for canary in ["struct DevelopSliderGroup", "struct DevelopGroupRowStyle", "struct DevelopGroupRow: View",
                       "configuration.label", "configuration.content"] {
            XCTAssertTrue(span.contains(canary), "read the wrong span: no \(canary)")
        }
        return span
    }

    /// Each `DevelopSliderGroup { ... }` in the inspector, braces matched, with line comments
    /// out, and what follows its closing brace.
    private func inspectorGroups() throws -> [(body: String, after: String)] {
        let s = try inspector()
        var groups: [(String, String)] = []
        var from = s.startIndex
        while let open = s.range(of: "DevelopSliderGroup {", range: from..<s.endIndex) {
            var depth = 1
            var i = open.upperBound
            while depth > 0 && i < s.endIndex {
                if s[i] == "{" { depth += 1 } else if s[i] == "}" { depth -= 1 }
                i = s.index(after: i)
            }
            XCTAssertEqual(depth, 0, "an unclosed group")
            let body = String(s[open.upperBound..<s.index(before: i)])
            let after = String(s[i...].drop { $0.isWhitespace }.prefix(40))
            groups.append((body, after))
            from = i
        }
        return groups
    }

    /// The group draws no line of its own: no rule, no hairline, no divider, no border and no
    /// shape in the group, its row style or its row, and nothing that moves the Form's own
    /// separators. The one background is the label width probe, a clear color. In the
    /// inspector, neither group's body holds a `Divider` and neither group carries a
    /// modifier, so each is still one bare Form row.
    func testTheGroupDrawsNoLine() throws {
        let span = try groupSource()
        for absent in ["Rectangle", "Divider", ".separator", ".overlay", ".border", ".stroke", "Path",
                       "Capsule", "RoundedRectangle", "listRowSeparator", "listRowInsets", ".fill("] {
            XCTAssertFalse(span.contains(absent), "the group draws \(absent)")
        }
        XCTAssertEqual(span.components(separatedBy: ".background(").count - 1, 1, "only the width probe")
        XCTAssertTrue(span.contains(".background(GeometryReader { g in\n                    Color.clear.preference("),
                      "the one background is the clear width probe")
        XCTAssertTrue(span.contains("VStack(alignment: .leading, spacing: Self.rowGap) {\n            rows\n        }"),
                      "the rows stack in one view, so the group is one Form row")

        let groups = try inspectorGroups()
        XCTAssertEqual(groups.count, 2, "Base's group and Tone's")
        for (n, g) in groups.enumerated() {
            XCTAssertFalse(g.body.isEmpty, "group \(n) read nothing")
            XCTAssertTrue(g.body.contains(n == 0 ? "ColourAxisRow(" : "ToneAdjustRow("), "group \(n) holds its rows")
            for absent in ["Divider", "listRowSeparator", "Rectangle"] {
                XCTAssertFalse(g.body.contains(absent), "group \(n) holds \(absent)")
            }
            XCTAssertFalse(g.after.hasPrefix("."), "group \(n) carries a modifier: \(g.after)")
        }
    }

    /// The rows sit 14 pt in from the row's leading edge, and that is the group's only
    /// padding.
    func testTheGroupIndentIs14() throws {
        XCTAssertEqual(DevelopSliderGroup<EmptyView>.indent, 14)
        let span = try groupSource()
        XCTAssertEqual(span.components(separatedBy: ".padding(").count - 1, 1, "one padding in the group")
        XCTAssertTrue(span.contains(".padding(.leading, Self.indent)\n    }\n}"),
                      "the indent is the group's last modifier")
    }

    /// A slider row's label and icon are quiet, secondary at `.callout`, on the label alone.
    /// The track, fill, tick and readout keep their own styles: the row style sets no font
    /// or color on the content, and draws no opacity of its own, so a disabled row dims the
    /// way the system dims a disabled control.
    func testTheSliderLabelsAreQuiet() throws {
        let span = try groupSource()
        XCTAssertTrue(span.contains("configuration.label\n                .font(.callout)\n                .foregroundStyle(.secondary)\n                .fixedSize()"),
                      "the label is secondary at callout")
        XCTAssertTrue(span.contains("configuration.content\n                .frame(maxWidth: .infinity)\n        }"),
                      "the content is laid out and not restyled")
        XCTAssertEqual(span.components(separatedBy: ".font(").count - 1, 1, "one font, the label's")
        XCTAssertEqual(span.components(separatedBy: ".foregroundStyle(").count - 1, 1, "one color, the label's")
        for absent in [".opacity(", "isEnabled", ".tint(", ".controlSize("] {
            XCTAssertFalse(span.contains(absent), "the row style sets \(absent)")
        }
    }

    // MARK: the Tone tracks (item 3)

    /// The drawn fill grows from the scale's own neutral, which is None's values, never
    /// from the preset's.
    func testTheToneTracksDrawFromTheScalesNeutral() {
        XCTAssertEqual(ToneSlider.allCases.map(\.neutral), [0, 0, 0, 100])
        for slider in ToneSlider.allCases {
            XCTAssertEqual(slider.readout(slider.neutral), slider.readout(slider.value(in: ToneAdjust.preset(for: .none))),
                           "\(slider): the neutral is None's value")
            XCTAssertTrue(slider.range.contains(slider.neutral), "\(slider)")
        }
        let s = try? repoSource("Sources/FilmPositive/UI/Inspector/ToneAdjustRow.swift")
        XCTAssertTrue(s?.contains("neutral: slider.neutral,") == true, "the track is drawn from the neutral")
        XCTAssertFalse(s?.contains("neutral: origin,") == true, "and no longer from the preset")
    }

    /// What each preset DRAWS, untouched: the fill from the neutral to the preset's value.
    /// None draws empty tracks, Flat fills Black to 20 and pulls White back to 92, Bold
    /// draws Exposure at -1.00, Contrast at 1.00 and Black at 20.
    func testWhatEachPresetDraws() {
        func fills(_ mode: ToneMode) -> [String] {
            ToneSlider.allCases.map { slider in
                let v = slider.value(in: ToneAdjust.preset(for: mode))
                return slider.readout(v) == slider.readout(slider.neutral)
                    ? "empty" : "\(slider.readout(slider.neutral))>\(slider.readout(v))"
            }
        }
        XCTAssertEqual(fills(.none), ["empty", "empty", "empty", "empty"])
        XCTAssertEqual(fills(.flat), ["empty", "empty", "0>20", "100>92"])
        XCTAssertEqual(fills(.print), ["0.00>-1.00", "0.00>1.00", "0>20", "empty"])
    }

    /// The tick per preset, as a pure function: at the preset's value, and none where the
    /// preset sits on the neutral (the start of the fill already marks it).
    func testTheTickPerPreset() {
        func ticks(_ mode: ToneMode) -> [String] {
            ToneSlider.allCases.map { s in s.tick(for: mode).map { s.readout($0) } ?? "-" }
        }
        XCTAssertEqual(ticks(.none), ["-", "-", "-", "-"])
        XCTAssertEqual(ticks(.flat), ["-", "-", "20", "92"])
        XCTAssertEqual(ticks(.print), ["-1.00", "1.00", "20", "-"])
        for mode in [ToneMode.none, .flat, .print] {
            for slider in ToneSlider.allCases {
                if let t = slider.tick(for: mode) {
                    XCTAssertEqual(t, slider.value(in: ToneAdjust.preset(for: mode)), "\(mode) \(slider)")
                    XCTAssertTrue(slider.range.contains(t), "\(mode) \(slider)")
                }
            }
        }
    }

    /// The selection's tick: the shared tone's, and none while the frames disagree about
    /// the tone. The reset target is unchanged: the frame's own preset.
    func testTheSelectionsTick() throws {
        let bold = try sidecar(tone: .print)
        let flat = try sidecar(tone: .flat)
        let one = SelectionSummary([bold])
        XCTAssertEqual(one.toneTick(.exposure), ToneSlider.exposure.tick(for: .print))
        XCTAssertEqual(one.originValue(.exposure), ToneSlider.exposure.value(in: ToneAdjust.preset(for: .print)),
                       "a double-click still returns to Bold's own value")
        XCTAssertEqual(one.trackPosition(.black), 20, accuracy: 1e-9, "the stored number drawn as it was")
        let mixed = SelectionSummary([bold, flat])
        for slider in ToneSlider.allCases { XCTAssertNil(mixed.toneTick(slider), "\(slider)") }
    }

    /// A mark on the line look is centered on its value and kept whole inside the track.
    func testTheTickStaysOnTheTrack() {
        let w: CGFloat = 100
        XCTAssertEqual(CentreOriginTrack.markX(50, width: w), 50 - CentreOriginTrack.markWidth / 2)
        XCTAssertEqual(CentreOriginTrack.markX(0, width: w), 0)
        XCTAssertEqual(CentreOriginTrack.markX(w, width: w), w - CentreOriginTrack.markWidth)
        XCTAssertGreaterThan(CentreOriginTrack.markHeight, CentreOriginTrack.trackHeight, "it stands across the track")
    }

    private func sidecar(tone: ToneMode) throws -> Sidecar {
        let image = scratch.appendingPathComponent("IMG_\(UUID().uuidString.prefix(8)).CR2")
        try Data(repeating: 0x42, count: 2048).write(to: image)
        var s = Sidecar(source: try SidecarStore.source(for: image))
        s.develop = DevelopSettings(stock: "generic", tone: tone, autoBalance: true, base: BaseSettings(mode: .anchor))
        return s
    }

    // MARK: the panel

    /// The title is the button, drawn as `FoldTitle` draws a section title: plain, with the
    /// section chevron only while closed, the hover help and accessibility label from the
    /// row, and the Adjust word's id. It holds no info icon of its own.
    func testTheTitleIsAPlainFoldButton() throws {
        let raw = try repoSource("Sources/FilmPositive/UI/Inspector/DevelopRowTitle.swift")
        XCTAssertTrue(raw.contains("struct DevelopRowTitle"), "read the wrong file")
        let start = try XCTUnwrap(raw.range(of: "struct DevelopRowTitle: View {")).lowerBound
        let end = try XCTUnwrap(raw.range(of: "struct DevelopSliderGroup")).lowerBound
        let view = String(raw[start..<end])
        XCTAssertTrue(view.contains("Button(action: action)"))
        XCTAssertTrue(view.contains("Label(row.title, systemImage: row.symbol)"))
        XCTAssertTrue(view.contains("if !open {\n                    Image(systemName: SectionFold.chevron)"),
                      "the section chevron, beside a closed title only")
        XCTAssertTrue(view.contains(".buttonStyle(.plain)"))
        XCTAssertTrue(view.contains(".help(row.help(open: open))"))
        XCTAssertTrue(view.contains(".accessibilityLabel(row.accessibilityLabel(open: open))"))
        XCTAssertTrue(view.contains(".accessibilityIdentifier(row.identifier)"))
        XCTAssertTrue(view.contains("lit ? AnyShapeStyle(Color.accentColor)"), "lit in the accent")
        for other in ["InfoGlyph(", "BaseInfoButton(", ".popover("] {
            XCTAssertFalse(view.contains(other), "the title holds \(other), so one click would do both")
        }
    }

    /// Each row draws its title and its info icon as two SEPARATE buttons, side by side, so a
    /// click on the icon opens its popover and never folds, and a click on the title folds
    /// and never opens the popover. Base is disabled on black and white, Tone never is.
    func testTheTitleAndTheInfoIconAreSeparateButtons() throws {
        let s = try inspector()
        let pairs: [(DevelopRow, String)] = [
            (.base, "BaseInfoButton(source: BaseInfo.selection(baseInfoSources)"),
            (.tone, "ToneInfoButton(thin: ToneThin.status(stretchReadings))"),
        ]
        for (row, infoCall) in pairs {
            let title = try XCTUnwrap(s.range(of: "DevelopRowTitle(row: .\(row.rawValue), open: DevelopRow.\(row.rawValue).isOpen(model.prefs),"),
                                      "\(row) title")
            XCTAssertEqual(s.components(separatedBy: "DevelopRowTitle(row: .\(row.rawValue),").count - 1, 1,
                           "one \(row) title")
            let info = try XCTUnwrap(s.range(of: infoCall, range: title.upperBound..<s.endIndex), "\(row) info")
            let between = String(s[title.lowerBound..<info.lowerBound])
            // The title call closes, with its action, before the icon begins: the icon is a
            // sibling in the label group, never inside the title's button.
            let action = "{ model.toggleDevelopRow(.\(row.rawValue)) }"
            XCTAssertTrue(between.contains("lit: DevelopRow.\(row.rawValue).lit(summary)) \(action)"), between)
            XCTAssertEqual(between.components(separatedBy: "{").count, 2, "only the action's brace: \(between)")
            XCTAssertEqual(between.contains(".disabled(monoSelection)"), row != .tone,
                           "\(row): disabled on black and white for Base only")
            XCTAssertFalse(between.contains("onTapGesture"), "no second gesture on the title")
        }
    }
}
