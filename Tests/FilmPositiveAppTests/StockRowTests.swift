import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// SwiftUI's "Invalid Configuration: the selection is invalid and does not have an
/// associated tag" fault, in the Film Stock row.
///
/// It appears when the binding's getter answers `mixedTag` for any ABSENT stock while the
/// Multiple row is inserted only while the frames DISAGREE. Absent and disagreeing are not
/// the same state (`SharedValue` returns nil from `.empty` too), so a selection with no shared
/// stock and no disagreement points at a row that is not there and the popup draws blank.
///
/// The invariant asserted here: every tag `stockPickerTag` can produce names an item the picker is rendering.
final class StockRowTests: XCTestCase {

    /// The rendered rows, built exactly as `InspectorView.stockChoices` builds them, so
    /// the two cannot drift. Kept in the test rather than reached for in the view because
    /// the view's copy needs a window and a model.
    private func rendered(_ profiles: ProfileLibrary?, tag: String) -> [StockChoice] {
        if tag == SelectionSummary.mixedTag {
            var list = StockChoices.list(from: profiles, current: nil)
            list.insert(StockChoice(id: SelectionSummary.mixedTag, name: "Multiple", kind: .unprofiled), at: 0)
            return list
        }
        return StockChoices.list(from: profiles, current: tag)
    }

    func testNoStockRecordedShowsTheGenericChoiceRatherThanBlank() {
        XCTAssertEqual(InspectorView.stockPickerTag(for: nil, isMultiple: false), StockChoices.genericID)
        XCTAssertNotEqual(InspectorView.stockPickerTag(for: nil, isMultiple: false),
                          SelectionSummary.mixedTag)
    }

    func testDisagreeingFramesShowTheMultipleItem() {
        XCTAssertEqual(InspectorView.stockPickerTag(for: nil, isMultiple: true), SelectionSummary.mixedTag)
        // Multiple wins even when a value survived, because the row the picker renders is
        // keyed on isMultiple and nothing else.
        XCTAssertEqual(InspectorView.stockPickerTag(for: "kodak-gold-200", isMultiple: true),
                       SelectionSummary.mixedTag)
    }

    func testAStockThatIsRecordedIsShownAsItself() {
        XCTAssertEqual(InspectorView.stockPickerTag(for: "kodak-gold-200", isMultiple: false),
                       "kodak-gold-200")
        XCTAssertEqual(InspectorView.stockPickerTag(for: "a-stock-with-no-profile", isMultiple: false),
                       "a-stock-with-no-profile")
    }

    /// The fault itself, stated as the invariant it broke. Every state a selection can be
    /// in, against the real shipped library, including the absent-value case.
    func testEveryProducibleTagNamesARenderedRow() throws {
        let profiles = try ProfileLibrary.bundled()
        let stored: [String?] = [nil, StockChoices.genericID, ProfileLibrary.monoStockID,
                                 "kodak-gold-200", "a-stock-from-another-machine"]
        for value in stored {
            for isMultiple in [false, true] {
                let tag = InspectorView.stockPickerTag(for: value, isMultiple: isMultiple)
                let rows = rendered(profiles, tag: tag)
                XCTAssertTrue(rows.contains { $0.id == tag },
                              "no row carries \(tag) for value \(value ?? "nil") multiple=\(isMultiple)")
            }
        }
    }

    /// The same sweep with no bundle at all, because the list is built differently there
    /// (two guaranteed ids) and an absent stock still has to land on a rendered row.
    func testEveryProducibleTagNamesARenderedRowWithoutTheBundle() {
        for value in [nil, StockChoices.genericID, "kodak-portra-400"] as [String?] {
            let tag = InspectorView.stockPickerTag(for: value, isMultiple: false)
            XCTAssertTrue(rendered(nil, tag: tag).contains { $0.id == tag },
                          "no row carries \(tag) without a profile bundle")
        }
    }

    /// Multiple can be shown and can never be written, so it must not be a stock id.
    func testTheMultipleTagCannotBeARealStock() throws {
        let profiles = try ProfileLibrary.bundled()
        XCTAssertFalse(StockChoices.list(from: profiles, current: nil)
            .contains { $0.id == SelectionSummary.mixedTag })
    }
}
