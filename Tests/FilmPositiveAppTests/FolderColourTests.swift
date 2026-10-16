import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// A folder's color label is its Finder color tag, and setting one keeps every other tag
/// the folder has.
///
/// The merge is a pure function and most of this pins it. The last three tests go through a
/// real folder on disk, because the claim that matters is that Finder sees what the sidebar
/// wrote, and a merge that is right in memory says nothing about the write.
final class FolderColourTests: XCTestCase {

    // MARK: the merge

    func testTheSevenFinderColourNamesAreTheCases() {
        XCTAssertEqual(FolderColour.allCases.map(\.tagName),
                       ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
    }

    func testAColourIsAddedToAFolderWithNoTags() {
        XCTAssertEqual(FolderColour.tags([], setting: .red), ["Red"])
    }

    func testAColourIsAppendedAfterTagsThatAreNotColours() {
        XCTAssertEqual(FolderColour.tags(["Portra", "Scanned"], setting: .blue),
                       ["Portra", "Scanned", "Blue"])
    }

    func testAnExistingColourIsReplacedWhereItStandsAndTheOtherTagsKeepTheirOrder() {
        XCTAssertEqual(FolderColour.tags(["Portra", "Red", "Scanned"], setting: .green),
                       ["Portra", "Green", "Scanned"])
    }

    func testSeveralColoursCollapseToTheOneChosen() {
        XCTAssertEqual(FolderColour.tags(["Red", "Portra", "Blue", "Yellow"], setting: .purple),
                       ["Purple", "Portra"])
    }

    func testNoneRemovesEveryColourAndNothingElse() {
        XCTAssertEqual(FolderColour.tags(["Red", "Portra", "Blue"], setting: nil), ["Portra"])
        XCTAssertEqual(FolderColour.tags(["Portra"], setting: nil), ["Portra"])
        XCTAssertEqual(FolderColour.tags([], setting: nil), [])
    }

    func testFinderIgnoresCaseInTagNamesAndSoDoesTheMatch() {
        XCTAssertEqual(FolderColour(tag: "gray"), .gray)
        XCTAssertEqual(FolderColour.tags(["red", "Portra"], setting: .orange), ["Orange", "Portra"])
    }

    func testATagThatOnlyContainsAColourNameIsNotAColour() {
        XCTAssertNil(FolderColour(tag: "Redscale"))
        XCTAssertNil(FolderColour(tag: "Blue hour"))
        XCTAssertEqual(FolderColour.tags(["Redscale"], setting: .red), ["Redscale", "Red"])
    }

    func testTheColourReadIsTheFirstColourTag() {
        XCTAssertEqual(FolderColour.colour(in: ["Portra", "Blue", "Red"]), .blue)
        XCTAssertNil(FolderColour.colour(in: ["Portra"]))
        XCTAssertNil(FolderColour.colour(in: []))
    }

    func testSettingTheSameColourTwiceChangesNothing() {
        let once = FolderColour.tags(["Portra"], setting: .yellow)
        XCTAssertEqual(FolderColour.tags(once, setting: .yellow), once)
    }

    // MARK: a real folder

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-folder-colour-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func setTags(_ tags: [String], on url: URL) throws {
        try (url as NSURL).setResourceValue(tags as NSArray, forKey: .tagNamesKey)
    }

    func testAColourWrittenToARealFolderReadsBackAndKeepsItsOtherTags() throws {
        try setTags(["Portra", "Red"], on: scratch)
        XCTAssertEqual(FolderColour.read(scratch), .red)

        XCTAssertEqual(try FolderColour.write(.green, to: scratch), .green)
        XCTAssertEqual(FolderColour.readTags(scratch), ["Portra", "Green"])

        XCTAssertNil(try FolderColour.write(nil, to: scratch))
        XCTAssertEqual(FolderColour.readTags(scratch), ["Portra"])
    }

    /// The read has to see a change made behind the app's back, which is Finder's case. The
    /// stored URL caches resource values, so this is what a cached read would get wrong.
    func testAChangeMadeElsewhereIsSeenOnTheNextRead() throws {
        let stored = scratch!
        XCTAssertNil(FolderColour.read(stored))
        try setTags(["Blue"], on: URL(fileURLWithPath: stored.path))
        XCTAssertEqual(FolderColour.read(stored), .blue)
    }

    /// The row carries the color in the mark the enum selects, and only there. The default
    /// is the icon.
    func testTheRowCarriesTheColourInTheSelectedMark() {
        XCTAssertEqual(FolderRow.colourMark, .icon)

        let icon = FolderRow.look(.red, .icon)
        XCTAssertEqual(icon.iconColour, .red)
        XCTAssertEqual(icon.symbol, "folder.fill")
        XCTAssertNil(icon.leadingDot)
        XCTAssertNil(icon.trailingDot)
        XCTAssertFalse(icon.reservesLeadingSlot)

        let leading = FolderRow.look(.green, .leadingDot)
        XCTAssertEqual(leading.leadingDot, .green)
        XCTAssertNil(leading.iconColour)
        XCTAssertNil(leading.trailingDot)
        XCTAssertEqual(leading.symbol, "folder")

        let trailing = FolderRow.look(.blue, .trailingDot)
        XCTAssertEqual(trailing.trailingDot, .blue)
        XCTAssertNil(trailing.iconColour)
        XCTAssertNil(trailing.leadingDot)

        // Untagged: the plain outline in the sidebar's tint under every mark, and the leading
        // dot mode still holds the dot's slot so the icons line up.
        for mark in FolderRow.ColourMark.allCases {
            let plain = FolderRow.look(nil, mark)
            XCTAssertEqual(plain.symbol, "folder")
            XCTAssertNil(plain.iconColour)
            XCTAssertNil(plain.leadingDot)
            XCTAssertNil(plain.trailingDot)
            XCTAssertEqual(plain.reservesLeadingSlot, mark == .leadingDot)
        }
    }

    @MainActor
    func testTheModelReadsColoursOnAddAndWritesThemThroughTheMenu() throws {
        Preferences.store = InMemoryPreferences()
        defer { Preferences.store = InMemoryPreferences() }
        let roll = scratch.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        try setTags(["Keep", "Purple"], on: roll)

        let model = AppModel(service: FailingRenderService(message: "no engine in tests"))
        let session = try XCTUnwrap(model.addFolder(roll))
        XCTAssertEqual(model.folderColours[session.id], .purple)

        model.setFolderColour(.orange, for: session.id)
        XCTAssertEqual(model.folderColours[session.id], .orange)
        XCTAssertEqual(FolderColour.readTags(roll), ["Keep", "Orange"])

        model.setFolderColour(nil, for: session.id)
        XCTAssertNil(model.folderColours[session.id])
        XCTAssertEqual(FolderColour.readTags(roll), ["Keep"])
        XCTAssertNil(model.notice)
    }
}
