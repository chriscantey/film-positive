import XCTest
@testable import FilmPositive

/// What a Finder drop adds to the Folders panel.
final class DroppedFoldersTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fp-drop-\(UUID().uuidString)", isDirectory: true)
        for name in ["RollA", "RollB", "Empty"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in ["1.CR2", "2.CR2", "3.CR2"] {
            try Data([0]).write(to: root.appendingPathComponent("RollA/\(name)"))
        }
        try Data([0]).write(to: root.appendingPathComponent("RollB/1.CR2"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func paths(_ urls: [URL]) -> [String] { urls.map { $0.standardizedFileURL.path } }
    private func path(_ name: String) -> String { root.appendingPathComponent(name).standardizedFileURL.path }

    func testADroppedFolderIsItself() {
        XCTAssertEqual(paths(DroppedFolders.folders(from: [root.appendingPathComponent("RollA")])), [path("RollA")])
    }

    func testADroppedFileAddsTheFolderItIsIn() {
        XCTAssertEqual(paths(DroppedFolders.folders(from: [root.appendingPathComponent("RollB/1.CR2")])), [path("RollB")])
    }

    func testManyFilesFromOneFolderAddItOnce() {
        let files = ["1.CR2", "2.CR2", "3.CR2"].map { root.appendingPathComponent("RollA/\($0)") }
        XCTAssertEqual(paths(DroppedFolders.folders(from: files)), [path("RollA")])
    }

    func testSeveralFoldersAddEachInOrder() {
        let dropped = [root.appendingPathComponent("RollB"), root.appendingPathComponent("RollA"),
                       root.appendingPathComponent("RollA/2.CR2"), root.appendingPathComponent("Empty")]
        XCTAssertEqual(paths(DroppedFolders.folders(from: dropped)), [path("RollB"), path("RollA"), path("Empty")])
    }

    func testATrailingSlashIsTheSameFolder() {
        let plain = URL(fileURLWithPath: path("RollA"))
        let slashed = URL(fileURLWithPath: path("RollA") + "/", isDirectory: true)
        XCTAssertEqual(DroppedFolders.folders(from: [plain, slashed]).count, 1)
    }

    func testNonFileURLsAreIgnored() {
        XCTAssertTrue(DroppedFolders.folders(from: [URL(string: "https://example.com/roll")!]).isEmpty)
    }
}

/// Returning from the closeup keeps the gallery's place, and moves only when the frame the
/// user arrowed to is out of view.
final class GalleryReturnTests: XCTestCase {
    func testTheSameFrameInViewDoesNotScroll() {
        XCTAssertFalse(GalleryReturn.needsScroll(cursor: 13, top: 12, columns: 4, visibleRows: 3))
        XCTAssertFalse(GalleryReturn.needsScroll(cursor: 23, top: 12, columns: 4, visibleRows: 3))
    }

    func testAFrameBelowOrAboveTheRowsScrolls() {
        XCTAssertTrue(GalleryReturn.needsScroll(cursor: 24, top: 12, columns: 4, visibleRows: 3))
        XCTAssertTrue(GalleryReturn.needsScroll(cursor: 11, top: 12, columns: 4, visibleRows: 3))
    }

    func testUnknownGeometryNeverScrolls() {
        XCTAssertFalse(GalleryReturn.needsScroll(cursor: 90, top: 0, columns: 0, visibleRows: 3))
        XCTAssertFalse(GalleryReturn.needsScroll(cursor: 90, top: 0, columns: 4, visibleRows: 0))
    }

    func testVisibleRowsFromMeasuredContent() {
        // 40 frames in 4 columns is 10 rows. Content 16 + 10 rows at 150 + 9 gaps of 16 + 16.
        let content: Double = 1676  // 16 + 10 rows at 150 + 9 gaps of 16 + 16
        XCTAssertEqual(GalleryReturn.visibleRows(viewport: 600, content: content, frames: 40, columns: 4,
                                                 padding: 16, spacing: 16), 3)
        XCTAssertEqual(GalleryReturn.visibleRows(viewport: 2000, content: content, frames: 40, columns: 4,
                                                 padding: 16, spacing: 16), 10)
    }
}

/// The drop box never touches the Folders heading. The heading is pinned above the list
/// instead of being its scrolling Section header, so the box covers the list alone and
/// cannot cross the heading or, in a scrolled list, a folder name.
final class DropHighlightTests: XCTestCase {
    func testTheHeadingIsPinnedAboveTheListAndTheBoxCoversOnlyTheList() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FilmPositive/UI/Sidebar/SidebarView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("Section(\"Folders\")"), "a Section header scrolls away with the rows")
        guard let heading = source.range(of: "Text(\"Folders\")"),
              let list = source.range(of: "List(selection:"),
              let box = source.range(of: ".strokeBorder(Color.accentColor") else {
            return XCTFail("sidebar shape not found")
        }
        XCTAssertTrue(heading.lowerBound < list.lowerBound, "the heading comes before the list")
        XCTAssertTrue(list.lowerBound < box.lowerBound, "the box is the list's overlay")
    }

    /// The stroke clears the rows by at least 4 pt top and bottom, because the list's
    /// edge, where rows start and scrolled rows clip, sits inside the box.
    func testTheStrokeClearsTheRowsByFourPoints() {
        let innerEdge = SidebarView.dropInset + SidebarView.dropStroke
        XCTAssertGreaterThanOrEqual(SidebarView.dropGutter - innerEdge, 4)
        // The sidebar's selection highlight starts 10 pt in from the list's side edges.
        XCTAssertGreaterThanOrEqual(10 - innerEdge, 4)
    }
}

/// The histogram's show and hide is the Histogram title's fold, and closing it keeps the
/// section from collapsing into Enhance by paying the gap by hand, not by a dummy row.
final class HistogramHeaderSwitchTests: XCTestCase {
    private func inspector() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FilmPositive/UI/Inspector/InspectorView.swift"), encoding: .utf8)
    }

    func testTheTitleFoldsAndTheSwitchIsGone() throws {
        let s = try inspector()
        guard let start = s.range(of: "private func histogramSection("),
              let header = s.range(of: "} header: {", range: start.upperBound..<s.endIndex),
              let end = s.range(of: "static let histogramOffGap", range: start.upperBound..<s.endIndex) else {
            return XCTFail("histogramSection shape not found")
        }
        let body = String(s[start.upperBound..<header.lowerBound])
        let head = String(s[header.lowerBound..<end.lowerBound])
        XCTAssertFalse(body.contains("Toggle("), "no Show Histogram row in the body")
        XCTAssertFalse(head.contains("Toggle("), "no switch in the header")
        XCTAssertTrue(body.contains("if isOpen(.histogram) {"), "the body is drawn only while open")
        XCTAssertTrue(head.contains("Self.foldHeader(.histogram, open: isOpen(.histogram))"))
        guard let fold = s.range(of: "static func foldHeader(") else { return XCTFail("no foldHeader") }
        XCTAssertTrue(s[fold.lowerBound...].prefix(600).contains(".padding(.bottom, foldedGap(open: open))"),
                      "the closed state pays its own gap")
        XCTAssertTrue(s.contains("static func foldedGap(open: Bool) -> CGFloat { open ? 0 : histogramOffGap }"))
    }
}

/// Every inspector section title goes through one explicit style, so an empty Section
/// above cannot turn the next title into plain text.
final class SectionTitleStyleTests: XCTestCase {
    func testEveryTitleGoesThroughTheOneStyle() throws {
        let s = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FilmPositive/UI/Inspector/InspectorView.swift"), encoding: .utf8)
        XCTAssertTrue(s.contains("static func sectionTitle(_ title: String) -> some View"))
        XCTAssertTrue(s.contains(".accessibilityAddTraits(.isHeader)"))
        XCTAssertFalse(s.contains("Text(\"Histogram\")"), "the Histogram title is styled like the others")
        guard let header = s.range(of: "private func sectionHeader(") else { return XCTFail("no sectionHeader") }
        XCTAssertTrue(s[header.lowerBound...].prefix(500).contains("Self.sectionTitle(title)"))
        // Histogram and Metadata go through `foldHeader`, which uses the same style.
        guard let fold = s.range(of: "static func foldHeader(") else { return XCTFail("no foldHeader") }
        XCTAssertTrue(s[fold.lowerBound...].prefix(500).contains("Self.sectionTitle(section.title)"))
        XCTAssertTrue(s.contains("Self.foldHeader(.histogram,"))
        let metadata = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FilmPositive/UI/Inspector/MetadataRows.swift"), encoding: .utf8)
        XCTAssertTrue(metadata.contains("InspectorView.foldHeader(.metadata,"))
        XCTAssertFalse(metadata.contains("sectionTitle(\"Metadata\")"), "one path for the Metadata title")
    }
}
