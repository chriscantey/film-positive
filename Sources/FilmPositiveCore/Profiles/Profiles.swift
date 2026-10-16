import Foundation
import FilmSidecar

// Profiles: the JSON under Resources/profiles, consumed read-only. A film profile
// carries only what the app presents or reads: its id, name and
// maker, its published dye gammas with their source, its activities, a note, and whether
// it is hidden. Anything else in a file is ignored by the decoder, so an older file with
// more keys still loads.

public struct DyeGamma: Codable, Equatable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    public static let neutral = DyeGamma(r: 1, g: 1, b: 1)
}

public struct FilmProfile: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Who makes the film, as the maker writes its own name. Absent on the two entries that
    /// are not one maker's film: the unknown color negative and black and white.
    public var maker: String?
    /// Per-channel dye gammas read off a characteristic curve, green being 1, with the
    /// sheet or measurement they came from. The ONLY number a film profile contributes to
    /// a render (`DevelopMath.physicsRanges`). A stock without it renders on the generic
    /// stock's.
    ///
    /// For the shipped stocks it is written from the maker's digitized curve. The `source`
    /// carries the publication and link, so there is one place that says where the pair
    /// came from.
    public var datasheetDyeGamma: SourcedDyeGamma?
    /// The green density above film base that the maker's published characteristic curve
    /// reaches at diffuse white for a normal exposure: the ISO speed point plus 1.71 log H.
    /// The reference the Stretch control blends a thin frame's own green ceiling toward
    /// (`DevelopMath.stretchedGreenCeiling`). Read it through
    /// `ProfileLibrary.whiteDensity(for:)`, which supplies the generic value when it is absent.
    ///
    /// Written from the same digitized curve as the dye gammas, so a stock with no
    /// digitized curve carries none.
    public var whiteDensity: Double?
    /// What this stock asks the develop kernel to DO, beyond supplying curves.
    ///
    /// A profile may declare an activity as well as numbers, so a film that needs something
    /// unusual declares it here instead of earning the app another button.
    ///
    /// Absent on every stock but one, and absent means "do what all the other stocks do".
    ///
    /// Entries are matched by NAME against `Activity` rather than decoded as an enum, so a
    /// word from a newer build, or a hand edit, costs the activity and never the whole
    /// profile: an unknown entry is ignored and the stock still loads and still renders.
    ///
    /// An entry may be a bare string or an object carrying that activity's own PARAMETERS,
    /// so a film-specific strength ships in the profile and not in the code. The bare string
    /// means the defaults.
    ///
    ///     "activities": ["balanceChannels"]
    ///     "activities": [{"name": "balanceChannels", "strength": 0.5, "scope": "frame"}]
    public var activities: [ActivityEntry]?
    /// Prose for a person reading the file: what the stock is and why the file says what it
    /// says. Nothing reads it.
    public var note: String?
    /// A profile that backs a picker row rather than being one. The generic color
    /// negative entry is the only one: the row the user sees is "Color Negative" and its
    /// sidecar value is the literal "generic", so offering the backing file a second time
    /// under its own name would be the same choice twice. Every profile that is not hidden
    /// is offered in the picker.
    public var hidden: Bool?

    /// A dye gamma pair with where it came from. The pair and its source travel together
    /// so a number cannot be read without the sentence that says what it is worth.
    public struct SourcedDyeGamma: Codable, Equatable, Sendable {
        public var r: Double, g: Double, b: Double
        public var source: Source
        public init(r: Double, g: Double, b: Double, source: Source) {
            self.r = r; self.g = g; self.b = b; self.source = source
        }
        public var dyeGamma: DyeGamma { DyeGamma(r: r, g: g, b: b) }

        public struct Source: Codable, Equatable, Sendable {
            /// The sheet, as its maker numbers it, or "measured" for a pair read off a
            /// chart. Shown in Settings.
            public var publication: String
            /// How the pair was read, in words: the fit and the log H window it spans.
            public var method: String
            /// Where the sheet lives on its maker's site. Settings makes the publication a
            /// link to it.
            public var url: String?
            public init(publication: String, method: String, url: String? = nil) {
                self.publication = publication; self.method = method; self.url = url
            }
        }
    }

    /// One declared activity: a name, plus whatever parameters that activity understands.
    ///
    /// Decodes from a bare string OR an object, because the shape has to stay open to a
    /// file somebody else wrote. An unknown KEY inside the object is ignored the same way an
    /// unknown NAME is, which is the whole tolerance contract: a profile from a newer build
    /// degrades to the part this build understands rather than failing to load.
    public struct ActivityEntry: Codable, Equatable, Sendable {
        public var name: String
        /// How far toward the full operator to go, 0 being off and 1 the whole thing.
        /// Absent means the activity's own default.
        public var strength: Double?
        /// What the activity measures over: `frame` or `selection`. Absent means `frame`.
        public var scope: String?

        public init(name: String, strength: Double? = nil, scope: String? = nil) {
            self.name = name; self.strength = strength; self.scope = scope
        }

        private enum CodingKeys: String, CodingKey { case name, strength, scope }

        public init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let bare = try? single.decode(String.self) {
                self.init(name: bare)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(name: try c.decode(String.self, forKey: .name),
                      strength: try? c.decodeIfPresent(Double.self, forKey: .strength),
                      scope: try? c.decodeIfPresent(String.self, forKey: .scope))
        }

        /// Encodes back to the shape it came in: a bare name stays a bare name, so a
        /// profile that carries no parameters never grows any by round tripping.
        public func encode(to encoder: Encoder) throws {
            guard strength != nil || scope != nil else {
                var single = encoder.singleValueContainer()
                try single.encode(name)
                return
            }
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(strength, forKey: .strength)
            try c.encodeIfPresent(scope, forKey: .scope)
        }
    }

    /// The one black and white path. Decided by id rather than by a field: there is exactly
    /// one mono profile, `bw-generic`, and every black and white market name aliases to it.
    public var isMono: Bool { id == ProfileLibrary.monoStockID }
    /// Backs a picker row instead of appearing as one. See `hidden`.
    public var isHidden: Bool { hidden ?? false }

    /// The activities this build understands. Anything else in the file is ignored.
    public enum Activity: String, Sendable, CaseIterable {
        /// Balance each color channel on its own before the tone step. For an UNMASKED
        /// film, where the maker's own guidance is to set each channel's levels separately.
        case balanceChannels
    }
    /// What an activity measures over. A file naming anything else gets `frame`, the same
    /// tolerance an unknown activity name gets.
    public enum ActivityScope: String, Sendable, CaseIterable {
        /// Measured on the frame being developed, which is what every other automatic step
        /// in this app does.
        case frame
        /// Measured once over a selection. Nothing in the kernel does this, so a profile
        /// asking for it renders per frame. Kept so such a file reads unchanged.
        case selection
    }

    /// One activity's parameters with every default filled in, so a caller never has to
    /// know which of them the file happened to set.
    public struct ActivitySettings: Equatable, Sendable {
        public let strength: Double
        public let scope: ActivityScope
        public init(strength: Double = 1, scope: ActivityScope = .frame) {
            self.strength = strength
            self.scope = scope
        }
    }

    /// Whether this stock asks for the per-channel balance. See `DevelopMath+Balance.swift`.
    var declares: Set<Activity> {
        Set((activities ?? []).compactMap { Activity(rawValue: $0.name) })
    }
    public var balancesChannels: Bool { declares.contains(.balanceChannels) }

    /// The parameters this profile sets for one activity, defaults filled in, or nil when it
    /// does not declare that activity at all.
    ///
    /// A strength outside 0...1 is CLAMPED rather than refused, for the same reason an
    /// unknown name is ignored: a hand-edited or newer file must degrade, never crash the
    /// kernel. The first matching entry wins if a file lists one twice.
    public func settings(for activity: Activity) -> ActivitySettings? {
        guard let entry = (activities ?? []).first(where: { $0.name == activity.rawValue }) else {
            return nil
        }
        let raw = entry.strength ?? 1
        let strength = raw < 0 ? 0 : (raw > 1 ? 1 : raw)
        let scope = entry.scope.flatMap(ActivityScope.init(rawValue:)) ?? .frame
        return ActivitySettings(strength: strength, scope: scope)
    }

    /// The balance's parameters, or nil when this stock does not ask for it.
    public var channelBalanceSettings: ActivitySettings? { settings(for: .balanceChannels) }
    /// The gate is "has a curve": a stock with its own dye gammas,
    /// read off its maker's sheet or measured off a chart, goes through one path. A color
    /// stock without them renders on the generic stock's, which is a stated borrow rather
    /// than a claim about the emulsion.
    public var isDatasheet: Bool { datasheetDyeGamma != nil }
    /// The pair was measured rather than published, so the picker says so instead of
    /// crediting a sheet nobody printed.
    public var isMeasured: Bool { datasheetDyeGamma?.source.publication.lowercased() == "measured" }
    public var dyeGamma: DyeGamma {
        isMono ? .neutral : (datasheetDyeGamma?.dyeGamma ?? .neutral)
    }
}

struct AliasEntry: Codable {
    var to: String
    /// The emulsion is the target's, the CHEMISTRY is not. A remjet-removed Vision3 shot
    /// and developed in C-41 renders through the ECN-2 stock's published sheet because
    /// that sheet is the emulsion, and the picker has to be able to say so rather than
    /// presenting it as the same thing.
    var crossProcessed: Bool?
    /// What this MARKET NAME asks the develop kernel to do, over and above what its target
    /// profile already asks for.
    ///
    /// A real profile file for the market name would be a trap: a real file SHADOWS the
    /// alias, and `resolveFilm` reads `crossProcessed` only when nothing shadows it, so
    /// shipping `cinestill-800t.json` would silently switch off the cross-process flag for
    /// CineStill 800T while looking like it only added a balance.
    ///
    /// Carrying the activity here instead keeps the target's numbers single-sourced, which
    /// matters because the target IS the emulsion: CineStill 800T is remjet-removed Vision3
    /// 500T, and nothing about the balance changes that. The same shape is available to
    /// CineStill 50D and the three Reflx AHU aliases and is deliberately not used by them.
    var activities: [FilmProfile.ActivityEntry]?
}
struct AliasFile: Codable { var films: [String: AliasEntry] }

public struct ProfileLibrary: Sendable {
    /// What the literal "generic" resolves through, and the engine's never-fail fallback
    /// for a stock id it does not know.
    ///
    /// It carries no dye gammas, so it renders on neutral 1/1/1, equal channel contrast: no
    /// film opinion for a film nobody named.
    ///
    /// The picker row and the sidecar value are both the literal "generic", so a sidecar
    /// renders through this backing profile with no migration.
    public static let genericStockID = "unknown-color-negative"
    public static let monoStockID = "bw-generic"

    public let films: [String: FilmProfile]
    /// Which of `films` came from the user's own profile folder rather than from the
    /// bundled package. The merge is by id, so once an imported profile overlays a shipped
    /// stock the two are indistinguishable by inspection: this set is the only record of
    /// where a profile came from, and it is what lets the Stock picker list a person's own
    /// presets in their own group instead of scattering them among the shipped stocks.
    public let userFilmIDs: Set<String>
    public let aliases: [String: String]
    /// Aliases whose emulsion is the target's but whose process is not: a remjet-removed
    /// Vision3 shot and developed in C-41. The sheet is right, the chemistry is not, and
    /// the picker says so.
    public let crossProcessedAliases: Set<String>
    /// Activities declared by a MARKET NAME rather than by a profile file, keyed by
    /// the alias id. Merged onto the resolved profile by `resolveFilm`, alias entries
    /// winning by name so a market name can add a behavior or override one of its
    /// target's without the target losing it for everybody else.
    public let aliasActivities: [String: [FilmProfile.ActivityEntry]]
    public let root: URL

    public struct Resolved: Equatable, Sendable {
        public let profile: FilmProfile
        public let requested: String
        public let fellBackToGeneric: Bool
        /// Reached through an alias whose emulsion is the target's but whose process is
        /// not (CineStill 800T, CineStill 50D, the three Reflx Lab AHU stocks). The develop
        /// pass does not act on it. The picker states it.
        public let crossProcessed: Bool
        /// The dye gammas of the generic stock, carried so a stock with none of its own
        /// can borrow them.
        let genericDyeGamma: DyeGamma

        /// What the kernel actually normalizes with. Black and white uses none. A stock
        /// with gammas of its own uses those, from its published characteristic curve or
        /// from a chart. A stock with none borrows the generic stock's, which are
        /// neutral 1/1/1 because the generic stock carries none. The borrow
        /// stays rather than a literal neutral here, so the generic stock is the one place
        /// that says what an unnamed color negative renders on.
        public var dyeGamma: DyeGamma {
            if profile.isMono { return .neutral }
            return profile.datasheetDyeGamma?.dyeGamma ?? genericDyeGamma
        }
    }

    public init(root: URL) throws {
        self.root = root
        let dec = JSONDecoder()
        func loadAll<T: Decodable>(_ sub: String, _: T.Type) throws -> [String: T] {
            let dir = root.appendingPathComponent(sub)
            var out: [String: T] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".json") {
                let v = try dec.decode(T.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
                out[String(name.dropLast(5))] = v
            }
            return out
        }
        var loadedFilms = try loadAll("films", FilmProfile.self)
        // A profile the user imported wins over the shipped one with the same id, which is
        // what makes a shared profile take effect. A broken file
        // in that folder is skipped rather than taking the whole library down with it: the
        // shipped stocks have to keep working whatever somebody dropped in there.
        var loadedUserIDs: Set<String> = []
        if let userDir = try? ProfilePackage.userProfilesDirectory(),
           let names = try? FileManager.default.contentsOfDirectory(atPath: userDir.path) {
            for name in names where name.hasSuffix(".json") {
                guard let data = try? Data(contentsOf: userDir.appendingPathComponent(name)),
                      let (_, profile) = try? ProfilePackage.decode(data) else { continue }
                loadedFilms[profile.id] = profile
                loadedUserIDs.insert(profile.id)
            }
        }
        films = loadedFilms
        userFilmIDs = loadedUserIDs
        let a = try dec.decode(AliasFile.self, from: Data(contentsOf: root.appendingPathComponent("aliases.json")))
        aliases = a.films.mapValues { $0.to }
        crossProcessedAliases = Set(a.films.filter { $0.value.crossProcessed == true }.keys)
        aliasActivities = a.films.compactMapValues { $0.activities }
    }

    /// The shipped profiles. Inside FilmPositive.app they sit at `Contents/Resources/profiles`,
    /// copied there by `tools/bundle-app.sh`; that is checked first because SwiftPM's
    /// `Bundle.module` accessor looks for the resource bundle at the app's ROOT and then at
    /// the absolute build path on the machine that built it, and `fatalError`s when both are
    /// missing, which is every machine that is not the build host. The SwiftPM resource
    /// bundle stays the path for `swift run` and the tests.
    public static func bundled() throws -> ProfileLibrary {
        if let inApp = Bundle.main.resourceURL?.appendingPathComponent("profiles"),
           FileManager.default.fileExists(atPath: inApp.appendingPathComponent("aliases.json").path) {
            return try ProfileLibrary(root: inApp)
        }
        guard let url = Bundle.module.resourceURL?.appendingPathComponent("profiles") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ProfileLibrary(root: url)
    }

    /// Mirrors the TS engine: "generic" is the generic stock, aliases resolve, and an
    /// unknown id renders through the generic profile rather than failing.
    public func resolveFilm(_ requested: String) -> Resolved {
        var id = requested == "generic" ? Self.genericStockID : requested
        // A real profile file wins over an alias. Applied first, the alias
        // `kodak-portra-400 -> ektacolor-pro-400` points at a name with no file, and every
        // Portra 400 frame would render through the generic path instead of its own profile.
        let generic = films[Self.genericStockID]!
        let genericGamma = generic.dyeGamma
        // Read before the alias is applied and only when no real profile file shadows it,
        // because a flagged alias that never fires has not cross-processed anything.
        let crossProcessed = films[id] == nil && crossProcessedAliases.contains(id)
        // Read under the SAME condition as the flag above and for the same reason: a market
        // name only gets to say anything when it is actually acting as a market name. A real
        // profile file shadowing the id means the alias never fired, so neither its flag nor
        // its activities apply.
        let fromAlias = films[id] == nil ? aliasActivities[id] : nil
        if let p = films[id] {
            return Resolved(profile: p, requested: requested, fellBackToGeneric: false,
                            crossProcessed: crossProcessed, genericDyeGamma: genericGamma)
        }
        if let to = aliases[id] { id = to }
        if let p = films[id] {
            return Resolved(profile: Self.merging(fromAlias, onto: p), requested: requested,
                            fellBackToGeneric: false,
                            crossProcessed: crossProcessed, genericDyeGamma: genericGamma)
        }
        return Resolved(profile: Self.merging(fromAlias, onto: generic), requested: requested,
                        fellBackToGeneric: true,
                        crossProcessed: crossProcessed, genericDyeGamma: genericGamma)
    }

    /// A market name's activities laid over its target's, by NAME, the alias winning.
    ///
    /// A union rather than a replacement, because the target is the emulsion: if Vision3
    /// 500T ever declares something, remjet-removed 500T sold as CineStill 800T is still
    /// that emulsion and should inherit it. Overriding one entry by name is the escape
    /// hatch for the case where it differs. Nothing shipped exercises either half
    /// today, since no target profile declares an activity, which is exactly why both halves
    /// are tested rather than assumed.
    ///
    /// Returns the profile untouched when the alias declares nothing, so the ordinary path
    /// allocates and compares nothing new.
    static func merging(_ fromAlias: [FilmProfile.ActivityEntry]?, onto profile: FilmProfile) -> FilmProfile {
        guard let fromAlias, !fromAlias.isEmpty else { return profile }
        var merged = profile
        let overridden = Set(fromAlias.map(\.name))
        merged.activities = (profile.activities ?? []).filter { !overridden.contains($0.name) } + fromAlias
        return merged
    }

    public var mono: FilmProfile { films[Self.monoStockID]! }

    /// The white density a stock with no curve of its own takes: the median of
    /// `FilmProfile.whiteDensity` over the 20 digitized curves at install time (1.142).
    public static let genericWhiteDensity = 1.14

    /// The Stretch control's reference for a stock id as a sidecar names it: the resolved
    /// stock's own `whiteDensity`, else `genericWhiteDensity`.
    ///
    /// A cross-processed alias takes the generic value even though its target has a curve,
    /// because a cine stock's curve describes its own process and not the one it was
    /// cross-processed in. Mono follows the same rule as color: its own curve if digitized,
    /// else generic.
    public func whiteDensity(for stockID: String) -> Double {
        let r = resolveFilm(stockID)
        guard !r.crossProcessed, let own = r.profile.whiteDensity, own.isFinite, own > 0 else {
            return Self.genericWhiteDensity
        }
        return own
    }

    /// A market film name as Tether records it ("Kodak Portra 400", maker "Kodak") to a
    /// stock id: the slug of the name, then maker plus name, matched against the profile
    /// files and the aliases (an alias resolves to its target id even when that target has
    /// no profile file yet). Nil when nothing matches. Nothing applies this on its own: a
    /// frame opens on the generic stock whatever its film name says, and the person picks.
    public func stockID(forFilmName name: String?, maker: String? = nil) -> String? {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var candidates = [Self.slug(name)]
        if let maker, !maker.isEmpty, !Self.slug(name).hasPrefix(Self.slug(maker)) { candidates.append(Self.slug(maker + " " + name)) }
        for c in candidates {
            if films[c] != nil { return c }
            if let to = aliases[c] {
                // Prefer an id that actually has a profile. "Kodak Portra 400" aliases to
                // the Eastman name `ektacolor-pro-400`, which ships no file, while the
                // profile digitized from Kodak's own E-4050 sheet is `kodak-portra-400`.
                // Recording the name with no file behind it puts an id in every sidecar
                // that only resolves through a second hop, which is indirection with
                // nothing at the end of it. If neither has a file, the alias target is
                // still the canonical name and is recorded as before.
                if films[to] != nil { return to }
                if let back = aliases.first(where: { $0.value == c && films[$0.key] != nil })?.key { return back }
                return to
            }
        }
        return nil
    }

    /// The develop settings a frame gets on its first develop when the sidecar has none: the
    /// literal "generic" stock, which renders through the generic color negative profile,
    /// whatever film name the capture carries. The name stays with the frame as metadata and
    /// the person picks a stock when they want its curve. (Until 2026-10-06 the name chose the
    /// stock; a wrong or loose name then put a specific stock on a film it was not.)
    public static let genericStockName = "generic"
    public func initialDevelop(capture: CaptureInfo?) -> DevelopSettings {
        let stock = Self.genericStockName
        // Tone `.none` and no look. The film edge search is on by default. A default that
        // applies a tone curve is a default that has an opinion, and the first thing a user
        // sees should be the film and nothing else on top.
        //
        // A stock that needs something unusual declares an ACTIVITY on its profile
        // (`FilmProfile.activities`) and the kernel runs it. It does not reach in and set a
        // tone here, so the default a person first sees is still the same for every
        // film and the Tone row never disagrees with the picture.
        return DevelopSettings(stock: stock, tone: .none, autoBalance: true,
                               base: BaseSettings(mode: .anchor))
    }

    static func slug(_ s: String) -> String {
        let lowered = s.lowercased().replacingOccurrences(of: "&", with: " and ")
        var out = ""; var lastDash = true
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}
