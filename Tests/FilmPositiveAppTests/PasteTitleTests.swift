import XCTest
import AppKit
@testable import FilmPositive

/// The paste item names only the sections that were copied, and Command V pastes them.
final class PasteTitleTests: XCTestCase {

    private func title(_ sections: [FrameSettingsSection]) -> String {
        FrameSettingsPayload(sections: sections).pasteMenuTitle
    }

    func testTheTitleNamesWhatWasCopied() {
        XCTAssertEqual(title([.enhance]), "Paste Settings (Enhance)")
        XCTAssertEqual(title([.crop]), "Paste Settings (Crop)")
        XCTAssertEqual(title([.positive]), "Paste Settings (Develop)")
        XCTAssertEqual(title([.enhance, .crop]), "Paste Settings (Enhance and Crop)")
        XCTAssertEqual(title([.crop, .positive]), "Paste Settings (Develop and Crop)", "menu order, not copy order")
        XCTAssertEqual(title([.positive, .enhance, .crop]), "Paste Settings")
    }

    func testTheLiveTitleReadsThePasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("fp-test-\(UUID().uuidString)"))
        FrameSettingsPasteboard.write(FrameSettingsPayload(sections: [.enhance]), to: pasteboard)
        XCTAssertEqual(FrameSettingsPasteboard.pasteMenuTitle(in: pasteboard), "Paste Settings (Enhance)")
        pasteboard.releaseGlobally()
    }

    func testCommandVPastesSettingsOnlyOffATextField() {
        typealias A = FilmPositiveApp
        XCTAssertEqual(A.pasteRoute(textFieldHasFocus: false, framesSelected: true, settingsCopied: true), .settings)
        XCTAssertEqual(A.pasteRoute(textFieldHasFocus: true, framesSelected: true, settingsCopied: true), .text,
                       "a text field keeps its paste")
        XCTAssertEqual(A.pasteRoute(textFieldHasFocus: false, framesSelected: false, settingsCopied: true), .text)
        XCTAssertEqual(A.pasteRoute(textFieldHasFocus: false, framesSelected: true, settingsCopied: false), .text,
                       "nothing copied, nothing to paste onto frames")
    }
}
