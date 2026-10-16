import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Harman Switch Azure, a stock offered with no numbers of its own.
///
/// Its maker publishes a datasheet and that sheet carries no characteristic curve and
/// no spectral dye density curve, so there is nothing here to ship. The row
/// exists for one reason: the film is unmasked, the maker's own sheet says so and gives
/// per-channel scanner guidance, so the profile DECLARES an activity the kernel runs.
///
/// The claim that has to hold forever is the pair: it renders through exactly the curves
/// Color Negative renders through, and it declares one activity that no other stock does.
/// Anything else here would be a number we invented.
final class AzureStockTests: XCTestCase {
    private let azure = "harman-switch-azure"

    private func library() throws -> ProfileLibrary { try ProfileLibrary.bundled() }

    // MARK: no numbers of its own

    func testAzureShipsAndCarriesNoNumbersOfItsOwn() throws {
        let film = try XCTUnwrap(try library().films[azure], "the stock did not ship")
        XCTAssertNil(film.datasheetDyeGamma)
        XCTAssertFalse(film.isDatasheet)
    }

    /// The other half of the same promise, said as a render fact rather than as a file fact.
    func testAzureRendersOnExactlyTheColorNegativePath() throws {
        let library = try self.library()
        let azureResolved = library.resolveFilm(azure)
        let generic = library.resolveFilm("generic")
        XCTAssertEqual(azureResolved.dyeGamma, generic.dyeGamma,
                       "Azure renders through something Color Negative does not")
        XCTAssertFalse(azureResolved.profile.isMono)
    }

    // MARK: the activity it declares

    func testAzureDeclaresTheChannelBalanceAndNothingElseDoes() throws {
        let library = try self.library()
        XCTAssertTrue(try XCTUnwrap(library.films[azure]).balancesChannels)
        for film in library.films.values where film.id != azure {
            XCTAssertFalse(film.balancesChannels, "\(film.id) also declares the channel balance")
        }
    }

    /// The activity reaches the kernel from the STOCK, with no control involved, and it
    /// reaches it under every tone, because it runs before the tone step rather than being
    /// one of them.
    func testTheActivityReachesTheKernelUnderEveryTone() throws {
        let svc = CPURenderService(profiles: try library())
        for tone in ToneNames.all {
            let d = DevelopSettings(stock: azure,
                                    tone: tone, autoBalance: true, base: BaseSettings(mode: .anchor))
            XCTAssertTrue(svc.developInput(for: d).balanceChannels, "\(tone.rawValue) lost the activity")
        }
        let other = DevelopSettings(stock: "kodak-gold-200",
                                    tone: .flat, autoBalance: true, base: BaseSettings(mode: .anchor))
        XCTAssertFalse(svc.developInput(for: other).balanceChannels)
    }

    /// The activity lives on the profile, so the Tone row is not touched and never shows None
    /// while something else made the picture. Every stock, Azure included, opens on the same
    /// default tone.
    func testNoStockMovesTheAppsDefaultTone() throws {
        let library = try self.library()
        for film in library.films.values {
            let d = library.initialDevelop(capture: CaptureInfo(film: film.name))
            XCTAssertEqual(d.stock, ProfileLibrary.genericStockName, "\(film.id) picked by name")
            XCTAssertEqual(d.tone, .none, "\(film.id) moved the app's default tone")
        }
        let azureOpen = library.initialDevelop(capture: CaptureInfo(film: "Harman Switch Azure",
                                                                    filmMaker: "Harman"))
        XCTAssertEqual(azureOpen.stock, ProfileLibrary.genericStockName,
                       "the film name picked the stock on open; the person picks Azure")
        XCTAssertEqual(library.stockID(forFilmName: "Harman Switch Azure", maker: "Harman"), azure)
        XCTAssertEqual(azureOpen.tone, .none, "the stock reached in and set a tone")
        let bare = library.initialDevelop(capture: nil)
        XCTAssertEqual(bare.stock, ProfileLibrary.genericStockName)
        XCTAssertEqual(bare.tone, .none)
    }

    /// There are exactly three tones and none of them is the activity. A fourth segment would
    /// put a word in every sidecar that chose it, and we could never stop reading it.
    func testTheToneRowIsStillThreeAndCarriesNoActivity() {
        XCTAssertEqual(ToneNames.all, [.none, .flat, .print])
        XCTAssertEqual(Set(ToneNames.all.map(\.rawValue)), ["none", "flat", "print"])
        // The value a fourth tone would have used. It must not decode, or a sidecar carrying
        // it would still select something here.
        XCTAssertNil(ToneMode(rawValue: "even"), "a fourth tone value still decodes")
    }

    /// `activities` is a raw string array on purpose, so a word from a newer build or a hand
    /// edit costs the activity and never the whole profile. Decoded from JSON rather than
    /// built in memory, because failing to decode is the failure this guards against.
    func testAnUnknownActivityIsIgnoredRatherThanLosingTheStock() throws {
        func profile(_ body: String) throws -> FilmProfile {
            try JSONDecoder().decode(FilmProfile.self, from: Data(body.utf8))
        }
        let future = try profile(#"{"id":"x","name":"X","activities":["somethingFromALaterBuild"]}"#)
        XCTAssertEqual(future.id, "x", "the stock was lost entirely over one unknown word")
        XCTAssertFalse(future.balancesChannels, "an unknown activity must not turn something on")
        let mixed = try profile(#"{"id":"x","name":"X","activities":["somethingElse","balanceChannels"]}"#)
        XCTAssertTrue(mixed.balancesChannels, "a known activity was lost because of an unknown neighbour")
        let none = try profile(#"{"id":"x","name":"X"}"#)
        XCTAssertFalse(none.balancesChannels)
        XCTAssertFalse(none.isHidden, "a profile that says nothing is offered, not hidden")
    }

    // MARK: the picker

    @MainActor
    func testAzureIsOfferedAndSaysWhatItIs() throws {
        let choices = StockChoices.list(from: try library(), current: nil)
        let rows = choices.filter { $0.id == azure }
        XCTAssertEqual(rows.count, 1, "Azure is missing from the picker, or is in it twice")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.name, "Harman Switch Azure 125")
        XCTAssertEqual(row.kind, .noPublishedCurve(balancesChannels: true))
    }

    /// Adding an entry may not disturb the rest of the list. Same groups, same order among
    /// everything that was already there.
    @MainActor
    func testAddingAzureLeavesEveryOtherRowWhereItWas() throws {
        let library = try self.library()
        let ids = StockChoices.list(from: library, current: nil).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "a stock is in the picker twice")
        // The first group is the two answers that always work, in that order, and a new
        // entry may not land in it. Mono is LAST IN THAT GROUP, not last in the list: the
        // flattening puts basics first, then the shipped stocks, then the user's own.
        XCTAssertEqual(Array(ids.prefix(2)), [StockChoices.genericID, ProfileLibrary.monoStockID],
                       "the first group is no longer Color Negative then Black & White")
        XCTAssertGreaterThan(try XCTUnwrap(ids.firstIndex(of: azure)), 1,
                             "Azure landed in the first group, which is for the two that always work")
        // Azure carries no maker prefix the grouping knows, so it sorts with the other
        // non-Kodak, non-Fuji makers and ahead of the mono entry, never among Kodak's.
        let azureIndex = try XCTUnwrap(ids.firstIndex(of: azure))
        let kodakLast = try XCTUnwrap(ids.lastIndex { $0.hasPrefix("kodak") })
        XCTAssertGreaterThan(azureIndex, kodakLast, "Azure sorted in among Kodak's own films")
    }

    // MARK: the activity's parameters are in the file too

    private func parsed(_ body: String) throws -> FilmProfile {
        try JSONDecoder().decode(FilmProfile.self, from: Data(body.utf8))
    }

    /// A copy of the shipped bundle with one hand-written profile dropped into its films
    /// folder, so a test can exercise a profile NOBODY SHIPS through the real load path.
    /// Writing the JSON rather than building a `FilmProfile` in memory is the point: the
    /// claim under test is about what a file can say.
    private func libraryCarrying(_ json: String, id: String) throws -> ProfileLibrary {
        let fm = FileManager.default
        let dst = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-activity-profiles-\(UUID().uuidString)")
        try fm.copyItem(at: try ProfileLibrary.bundled().root, to: dst)
        addTeardownBlock { try? fm.removeItem(at: dst) }
        try Data(json.utf8).write(to: dst.appendingPathComponent("films/\(id).json"))
        return try ProfileLibrary(root: dst)
    }

    /// Azure's own parameters live in its profile, not in a constant in Swift, so its strength
    /// can change without a code change.
    func testAzureCarriesItsParametersInTheProfileFile() throws {
        let film = try XCTUnwrap(try library().films[azure])
        let entry = try XCTUnwrap(film.activities?.first, "Azure declares no activity")
        XCTAssertEqual(entry.name, "balanceChannels")
        XCTAssertEqual(entry.strength, 1.0, "the strength is not stated in the file")
        XCTAssertEqual(entry.scope, "frame", "the scope is not stated in the file")
        let settings = try XCTUnwrap(film.channelBalanceSettings)
        XCTAssertEqual(settings.strength, 1, accuracy: 1e-12)
        XCTAssertEqual(settings.scope, .frame)
    }

    /// A file that lists a bare activity name still reads, and a bare name means the defaults.
    /// This makes the parameterized shape additive rather than a migration.
    func testABareActivityNameStillMeansTheDefaults() throws {
        let film = try parsed(#"{"id":"x","name":"X","activities":["balanceChannels"]}"#)
        XCTAssertTrue(film.balancesChannels)
        let settings = try XCTUnwrap(film.channelBalanceSettings)
        XCTAssertEqual(settings.strength, 1, accuracy: 1e-12, "a bare name changed the strength")
        XCTAssertEqual(settings.scope, .frame, "a bare name changed the scope")
    }

    /// The parameters a file sets are the parameters the KERNEL gets, through the shipped
    /// settings-to-input path rather than by reading the profile in the test.
    func testAProfilesStrengthReachesTheKernel() throws {
        func strengthReaching(_ json: String) throws -> Double {
            let svc = CPURenderService(profiles: try libraryCarrying(json, id: "x"))
            let d = DevelopSettings(stock: "x",
                                    tone: .none, autoBalance: true, base: BaseSettings(mode: .anchor))
            return svc.developInput(for: d).balanceStrength
        }
        let half = #"{"id":"x","name":"X","activities":[{"name":"balanceChannels","strength":0.5}]}"#
        XCTAssertEqual(try strengthReaching(half), 0.5, accuracy: 1e-12,
                       "the file set a strength and the kernel did not get it")
        let bare = #"{"id":"x","name":"X","activities":["balanceChannels"]}"#
        XCTAssertEqual(try strengthReaching(bare), 1, accuracy: 1e-12)
    }

    /// The tolerance contract, extended from names to payloads: a file from a newer build
    /// degrades to the part this build understands rather than failing to load. Nothing here
    /// may throw and nothing may turn something on that was not asked for.
    func testAnUnknownPayloadDegradesTheSameWayAnUnknownNameDoes() throws {
        let future = try parsed(#"{"id":"x","name":"X","activities":[{"name":"balanceChannels","strength":0.25,"somethingFromALaterBuild":{"a":[1,2]}}]}"#)
        XCTAssertEqual(try XCTUnwrap(future.channelBalanceSettings).strength, 0.25, accuracy: 1e-12,
                       "an unknown neighbouring key cost the strength beside it")
        let futureName = try parsed(#"{"id":"x","name":"X","activities":[{"name":"somethingElse","strength":0.5}]}"#)
        XCTAssertFalse(futureName.balancesChannels, "an unknown activity turned something on")
        XCTAssertNil(futureName.channelBalanceSettings)
        XCTAssertEqual(futureName.id, "x", "the stock was lost over an unknown activity object")
        // Out of range is clamped rather than refused, so a hand edit cannot reach the kernel
        // with a number the operator has no meaning for.
        XCTAssertEqual(try XCTUnwrap(try parsed(#"{"id":"x","name":"X","activities":[{"name":"balanceChannels","strength":9}]}"#).channelBalanceSettings).strength,
                       1, accuracy: 1e-12, "a strength above 1 was not clamped")
        XCTAssertEqual(try XCTUnwrap(try parsed(#"{"id":"x","name":"X","activities":[{"name":"balanceChannels","strength":-4}]}"#).channelBalanceSettings).strength,
                       0, accuracy: 1e-12, "a negative strength was not clamped")
        // An unrecognised scope word falls back to the one this build can actually do.
        XCTAssertEqual(try XCTUnwrap(try parsed(#"{"id":"x","name":"X","activities":[{"name":"balanceChannels","scope":"perRollIshMaybe"}]}"#).channelBalanceSettings).scope,
                       .frame, "an unknown scope word was not defaulted")
    }

    /// A profile may carry `"style": "blackPoint"`, a balance style that no longer exists, in
    /// its activity entry, and it must still load and still run the balance, which is always
    /// the stretch.
    func testARetiredBlackPointStyleStillLoadsAndRunsTheStretch() throws {
        let json = #"{"id":"x","name":"X","activities":[{"name":"balanceChannels","style":"blackPoint","strength":1}]}"#
        let film = try parsed(json)
        XCTAssertTrue(film.balancesChannels, "the activity was lost with the retired key")
        XCTAssertEqual(try XCTUnwrap(film.channelBalanceSettings).strength, 1, accuracy: 1e-12)
        let svc = CPURenderService(profiles: try libraryCarrying(json, id: "x"))
        let d = DevelopSettings(stock: "x",
                                tone: .none, autoBalance: true, base: BaseSettings(mode: .anchor))
        let input = svc.developInput(for: d)
        XCTAssertTrue(input.balanceChannels)
        let (analysis, _) = DevelopMath.analyze(ramp(), input: input)
        let balance = try XCTUnwrap(analysis.balance, "no balance ran")
        XCTAssertEqual(balance.strength, 1, accuracy: 1e-12)
    }

    /// A profile may ASK for a pooled balance, and this build cannot give it one, because the
    /// app has no selection pre-pass. What must never happen is the balance claiming to be
    /// pooled when it measured a single frame: `source` reports what happened, not what was
    /// requested. Recorded as a test so the knob cannot quietly start reading as honored.
    func testDeclaringSelectionScopeDoesNotClaimAPooledBalance() throws {
        let json = #"{"id":"x","name":"X","activities":[{"name":"balanceChannels","scope":"selection"}]}"#
        let film = try parsed(json)
        XCTAssertEqual(try XCTUnwrap(film.channelBalanceSettings).scope, .selection,
                       "the file's scope was lost on the way in")
        let svc = CPURenderService(profiles: try libraryCarrying(json, id: "x"))
        let d = DevelopSettings(stock: "x",
                                tone: .none, autoBalance: true, base: BaseSettings(mode: .anchor))
        let (analysis, _) = DevelopMath.analyze(ramp(), input: svc.developInput(for: d))
        XCTAssertEqual(try XCTUnwrap(analysis.balance).source, .frame,
                       "a profile asking for a pooled balance got one reported as pooled")
    }

    /// Three differently placed channels, so a per-channel operator has something to find.
    private func ramp(width: Int = 160, height: Int = 120) -> DecodedFrame {
        var px = [UInt16](repeating: 0, count: width * height * 3)
        let spans: [(Double, Double)] = [(6_000, 52_000), (9_000, 61_000), (4_000, 38_000)]
        for i in 0..<(width * height) {
            let t = Double(i) / Double(width * height - 1)
            for c in 0..<3 { px[i * 3 + c] = UInt16(spans[c].0 + (spans[c].1 - spans[c].0) * t) }
        }
        return DecodedFrame(width: width, height: height, pixels: px)
    }

    // MARK: the activity is DATA, not Swift

    /// The open-source claim, asserted rather than said: the activity lives in the profile
    /// FILE, so somebody else, including a film's maker, can ship a better profile for a
    /// stock without touching this app. An imported `.fpprofile` goes through
    /// `ProfilePackage.decode`, which keeps the whole dictionary as it arrived and derives
    /// the typed view from the same bytes, so `activities` survives import, survives the
    /// canonical re-encode `install` writes to disk, and reaches the kernel exactly as the
    /// shipped Azure entry does. Nothing about the activity is compiled in.
    func testAProfileFileCanDeclareTheActivity() throws {
        let json = """
        {
          "id": "someone-elses-unmasked-stock",
          "name": "Someone Else's Unmasked Stock",
          "maker": "Someone",
          "activities": ["balanceChannels"],
          "note": "hand written for this test, carries no numbers"
        }
        """
        let (object, profile) = try ProfilePackage.decode(Data(json.utf8))
        XCTAssertTrue(profile.balancesChannels, "the activity did not survive import")
        XCTAssertNil(profile.datasheetDyeGamma, "a file with no curve gained one")
        // `install` writes `encode(object)`, so the round trip is the thing that has to hold.
        let (_, reread) = try ProfilePackage.decode(try ProfilePackage.encode(object))
        XCTAssertTrue(reread.balancesChannels, "the canonical re-encode dropped the activity")
        // And the negative direction, so this cannot pass by everything declaring it.
        let plain = json.replacingOccurrences(of: "\"activities\": [\"balanceChannels\"],", with: "")
        XCTAssertFalse(try ProfilePackage.decode(Data(plain.utf8)).profile.balancesChannels,
                       "a profile that declares no activity balanced anyway")
    }

    /// The same claim for the PARAMETERISED form, because that is the one that makes
    /// the open-source story worth anything: an imported file must be able to set the values,
    /// not merely switch the activity on. Round tripped through the canonical re-encode that
    /// `install` writes, and checked in both directions so it cannot pass by everything
    /// reading as 0.4.
    func testAnImportedProfileCanSetTheParametersAndTheySurviveTheRoundTrip() throws {
        func body(_ activities: String) -> String {
            """
            {
              "id": "someone-elses-unmasked-stock",
              "name": "Someone Else's Unmasked Stock",
              "maker": "Someone",
              "activities": \(activities),
              "note": "hand written for this test, carries no numbers"
            }
            """
        }
        let stated = body(#"[{"name": "balanceChannels", "strength": 0.4, "scope": "selection"}]"#)
        let (object, profile) = try ProfilePackage.decode(Data(stated.utf8))
        let settings = try XCTUnwrap(profile.channelBalanceSettings, "the activity was lost on import")
        XCTAssertEqual(settings.strength, 0.4, accuracy: 1e-12, "the imported strength was lost")
        XCTAssertEqual(settings.scope, .selection, "the imported scope was lost")

        let (_, reread) = try ProfilePackage.decode(try ProfilePackage.encode(object))
        let after = try XCTUnwrap(reread.channelBalanceSettings)
        XCTAssertEqual(after.strength, 0.4, accuracy: 1e-12, "the canonical re-encode dropped the strength")
        XCTAssertEqual(after.scope, .selection, "the canonical re-encode dropped the scope")

        // The other direction: a bare name through the identical path is still the defaults,
        // so 0.4 above comes from the file and nowhere else.
        let bare = try ProfilePackage.decode(Data(body(#"["balanceChannels"]"#).utf8)).profile
        let defaults = try XCTUnwrap(bare.channelBalanceSettings)
        XCTAssertEqual(defaults.strength, 1, accuracy: 1e-12)
        XCTAssertEqual(defaults.scope, .frame)
    }
}
