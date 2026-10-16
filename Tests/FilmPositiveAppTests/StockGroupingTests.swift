import XCTest
import FilmPositiveCore
@testable import FilmPositive

/// `StockChoices.grouped` and `StockChoices.prettify`, the two pure functions behind the
/// film stock picker's order and its labels: each maker's stocks sit together, and a Kodak
/// stock whose name does not start with Kodak gains it.
///
/// They are tested apart from `list` on purpose. `list` depends on the bundled profile
/// library, so a test written against it can only assert what today's bundle happens to
/// hold and it goes quiet the moment a profile ships or is withdrawn. The ordering rule and
/// the naming rule are claims about the functions themselves, so they get inputs built here
/// and they stay meaningful whatever the bundle does.
final class StockGroupingTests: XCTestCase {

    private func choice(_ id: String, _ name: String, _ kind: StockChoice.Kind) -> StockChoice {
        StockChoice(id: id, name: name, kind: kind)
    }

    /// The shape of the menu, stated as positions rather than as a literal list: generic
    /// first, unprofiled second to last, Black and White last.
    func testGenericLeadsAndMonoTrailsWithUnprofiledJustAhead() {
        let input = [
            choice("bw-generic", "Black & White", .mono),
            choice("kodak-gold-200", "Kodak Gold 200", .curve(measured: false)),
            choice("some-stock", "Some Stock", .unprofiled),
            choice("generic", "Color Negative (Generic)", .generic)
        ]
        let out = StockChoices.grouped(input)
        XCTAssertEqual(out.map(\.id), ["generic", "kodak-gold-200", "some-stock", "bw-generic"])
        // Stated as the rule too, so a reordering of the input cannot make this pass by
        // accident: the generic entry's name begins with C and would sort into the middle.
        XCTAssertEqual(out.first?.kind, .generic)
        XCTAssertEqual(out.last?.kind, .mono)
    }

    /// A maker's stocks form one contiguous run, so the test asserts
    /// contiguity rather than an index, which is what "all Kodak together" means and is
    /// what a per-entry sort key alone would not give.
    func testEveryMakerFormsOneContiguousRun() throws {
        let input = [
            choice("fujifilm-400", "Fujifilm 400", .curve(measured: true)),
            choice("kodak-gold-200", "Kodak Gold 200", .curve(measured: false)),
            choice("lomography-cn-400", "Lomography 400", .alias(target: "Kodak UltraMax 400", crossProcessed: false)),
            choice("cinestill-800t", "CineStill 800T", .alias(target: "Kodak Vision3 500T", crossProcessed: true)),
            choice("fujifilm-200", "Fujifilm 200", .alias(target: "Kodak Gold 200", crossProcessed: false)),
            choice("ektacolor-pro-400", "Kodak Ektacolor Pro 400", .alias(target: "Kodak Portra 400", crossProcessed: false)),
            choice("ilford-something", "Ilford Something", .curve(measured: true)),
            choice("kodak-ektar-100", "Kodak Ektar 100", .curve(measured: false)),
            choice("generic", "Color Negative (Generic)", .generic),
            choice("bw-generic", "Black & White", .mono)
        ]
        let out = StockChoices.grouped(input)

        func run(_ prefix: String) -> Range<Int> {
            let idx = out.indices.filter { out[$0].name.lowercased().hasPrefix(prefix) }
            XCTAssertFalse(idx.isEmpty, "no \(prefix) entry survived grouping")
            XCTAssertEqual(idx.count, (idx.first! ... idx.last!).count,
                           "\(prefix) entries are split apart: \(out.map(\.name))")
            return idx.first! ..< (idx.last! + 1)
        }
        let kodak = run("kodak"), fuji = run("fuji"), cine = run("cinestill"), lomo = run("lomography")

        // Contiguity is the criterion; the order BETWEEN makers is the secondary rule the
        // code documents, so assert that too rather than leaving it free.
        XCTAssertLessThan(kodak.lowerBound, fuji.lowerBound)
        XCTAssertLessThan(fuji.lowerBound, cine.lowerBound)
        XCTAssertLessThan(cine.lowerBound, lomo.lowerBound)
        // and a maker with no rank of its own sorts after the named ones, still ahead of mono
        let ilford = try XCTUnwrap(out.firstIndex { $0.id == "ilford-something" })
        XCTAssertGreaterThan(ilford, lomo.upperBound - 1)
        XCTAssertEqual(out.last?.kind, .mono)

        // Within one maker, natural order. "Ektar 100" before "Gold 200" is alphabetical;
        // the point of localizedStandardCompare is that digits compare as numbers.
        let kodakNames = out[kodak].map(\.name)
        XCTAssertEqual(kodakNames, ["Kodak Ektacolor Pro 400", "Kodak Ektar 100", "Kodak Gold 200"])
    }

    /// Numbers sort as numbers inside a maker, which a plain string sort gets wrong. Written
    /// so it would fail against `<` on the names: "Kodak Gold 1000" sorts before
    /// "Kodak Gold 200" lexically and after it naturally.
    func testWithinAMakerNumbersSortNumerically() {
        let out = StockChoices.grouped([
            choice("a", "Kodak Gold 1000", .curve(measured: false)),
            choice("b", "Kodak Gold 200", .curve(measured: false)),
            choice("c", "Kodak Gold 90", .curve(measured: false))
        ])
        XCTAssertEqual(out.map(\.name), ["Kodak Gold 90", "Kodak Gold 200", "Kodak Gold 1000"])
    }

    /// Grouping reorders and never adds, drops or rewrites an entry. The picker's selection
    /// is bound to these ids, so losing one silently blanks the control and the first
    /// interaction rewrites the sidecar, which is the trap `list` already documents.
    func testGroupingIsAPermutation() {
        let input = [
            choice("generic", "Color Negative (Generic)", .generic),
            choice("kodak-gold-200", "Kodak Gold 200", .curve(measured: false)),
            choice("fujifilm-400", "Fujifilm 400", .curve(measured: true)),
            choice("mystery", "Mystery", .unprofiled),
            choice("bw-generic", "Black & White", .mono)
        ]
        let out = StockChoices.grouped(input)
        XCTAssertEqual(out.count, input.count)
        XCTAssertEqual(Set(out.map(\.id)), Set(input.map(\.id)))
        XCTAssertEqual(Set(out.map(\.id)).count, out.count, "an id is listed twice")
        for c in input {
            XCTAssertEqual(out.first { $0.id == c.id }?.name, c.name, "\(c.id) was relabelled")
        }
    }

    /// Two entries that rank the same and are named the same must not make the sort throw.
    /// Swift's `sorted(by:)` traps on a comparator that is not a strict weak ordering, so
    /// this is about the comparator being total, not about the output order.
    func testEqualNamesDoNotTrapTheSort() {
        let out = StockChoices.grouped([
            choice("a", "Kodak Gold 200", .curve(measured: false)),
            choice("b", "Kodak Gold 200", .curve(measured: false)),
            choice("c", "Kodak Gold 200", .curve(measured: true))
        ])
        XCTAssertEqual(out.count, 3)
    }

    // MARK: prettify

    /// The Kodak families that ship without the maker in their id get it, so they land in
    /// the Kodak run rather than under E, C or G. This is the half that makes the grouping
    /// rule above reach the alias entries at all.
    func testKodakFamiliesGainTheMakerPrefix() {
        XCTAssertEqual(StockChoices.prettify("ektacolor-pro-400"), "Kodak Ektacolor Pro 400")
        XCTAssertEqual(StockChoices.prettify("ektacolor-pro-160"), "Kodak Ektacolor Pro 160")
        XCTAssertEqual(StockChoices.prettify("ektar-100"), "Kodak Ektar 100")
        XCTAssertEqual(StockChoices.prettify("gold-200"), "Kodak Gold 200")
        XCTAssertEqual(StockChoices.prettify("portra-400"), "Kodak Portra 400")
        XCTAssertEqual(StockChoices.prettify("ultramax-400"), "Kodak Ultramax 400")
        XCTAssertEqual(StockChoices.prettify("vision3-250d"), "Kodak Vision3 250D")
        XCTAssertEqual(StockChoices.prettify("colorplus-200"), "Kodak Colorplus 200")
        // and the prefix is never doubled on an id that already carries the maker
        XCTAssertEqual(StockChoices.prettify("kodak-gold-200"), "Kodak Gold 200")
        XCTAssertEqual(StockChoices.prettify("kodak-ektar-100"), "Kodak Ektar 100")
    }

    /// A maker that is not Kodak keeps its own name and gains nothing.
    func testOtherMakersAreNotRelabelledAsKodak() {
        XCTAssertEqual(StockChoices.prettify("fujifilm-200"), "Fujifilm 200")
        XCTAssertEqual(StockChoices.prettify("ilford-hp5-plus"), "Ilford Hp5 Plus")
        for id in ["fujifilm-200", "ilford-hp5-plus", "cinestill-50d", "lomography-cn-400"] {
            XCTAssertFalse(StockChoices.prettify(id).hasPrefix("Kodak"), "\(id) was labelled Kodak")
        }
    }

    /// `cn` is a Lomography packaging token, not part of the name anyone says, so
    /// "Lomography CN 400" reads as "Lomography 400". The dropped segment must not leave a
    /// double space behind, which is what the empty-string filter in `prettify` is for.
    func testTheLomographyCNTokenIsDroppedCleanly() {
        XCTAssertEqual(StockChoices.prettify("lomography-cn-400"), "Lomography 400")
        XCTAssertEqual(StockChoices.prettify("lomography-cn-800"), "Lomography 800")
        for id in ["lomography-cn-400", "lomography-cn-800"] {
            let name = StockChoices.prettify(id)
            XCTAssertFalse(name.contains("  "), "\(id) left a double space: \(name)")
            XCTAssertFalse(name.hasPrefix(" ") || name.hasSuffix(" "), "\(id) has edge whitespace")
            XCTAssertFalse(name.lowercased().contains(" cn "), "\(id) still carries CN")
        }
        // Only the standalone token goes. A name that merely contains those letters is
        // untouched, which is the difference between a token filter and a substring one.
        XCTAssertEqual(StockChoices.prettify("cnx-100"), "Cnx 100")
    }

    /// CineStill's inner capital survives word casing, which a blanket capitalize would
    /// flatten to "Cinestill".
    func testCineStillKeepsItsCasing() {
        XCTAssertEqual(StockChoices.prettify("cinestill-50d"), "CineStill 50D")
        XCTAssertEqual(StockChoices.prettify("cinestill-800t"), "CineStill 800T")
        XCTAssertEqual(StockChoices.prettify("cinestill-400d"), "CineStill 400D")
    }

    /// A speed with its balance letter is the manufacturer's own capitalisation (Vision3
    /// 250D, CineStill 800T), and AHU is an initialism nobody writes in lower case. Both
    /// are token rules, so a word that merely starts with a letter is untouched.
    func testSpeedLettersAndInitialismsAreUppercased() {
        XCTAssertEqual(StockChoices.prettify("reflx-lab-320d-ahu"), "Reflx Lab 320D AHU")
        XCTAssertEqual(StockChoices.prettify("kodak-vision3-500t"), "Kodak Vision3 500T")
        XCTAssertEqual(StockChoices.prettify("reflx-lab-640t-ahu"), "Reflx Lab 640T AHU")
        XCTAssertEqual(StockChoices.prettify("reflx-lab-50d-ahu"), "Reflx Lab 50D AHU")
        XCTAssertEqual(StockChoices.prettify("ilford-hp5-plus"), "Ilford Hp5 Plus")
    }

    /// A bare numeric segment is passed through rather than run through the capitaliser, so
    /// an id that is nothing but digits still reads as itself.
    func testNumericSegmentsArePassedThrough() {
        XCTAssertEqual(StockChoices.prettify("400"), "400")
        XCTAssertEqual(StockChoices.prettify("some-stock-we-never-heard-of"),
                       "Some Stock We Never Heard Of")
        XCTAssertEqual(StockChoices.prettify(""), "")
    }

    /// The two functions together: every entry the bundle offers is labeled and the makers
    /// are contiguous in the real list, not only in a hand-built one. Asserted as rules so
    /// it does not go stale when a profile ships.
    func testTheBundledListIsLabelledAndGrouped() throws {
        let library = try ProfileLibrary.bundled()
        let list = StockChoices.list(from: library, current: nil)
        XCTAssertEqual(list.first?.kind, .generic)
        // Second, not last: the two always-working answers are one block.
        XCTAssertEqual(list.dropFirst().first?.kind, .mono)
        for c in list {
            XCTAssertFalse(c.name.isEmpty, "\(c.id) has no label")
            XCTAssertNotEqual(c.name, c.id, "\(c.id) is showing its slug as its label")
            XCTAssertFalse(c.name.contains("  "), "\(c.id) has a double space: \(c.name)")
        }
        for prefix in ["kodak", "fuji", "cinestill", "lomography"] {
            let idx = list.indices.filter { list[$0].name.lowercased().hasPrefix(prefix) }
            guard !idx.isEmpty else { continue }
            XCTAssertEqual(idx.count, (idx.first! ... idx.last!).count,
                           "\(prefix) is split in the shipped list: \(list.map(\.name))")
        }
    }

    // MARK: the three blocks

    /// The picker draws three blocks with a divider between them. The first two entries are
    /// the two answers that always work, in that order and with those words; the shipped
    /// stocks follow, and the person's own imported profiles come last and only when they exist.
    func testTheFirstBlockIsTheTwoAlwaysWorkingEntriesInOrder() throws {
        let library = try ProfileLibrary.bundled()
        let groups = StockChoices.groups(from: library, current: nil)

        let basics = try XCTUnwrap(groups.first)
        XCTAssertEqual(basics.role, .basics)
        XCTAssertEqual(basics.choices.map(\.id), ["generic", ProfileLibrary.monoStockID])
        XCTAssertEqual(basics.choices.map(\.name), ["Color Negative", "Black & White Negative"])

        // The shipped block exists and holds the named stocks, none of which are the two
        // above.
        let shipped = try XCTUnwrap(groups.first { $0.role == .shipped })
        XCTAssertFalse(shipped.choices.isEmpty)
        XCTAssertFalse(shipped.choices.contains { $0.id == "generic" || $0.id == ProfileLibrary.monoStockID })

        // With no user profile loaded the third block is ABSENT rather than present and
        // empty.
        XCTAssertEqual(library.userFilmIDs.intersection(Set(library.films.keys)).isEmpty,
                       !groups.contains { $0.role == .user },
                       "the user block appears exactly when a user profile is loaded")

        // `list` is the blocks flattened, in order, so the two views cannot disagree.
        XCTAssertEqual(StockChoices.list(from: library, current: nil).map(\.id),
                       groups.flatMap { $0.choices }.map(\.id))
    }

    /// The word "generic" never reaches a name the picker draws, whatever the bundle holds.
    /// The id keeps it forever, which is the point of the split.
    func testNoEntryNameSaysGeneric() throws {
        let library = try ProfileLibrary.bundled()
        for choice in StockChoices.list(from: library, current: "some-unknown-stock-2026") {
            XCTAssertFalse(choice.name.lowercased().contains("generic"), "name: \(choice.name)")
        }
    }
}
