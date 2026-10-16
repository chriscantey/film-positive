import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The shipped stock tiers, and the absence of any light or camera list.
final class LightsAndStocksTests: XCTestCase {

    private func library() throws -> ProfileLibrary { try ProfileLibrary.bundled() }

    /// No light or camera list ships, so the rule is kept as the folders' absence.
    func testNoLightOrCameraProfilesShip() throws {
        let root = try library().root
        for folder in ["scanners", "cameras"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(folder).path),
                           "\(folder)/ ships again")
        }
    }

    /// A stock develops with no calibration step.
    @MainActor
    func testAStockDevelopsWithNoCalibration() throws {
        let profiles = try library()
        let develop = profiles.initialDevelop(capture: nil)
        let gamma = profiles.resolveFilm(develop.stock).dyeGamma
        XCTAssertTrue([gamma.r, gamma.g, gamma.b].allSatisfy { $0.isFinite && $0 > 0 })
    }

    /// Slide film is out of scope for v1, so nothing in the picker is a positive film. A
    /// profile does not carry its process, so this is asserted by name, and
    /// `ProfilePackage` still refuses an imported file that declares E-6.
    @MainActor
    func testNoPositiveFilmIsOffered() throws {
        let library = try self.library()
        for p in library.films.values {
            XCTAssertFalse(p.name.lowercased().contains("ektachrome"), "\(p.id) is a slide film")
            XCTAssertFalse(p.name.lowercased().contains("velvia"), "\(p.id) is a slide film")
            XCTAssertFalse(p.name.lowercased().contains("provia"), "\(p.id) is a slide film")
        }
        for choice in StockChoices.list(from: library, current: nil) {
            XCTAssertNotEqual(choice.name.lowercased(), "slide")
            XCTAssertFalse(choice.name.lowercased().contains("slide"), "\(choice.id)")
        }
    }

    /// Nothing in the app writes a film profile. Import copies a file as it arrived. A writer
    /// appearing anywhere in the app is what this catches, in the tree rather than in a review.
    @MainActor
    func testNoCodeWritesAProfile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var offenders: [String] = []
        let keys = ["effectiveDyeGamma", "baseRatios", "measuredBase"]
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                let writes = text.contains("JSONEncoder") || text.contains(".write(to:")
                guard writes else { continue }
                for key in keys where text.contains(key) {
                    offenders.append("\(url.lastPathComponent) encodes \(key)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "a profile writer exists in the app")
    }

    /// The settings list labels every entry for what it is, and there are exactly two
    /// shipped tiers. "Fitted" is not one of them: that tier means a number measured off
    /// somebody's roll, and no shipped profile may carry one.
    @MainActor
    func testTheStockListLabelsEveryTier() throws {
        let library = try self.library()
        // the generic entry is not a profile file, it is the literal sidecar value
        XCTAssertEqual(StockChoices.genericID, "generic")
        let choices = StockChoices.list(from: library, current: nil)
        XCTAssertEqual(choices.first?.kind, .generic)
        XCTAssertTrue(choices.contains { $0.kind == .mono })
        XCTAssertTrue(choices.contains { $0.kind == .curve(measured: false) })
    }
}
