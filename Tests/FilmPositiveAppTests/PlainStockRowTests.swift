import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Stock is a choice of film and nothing else. Its row is a title, an info icon and the
/// picker, with no fold and no sliders under it, for a color frame and for a black and white
/// one. The pair that trims a stock's red and blue contrast is a profile-building function:
/// the kernel keeps it (`HighlightAxesCoreTests`), and a frame's sidecar no longer reaches it.
/// A file that carries a stored value renders as the same file without it and loses the
/// attribute the next time it is written.
final class PlainStockRowTests: XCTestCase {

    private var scratch: URL!
    private let stored = ColourAxes(warm: 6, green: -3)

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-stock-\(UUID().uuidString)")
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

    /// The Stock row's block in the inspector, from its gate to the Base title.
    private func stockRow() throws -> String {
        let s = try inspector()
        let start = try XCTUnwrap(s.range(of: "if rows.contains(.stock) {"), "the Stock row's gate")
        let end = try XCTUnwrap(s.range(of: "DevelopRowTitle(row: .base,", range: start.upperBound..<s.endIndex),
                                "the Base title after it")
        return String(s[start.lowerBound..<end.lowerBound])
    }

    // MARK: the plain row

    /// The Stock row offers no fold and no rows, for color and for black and white: its title
    /// is a plain label beside the info icon and the picker, nothing under it is a slider, and
    /// no Develop fold, preference or accessibility id names Stock.
    func testTheStockRowOffersNoFoldAndNoRowsForColorAndForBlackAndWhite() throws {
        let row = try stockRow()
        XCTAssertTrue(row.contains("Label(StockChoices.rowTitle, systemImage: StockChoices.rowSymbol)"),
                      "the title is a plain label: \(row)")
        XCTAssertTrue(row.contains(#"InfoGlyph(text: StockChoices.infoHover, identifier: "positive.stockInfo","#),
                      "the info icon stays")
        XCTAssertTrue(row.contains("stockPicker.fixedSize()"), "the picker stays")
        for absent in ["DevelopRowTitle(", "DevelopSliderGroup(", "ColourAxisRow(", "Button(", ".lit(",
                       "toggleDevelopRow", "SectionFold.chevron", "stock.adjust", ".disabled(monoSelection)"] {
            XCTAssertFalse(row.contains(absent), "the Stock row carries \(absent)")
        }
        XCTAssertEqual(StockChoices.rowTitle, "Stock")
        XCTAssertEqual(StockChoices.rowSymbol, "film")
        XCTAssertNotNil(NSImage(systemSymbolName: StockChoices.rowSymbol, accessibilityDescription: nil))

        // No fold: Stock is not a Develop row, and no fold the inspector draws is a Stock one.
        XCTAssertNil(DevelopRow(rawValue: "stock"))
        XCTAssertFalse(DevelopRow.allCases.map(\.title).contains("Stock"))
        XCTAssertEqual(DevelopRow.allCases, [.base, .tone])

        // No rows: for every Auto color state, color and black and white, open fold or not,
        // the row after Stock is Auto color.
        for mono in [false, true] {
            for open in [false, true] {
                for state in [SharedValue<Bool?>.uniform(true), .uniform(false), .multiple, .uniform(nil), .empty] {
                    let rows = PositiveRows.visibleRows(autoColor: state, mono: mono, axesOpen: open)
                    XCTAssertEqual(Array(rows.prefix(2)), [.stock, .autoColor], "mono \(mono), open \(open)")
                }
            }
        }

        // No remembered fold: the preferences carry no key for one, and a blob an earlier
        // build saved with that key still decodes and keeps the folds that remain.
        let encoded = String(decoding: try JSONEncoder().encode(Preferences()), as: UTF8.self)
        XCTAssertFalse(encoded.contains("highlightAxesOpen"), encoded)
        var blob = try XCTUnwrap(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(Preferences()))
                                 as? [String: Any])
        blob["highlightAxesOpen"] = true
        blob["colourAxesOpen"] = true
        let decoded = try JSONDecoder().decode(Preferences.self, from: try JSONSerialization.data(withJSONObject: blob))
        XCTAssertTrue(decoded.showsColourAxes, "the Base fold survives")
        XCTAssertFalse(decoded.showsToneAdjust)
    }

    /// The Stock row's info icon: the hover names the generic stock by its display name, from
    /// the one constant, and the popover keeps the point that most film can stay on it and
    /// says nothing about tuning the stock.
    func testTheStockInfoIconNamesTheGenericStock() throws {
        XCTAssertTrue(StockChoices.infoHover.hasPrefix(StockChoices.genericName + " "),
                      "the hover must name the generic stock as the picker shows it")
        XCTAssertEqual(StockChoices.infoHover,
                       "Color Negative suits most film, because Base removes the film's own color.")
        XCTAssertEqual(StockChoices.infoPopover,
                       "Pick your film when it is listed to use its own curves. Otherwise leave it on Color Negative, and Base takes care of the rest.")
        for text in [StockChoices.infoHover, StockChoices.infoPopover] {
            for word in ["Adjust", "Click Stock", "highlights", "tune", "slider", "\u{2014}", ";"] {
                XCTAssertFalse(text.contains(word), "\(word) in \(text)")
            }
        }
        let s = try inspector()
        let title = try XCTUnwrap(s.range(of: "Label(StockChoices.rowTitle,"))
        let info = try XCTUnwrap(s.range(of: #"InfoGlyph(text: StockChoices.infoHover, identifier: "positive.stockInfo","#))
        let picker = try XCTUnwrap(s.range(of: "stockPicker.fixedSize()"))
        XCTAssertLessThan(title.lowerBound, info.lowerBound)
        XCTAssertLessThan(info.lowerBound, picker.lowerBound)
        XCTAssertTrue(String(s[info.lowerBound...].prefix(200)).contains("popover: StockChoices.infoPopover"))
    }

    // MARK: nothing writes one

    /// No shipped profile seeds a value, and no edit verb moves one a sidecar already holds.
    func testNothingAutomaticWritesTheHighlightAxes() throws {
        let profiles = try ProfileLibrary.bundled()
        XCTAssertGreaterThan(profiles.films.count, 1, "no profiles loaded, so this asserts nothing")
        for film in profiles.films.values {
            let d = profiles.initialDevelop(capture: CaptureInfo(film: film.name, filmMaker: nil))
            XCTAssertEqual(d.stock, ProfileLibrary.genericStockName, "\(film.id) picked by name")
            XCTAssertTrue(d.highlightAxes.isIdentity, "\(film.id) seeded a value")
        }
        XCTAssertTrue(profiles.initialDevelop(capture: nil).highlightAxes.isIdentity)

        let image = scratch.appendingPathComponent("IMG_0001.CR2")
        try Data(repeating: 0x42, count: 2048).write(to: image)
        var s = Sidecar(source: try SidecarStore.source(for: image))
        s.develop = developed(stored)
        let after: [(String, Sidecar)] = [
            ("setBase", SidecarEdits.setBase(s, BaseSettings(mode: .measured, measured: [1, 2, 3]))),
            ("setColourAxes", SidecarEdits.setColourAxes(s, ColourAxes(warm: 3))),
            ("setEnhance", SidecarEdits.setEnhance(s, EnhanceSettings.identity)),
            ("setGeometry", SidecarEdits.setGeometry(s, GeometrySettings(rotate: 90))),
            ("resetEnhance", SidecarEdits.resetEnhance(s)),
            ("applyLook", SidecarEdits.applyLook(s, ShippedLooks.all[0])),
        ]
        for (name, out) in after {
            XCTAssertEqual(out.develop?.highlightAxes, stored, "\(name) moved the value")
        }
    }

    /// The only assignment of the field in the sources is the one place a stored value is
    /// dropped, `Sidecar.withLiveFields`, and it assigns the identity. No edit, paste or
    /// render path assigns it.
    func testTheFieldHasNoOtherWriterInTheSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var writers: [String] = []
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: "\n")
            where line.contains(".highlightAxes = ") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                writers.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertGreaterThan(writers.count, 0, "the search found nothing, so it searched nothing")
        XCTAssertEqual(writers.sorted(), ["LiveSidecar.swift: d.highlightAxes = .identity"])
    }

    // MARK: a stored value

    private func developed(_ axes: ColourAxes) -> DevelopSettings {
        var d = DevelopSettings(stock: "kodak-gold-200", tone: .none, autoBalance: false,
                                base: BaseSettings(mode: .anchor))
        d.colourAxes = ColourAxes(warm: 2, green: 1)
        d.highlightAxes = axes
        return d
    }

    /// The app's renderer gives the same pixels for a develop layer carrying a stored value
    /// as for the same layer without it, while the kernel itself still moves with the same
    /// value, so the comparison can fail.
    func testAStoredValueRendersByteForByteAsWithoutIt() async throws {
        let f = SceneFixtures.neutralScene(castRG: 1.15, castBG: 0.92)
        let url = URL(fileURLWithPath: "/dev/null/synthetic.CR2")
        func render(_ d: DevelopSettings) async throws -> [UInt16] {
            let svc = CPURenderService(profiles: try ProfileLibrary.bundled(), enhance: IdentityEnhance(),
                                       decode: { _, _ in f })
            return try await svc.render(RenderRequest(imageURL: url, develop: d, enhance: .identity,
                                                      scale: .full)).frame.pixels
        }
        let with = try await render(developed(stored))
        let without = try await render(developed(.identity))
        XCTAssertEqual(with, without, "a stored value moves nothing on screen")

        let svc = CPURenderService(profiles: try ProfileLibrary.bundled())
        XCTAssertEqual(svc.developInput(for: developed(stored)).highlightAxes, .identity,
                       "the sidecar's value does not reach the kernel")
        var driven = svc.developInput(for: developed(.identity))
        let rest = DevelopMath.analyze(f, input: driven).0.physics
        driven.highlightAxes = stored
        XCTAssertNotEqual(DevelopMath.analyze(f, input: driven).0.physics, rest,
                          "the kernel still moves the ceilings when a caller sets the value")
    }

    /// A file with a stored value: opening the folder rewrites nothing and reads it as
    /// identity, and the next write for any other reason drops the attribute, giving the
    /// bytes the same frame writes without it.
    @MainActor
    func testAStoredValueReadsAsIdentityAndGoesAtTheNextWrite() throws {
        let roll = scratch.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        let image = roll.appendingPathComponent("IMG_0001.CR2")
        try Data(repeating: 0x42, count: 64).write(to: image)
        var carrying = Sidecar(source: try SidecarStore.source(for: image))
        carrying.develop = developed(stored)
        let xmp = try carrying.encoded()
        XCTAssertTrue(String(decoding: xmp, as: UTF8.self).contains("HighlightAxes"), "the fixture carries the attribute")
        let sidecarURL = SidecarStore.sidecarURL(for: image)
        try xmp.write(to: sidecarURL)

        // Open: the folder reads the value as identity and writes nothing.
        let model = AppModel(service: CPURenderService(profiles: try ProfileLibrary.bundled()))
        model.undoManager.groupsByEvent = false
        XCTAssertNotNil(model.addFolder(roll))
        let frame = try XCTUnwrap(model.selectedFolder?.frames.first)
        XCTAssertEqual(frame.sidecar.develop?.highlightAxes, .identity, "read as identity")
        XCTAssertEqual(frame.sidecar.develop?.colourAxes, ColourAxes(warm: 2, green: 1), "the Base pair is kept")
        XCTAssertEqual(try Data(contentsOf: sidecarURL), xmp, "opening the folder rewrites nothing")

        // Write: a Base edit's save drops the attribute.
        var edited = carrying
        edited.develop?.colourAxes = ColourAxes(warm: 3, green: 1)
        try model.writeSidecar(edited, for: image)
        let written = try Data(contentsOf: sidecarURL)
        XCTAssertFalse(String(decoding: written, as: UTF8.self).contains("HighlightAxes"), "the attribute is gone")
        XCTAssertEqual(try XCTUnwrap(SidecarStore().load(for: image)).sidecar.develop?.highlightAxes, .identity)

        // And those bytes are the bytes the same edit writes on the same file that never had
        // it: put back the opened file without the attribute, make the same edit, compare.
        var never = carrying
        never.develop?.highlightAxes = .identity
        let neverXMP = try never.encoded()
        XCTAssertFalse(String(decoding: neverXMP, as: UTF8.self).contains("HighlightAxes"))
        try neverXMP.write(to: sidecarURL)
        var plain = edited
        plain.develop?.highlightAxes = .identity
        try model.writeSidecar(plain, for: image)
        XCTAssertEqual(try Data(contentsOf: sidecarURL), written, "byte for byte")
    }

    /// A file with no stored value reads and writes byte for byte as the store alone reads
    /// and writes it: the frame holds exactly the sidecar on disk, and the app's write gives
    /// the bytes the store's own save gives.
    @MainActor
    func testASidecarWithoutAStoredValueReadsAndWritesByteForByte() throws {
        let roll = scratch.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        let image = roll.appendingPathComponent("IMG_0001.CR2")
        try Data(repeating: 0x42, count: 64).write(to: image)
        var plain = Sidecar(source: try SidecarStore.source(for: image))
        plain.develop = developed(.identity)
        // Every Enhance value the app keeps, set, so the write covers the whole layer.
        var e = EnhanceSettings()
        for (i, c) in EnhanceControl.all.enumerated() { e[keyPath: c.path] = 0.05 + 0.01 * Double(i) }
        e.levels = Levels(inBlack: 0.05, gamma: 1.2, inWhite: 0.95, outBlack: 0.02, outWhite: 0.98)
        e.curves.rgb = CurvePoints(sanitising: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)])
        plain.enhance = e
        try SidecarStore().save(plain, for: image)
        let sidecarURL = SidecarStore.sidecarURL(for: image)
        let bytes = try Data(contentsOf: sidecarURL)

        XCTAssertEqual(plain.withLiveFields, plain, "nothing to drop")
        let frame = try XCTUnwrap(try FolderSession.scan(roll).first)
        let loaded = try XCTUnwrap(SidecarStore().load(for: image)).sidecar
        XCTAssertEqual(frame.sidecar, loaded, "the frame holds the file as it reads")
        XCTAssertEqual(try Data(contentsOf: sidecarURL), bytes, "reading rewrites nothing")

        // A fresh write through the app's path gives the store's own bytes.
        try FileManager.default.removeItem(at: sidecarURL)
        let model = AppModel(service: CPURenderService(profiles: try ProfileLibrary.bundled()))
        try model.writeSidecar(frame.sidecar, for: image)
        XCTAssertEqual(try Data(contentsOf: sidecarURL), bytes, "written byte for byte")
    }
}
