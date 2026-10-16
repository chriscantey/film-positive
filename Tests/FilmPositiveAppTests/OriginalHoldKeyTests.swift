import XCTest
import AppKit
import SwiftUI
@testable import FilmPositive

/// Hold M reached through a slider that holds focus. The monitor's reading of an
/// event is pure, so which events it takes and which it leaves is asserted here.
final class OriginalHoldKeyTests: XCTestCase {
    private func phase(_ type: NSEvent.EventType, repeat r: Bool = false, _ chars: String = "m",
                       _ mods: NSEvent.ModifierFlags = [], text: Bool = false) -> KeyPress.Phases? {
        OriginalHoldKey.phase(type: type, isRepeat: r, characters: chars, modifiers: mods, textFieldHasFocus: text)
    }

    func testABareMIsTakenInAllThreePhases() {
        XCTAssertEqual(phase(.keyDown), .down)
        XCTAssertEqual(phase(.keyDown, repeat: true), .repeat)
        XCTAssertEqual(phase(.keyUp), .up)
        XCTAssertEqual(phase(.keyDown, "M"), .down, "caps lock is still M")
        XCTAssertEqual(phase(.keyDown, "m", .shift), .down)
    }

    func testATextFieldKeepsItsLetter() {
        XCTAssertNil(phase(.keyDown, text: true))
        XCTAssertNil(phase(.keyUp, text: true))
    }

    func testMenuChordsAndOtherKeysPassThrough() {
        XCTAssertNil(phase(.keyDown, "m", .command), "Command M is Minimize")
        XCTAssertNil(phase(.keyDown, "m", .option))
        XCTAssertNil(phase(.keyDown, "m", .control))
        XCTAssertNil(phase(.keyDown, "n"))
        XCTAssertNil(phase(.flagsChanged))
    }

    /// Both surfaces use the monitor and neither still relies on focus for M.
    func testBothSurfacesCatchMAboveTheFocusChain() throws {
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FilmPositive/UI")
        for file in ["Viewer/ViewerView.swift", "Grid/GridView.swift"] {
            let s = try String(contentsOf: ui.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(s.contains("holdKey.install"), file)
            XCTAssertTrue(s.contains("holdKey.remove()"), "\(file) removes its monitor when it goes")
            XCTAssertFalse(s.contains(#"onKeyPress(keys: ["m"]"#), "\(file) still reads M through focus")
        }
    }
}
