import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// CineStill 800T: a stock whose distinctive behavior is declared by a MARKET NAME rather
/// than by a profile file.
///
/// 800T is remjet-removed Vision3 500T (5219) rated 800, so every number it renders through
/// is Kodak's, read from the 500T sheet. What it adds is an activity, `balanceChannels` at
/// strength 1.0 scope frame, picked by eye off a ladder of balance strengths and measured on
/// 8 frames as a contrast operator: up about 35 percent at full strength with a* moving only
/// 7.62 to 7.98, so the 500T-curve magenta residual survives it rather than being corrected
/// away.
///
/// The claim that has to hold forever is a PAIR, and the second half is the one that would
/// have been lost by the obvious implementation. 800T declares the activity, AND 800T is
/// still flagged cross-processed. Shipping a real `cinestill-800t.json` would have satisfied
/// the first and silently broken the second, because a real profile file shadows the alias
/// and `resolveFilm` reads `crossProcessed` only when nothing shadows the id.
final class CineStill800TTests: XCTestCase {
    private let stock = "cinestill-800t"
    private let target = "kodak-vision3-500t"

    private func library() throws -> ProfileLibrary { try ProfileLibrary.bundled() }

    // MARK: the pair that has to hold

    /// Half one: the activity reaches the resolved profile, with the parameters the file set.
    func test800TDeclaresTheChannelBalanceThroughItsAlias() throws {
        let resolved = try library().resolveFilm(stock)
        XCTAssertTrue(resolved.profile.balancesChannels, "the market name's activity did not reach the profile")
        let settings = try XCTUnwrap(resolved.profile.channelBalanceSettings)
        XCTAssertEqual(settings.strength, 1.0, accuracy: 1e-12)
        XCTAssertEqual(settings.scope, .frame)
    }

    /// Half two, and this is the acceptance test for the whole design rather than a footnote.
    /// The flag must survive the change, because the chemistry is still wrong for the sheet
    /// and the picker has to be able to say so.
    func test800TIsStillFlaggedCrossProcessedAfterGainingTheActivity() throws {
        let resolved = try library().resolveFilm(stock)
        XCTAssertTrue(resolved.crossProcessed,
                      "the cross-process flag is read only when no real profile file shadows the alias")
        XCTAssertTrue(resolved.profile.balancesChannels, "and it holds AT THE SAME TIME as the activity")
    }

    /// The structural reason half two holds: there is no profile file for this id. If one
    /// ever ships, this fails before anybody notices the flag went quiet.
    func testNoRealProfileFileShadowsTheMarketName() throws {
        XCTAssertNil(try library().films[stock],
                     "a real cinestill-800t.json would shadow the alias and switch crossProcessed off")
    }

    // MARK: the curves are the target's

    /// The numbers stay single-sourced: 800T renders through exactly the 500T profile it
    /// points at, activity aside. Asserted on the curves rather than on the file, because
    /// that is the claim that matters.
    func test800TRendersThroughExactlyTheVision3500TCurves() throws {
        let library = try self.library()
        let mine = library.resolveFilm(stock)
        let theirs = library.resolveFilm(target)
        XCTAssertEqual(mine.profile.id, theirs.profile.id, "it resolves to the 500T profile, activity aside")
        XCTAssertEqual(mine.dyeGamma, theirs.dyeGamma)
        XCTAssertEqual(mine.profile.datasheetDyeGamma, theirs.profile.datasheetDyeGamma)
    }

    /// And the target does NOT inherit the market name's activity. Vision3 500T shot and
    /// developed as Vision3 500T is a different thing from 800T and must render as it did.
    func testTheTargetProfileDoesNotGainTheActivity() throws {
        let library = try self.library()
        XCTAssertFalse(library.resolveFilm(target).profile.balancesChannels,
                       "the alias may not reach back into the profile it points at")
        XCTAssertFalse(try XCTUnwrap(library.films[target]).balancesChannels,
                       "nor into the stored profile every other caller reads")
    }

    // MARK: what stays OFF

    /// Everything else the mechanism COULD apply to and deliberately does not. 50D and the
    /// Reflx stocks are the same shape and nobody has measured them; Treat is excluded on
    /// evidence, because there the activity is a 3 percent no-op on clean frames and looks
    /// like a win only on fogged ones, where it is undoing our own edge-base misread.
    func testNoOtherStockGainedAnActivityTonight() throws {
        let library = try self.library()
        for id in ["cinestill-50d", "reflx-lab-320d-ahu", "reflx-lab-640t-ahu", "reflx-lab-50d-ahu",
                   "kodak-vision3-250d", "kodak-vision3-500t", "kodak-gold-200",
                   "kodak-ultramax-400", "kodak-portra-400", "generic"] {
            XCTAssertFalse(library.resolveFilm(id).profile.balancesChannels,
                           "\(id) must not balance channels")
        }
        // Said as a count as well, so a stock added later cannot slip past the list above.
        let balancing = library.films.values.filter(\.balancesChannels).map(\.id).sorted()
        XCTAssertEqual(balancing, ["harman-switch-azure"],
                       "exactly one PROFILE FILE declares the balance, and it is Azure")
        XCTAssertEqual(library.aliasActivities.keys.sorted(), [stock],
                       "exactly one ALIAS declares an activity, and it is CineStill 800T")
    }

    // MARK: the merge, both halves, because nothing SHIPPED exercises either

    /// A library whose `aliases.json` has one entry replaced, written and read back through
    /// the real decode path so the payload is parsed rather than hand-constructed. Azure is
    /// the target in these, because it is the one shipped profile that declares an activity
    /// of its own, which is what makes the union and the override observable at all.
    private func libraryWithAlias(_ id: String, _ entry: [String: Any]) throws -> ProfileLibrary {
        let fm = FileManager.default
        let dst = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-alias-activities-\(UUID().uuidString)")
        try fm.copyItem(at: try ProfileLibrary.bundled().root, to: dst)
        addTeardownBlock { try? fm.removeItem(at: dst) }
        let url = dst.appendingPathComponent("aliases.json")
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        var films = try XCTUnwrap(root["films"] as? [String: Any])
        films[id] = entry
        root["films"] = films
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted]).write(to: url)
        return try ProfileLibrary(root: dst)
    }

    /// An alias entry ADDS to whatever its target declares rather than replacing the set.
    func testAnAliasActivityIsAddedToItsTargetsOwn() throws {
        let library = try libraryWithAlias("test-market-name", [
            "to": "harman-switch-azure",
            "activities": [["name": "someFutureThing"]],
        ])
        let merged = library.resolveFilm("test-market-name").profile
        XCTAssertEqual(merged.activities?.map(\.name).sorted(), ["balanceChannels", "someFutureThing"])
        XCTAssertTrue(merged.balancesChannels, "the target's own activity survived the merge")
        XCTAssertEqual(try XCTUnwrap(merged.channelBalanceSettings).strength, 1.0, accuracy: 1e-12)
    }

    /// And it WINS by name where both declare the same one, so a market name can differ from
    /// its emulsion without the emulsion losing its own setting for everybody else.
    func testAnAliasActivityOverridesItsTargetsByName() throws {
        let library = try libraryWithAlias("test-market-name", [
            "to": "harman-switch-azure",
            "activities": [["name": "balanceChannels", "strength": 0.25, "scope": "selection"]],
        ])
        let merged = library.resolveFilm("test-market-name").profile
        XCTAssertEqual(merged.activities?.count, 1, "one entry, not two competing ones")
        let settings = try XCTUnwrap(merged.channelBalanceSettings)
        XCTAssertEqual(settings.strength, 0.25, accuracy: 1e-12)
        XCTAssertEqual(settings.scope, .selection)

        let azure = try XCTUnwrap(library.films["harman-switch-azure"]?.channelBalanceSettings)
        XCTAssertEqual(azure.strength, 1.0, accuracy: 1e-12, "and Azure itself is untouched")
        XCTAssertEqual(azure.scope, .frame)
    }

    /// Declaring nothing costs nothing and changes nothing, which is what keeps every other
    /// alias in the shipped file behaving as it would with no activity field at all.
    func testAnAliasThatDeclaresNothingLeavesItsTargetAlone() throws {
        let library = try libraryWithAlias("test-market-name", ["to": "kodak-gold-200"])
        let merged = library.resolveFilm("test-market-name").profile
        XCTAssertNil(merged.activities)
        XCTAssertFalse(merged.balancesChannels)
        XCTAssertEqual(merged, try XCTUnwrap(library.films["kodak-gold-200"]),
                       "an alias with no payload hands back its target unchanged")
    }

    /// An unknown word in an alias payload degrades exactly the way an unknown word in a
    /// profile already did: it costs the activity, never the alias and never the whole file.
    func testAnUnknownActivityNameFromAnAliasIsIgnored() throws {
        let library = try libraryWithAlias("test-market-name", [
            "to": "kodak-gold-200",
            "activities": [["name": "someFutureThing", "strength": 1.0]],
        ])
        let merged = library.resolveFilm("test-market-name").profile
        XCTAssertFalse(merged.balancesChannels)
        XCTAssertEqual(merged.activities?.count, 1, "it is carried, it is simply not understood")
        XCTAssertNil(merged.channelBalanceSettings)
        XCTAssertFalse(library.films.isEmpty, "and the rest of the library still loaded")
    }

    /// A market name whose target does not exist still gets its activity, because the
    /// activity is a fact about the film rather than about the curves it borrows.
    func testAnAliasActivitySurvivesAFallbackToGeneric() throws {
        let library = try libraryWithAlias("test-market-name", [
            "to": "a-profile-that-does-not-exist",
            "activities": [["name": "balanceChannels", "strength": 0.5, "scope": "frame"]],
        ])
        let resolved = library.resolveFilm("test-market-name")
        XCTAssertTrue(resolved.fellBackToGeneric)
        XCTAssertEqual(try XCTUnwrap(resolved.profile.channelBalanceSettings).strength, 0.5, accuracy: 1e-12)
    }
}
