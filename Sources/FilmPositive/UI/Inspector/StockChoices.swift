import Foundation
import FilmPositiveCore

/// The film stock list for the develop section, built from `ProfileLibrary.bundled()`: the
/// stocks with curves, the generic color choice, and the one Black and White choice.
///
/// The entry that is easy to leave out is the last one. A sidecar can name a stock that
/// has no profile file, because `initialDevelop` records the canonical name from Tether's
/// film field and `resolveFilm` renders it through the generic profile until the profile
/// ships. If that id is absent from the list, a `Picker` with no matching selection draws
/// blank and the first interaction silently rewrites the sidecar to something the user did
/// not pick. So an unknown current stock is carried as its own entry, labeled for what it
/// is, and it disappears from the list as soon as the user chooses something else.
struct StockChoice: Identifiable, Hashable, Sendable {
    enum Kind: Sendable, Hashable {
        case generic
        /// A stock with a curve of its own: dye gammas read off its maker's published
        /// characteristic curve, or `measured` off a chart. The kind says which, because
        /// a measured pair must not be credited to a sheet.
        case curve(measured: Bool)
        case mono
        /// A market name that has no profile of its own and renders through another
        /// stock's. CineStill 50D is remjet-removed Vision3 50D; Ektacolor Pro 400 is what
        /// Eastman calls Portra 400. People shop for these names, so they belong in the
        /// picker even though they carry no numbers we measured.
        ///
        /// `crossProcessed` is the case where the emulsion is the target's and the
        /// chemistry is not: a remjet-free Vision3 shot and souped in C-41.
        case alias(target: String, crossProcessed: Bool)
        /// Offered although its maker publishes nothing we could ship. It renders on
        /// exactly the curves Color Negative renders on, and the kind says that rather
        /// than letting the row imply a profile exists. `balancesChannels` is the activity
        /// the profile declares, which is the whole reason such a row is worth having.
        case noPublishedCurve(balancesChannels: Bool)
        case unprofiled
    }

    let id: String
    let name: String
    let kind: Kind
}

enum StockChoices {
    /// `"generic"` is a literal sidecar value, not a profile id: it means "no
    /// stock-specific claim", which is why it is listed separately from the stock its
    /// numbers happen to come from.
    static let genericID = ProfileLibrary.genericStockName

    /// The mono entry's display name. The sidecar id stays `bw-generic` forever, and only
    /// the WORD is named here. It carries "Negative" so the two entries in the first group
    /// read as a pair.
    static let monoName = "Black & White Negative"

    /// The first group's color entry. Not "Generic": that word is an engine fact about which
    /// curve is used, not something a person picking a film wants to read, and the row it
    /// names is the ordinary path rather than the odd one.
    static let genericName = "Color Negative"

    /// The Stock row's title and leading icon. A plain label: Stock is a choice of film and
    /// opens no sliders.
    static let rowTitle = "Stock"
    static let rowSymbol = "film"

    /// The Stock row's info icon, its hover line and its click popover. Built from
    /// `genericName`, so renaming the entry renames the sentence.
    static let infoHover = "\(genericName) suits most film, because Base removes the film's own color."
    static let infoPopover = "Pick your film when it is listed to use its own curves. Otherwise leave it on \(genericName), and Base takes care of the rest."

    /// One block of the Stock picker, drawn with a `Divider()` between blocks.
    struct StockGroup: Identifiable, Hashable, Sendable {
        enum Role: Sendable, Hashable {
            /// The Multiple placeholder, drawn only while the selection disagrees.
            case mixed
            /// Color Negative and Black & White Negative, always, in that order.
            case basics
            /// Every named shipped stock, by maker, exactly as before.
            case shipped
            /// The person's own imported profiles, from the user profile folder. Absent when
            /// there are none, rather than present and empty.
            case user
        }
        var id: Role { role }
        let role: Role
        let choices: [StockChoice]
    }

    /// The picker's contents as the blocks it draws, which is the shape the view needs and
    /// the shape a test can assert. `list` is this, flattened.
    ///
    /// Three groups with a divider between them. The first is the two
    /// answers that always work, the second is the shipped stocks, and the third is the
    /// person's own imported profiles, which belong together rather than sorted in among
    /// Kodak's own films where they read as ours.
    static func groups(from profiles: ProfileLibrary?, current: String?) -> [StockGroup] {
        var basics: [StockChoice] = [
            StockChoice(id: genericID, name: genericName, kind: .generic)
        ]
        var shipped: [StockChoice] = []
        var user: [StockChoice] = []

        if let profiles {
            let userIDs = profiles.userFilmIDs

            // Stocks with a curve: real entries with a real published source, saying what
            // they are. The kind distinguishes a pair read off a published
            // curve from one measured off a chart. `!isHidden` keeps the first
            // group's BACKING profile out of the list: it is a real datasheet-shaped entry
            // and would otherwise show up as a second color negative choice under a
            // different name and a different id. One row, one id.
            let datasheet = profiles.films.values
                .filter { $0.isDatasheet && !$0.isHidden }
            shipped += datasheet.filter { !userIDs.contains($0.id) }
                .map { StockChoice(id: $0.id, name: $0.name, kind: .curve(measured: $0.isMeasured)) }
            user += datasheet.filter { userIDs.contains($0.id) }
                .map { StockChoice(id: $0.id, name: $0.name, kind: .curve(measured: $0.isMeasured)) }

            // Stocks offered although their maker publishes no curve. Harman Switch
            // Azure is the first: no characteristic curve exists for it, so it carries no
            // numbers and renders on the generic stock's neutral gammas. What earns it a
            // row is the ACTIVITY it declares, which an alias would have nowhere to carry.
            // Every profile that is not hidden is offered. The two exclusions below are the
            // entries already in the list above, which would otherwise appear twice.
            let listed = profiles.films.values
                .filter { !$0.isHidden && !$0.isDatasheet && !$0.isMono }
            func listedChoice(_ f: FilmProfile) -> StockChoice {
                StockChoice(id: f.id, name: f.name,
                            kind: .noPublishedCurve(balancesChannels: f.balancesChannels))
            }
            shipped += listed.filter { !userIDs.contains($0.id) }.map(listedChoice)
            user += listed.filter { userIDs.contains($0.id) }.map(listedChoice)

            // Market names people actually shop for, which have no profile of their own.
            //
            // Four filters, and each removes a different kind of noise. An alias that HAS
            // a profile file is already in the list above, which is what excludes the
            // reciprocal pairs the two-way resolution needs. An alias whose target
            // resolves to nothing real would be an entry that renders through the standard
            // path under a specific name, which is worse than not offering it. And the
            // technical `-remjet-removed` ids arrive from Tether metadata, and nobody picks
            // one from a menu.
            shipped += profiles.aliases
                .filter { alias, target in
                    profiles.films[alias] == nil
                        && !alias.hasSuffix("-remjet-removed")
                        && target != ProfileLibrary.monoStockID
                        && profiles.films[target] != nil
                        && !(profiles.films[target]?.isMono ?? true)
                }
                .map { alias, target in
                    StockChoice(id: alias, name: prettify(alias), kind: aliasKind(profiles, alias, target))
                }

            if profiles.films[ProfileLibrary.monoStockID] != nil {
                basics.append(StockChoice(id: ProfileLibrary.monoStockID, name: monoName, kind: .mono))
            }
        } else {
            // Without the bundle there is still a correct first group: the two ids the
            // engine guarantees. Showing an empty picker would read as "this frame has no
            // stock".
            basics.append(StockChoice(id: ProfileLibrary.monoStockID, name: monoName, kind: .mono))
        }

        shipped = grouped(shipped)
        user = grouped(user)

        let known = basics.map(\.id) + shipped.map(\.id) + user.map(\.id)
        if let current, !known.contains(current) {
            // A sidecar that names a stock the picker does not offer has to stay selectable
            // or the picker draws blank and the first interaction rewrites it. It is
            // carried as what it is.
            if let profiles, let target = profiles.aliases[current], profiles.films[target] != nil {
                shipped.append(StockChoice(id: current, name: prettify(current),
                                           kind: aliasKind(profiles, current, target)))
            } else {
                shipped.append(StockChoice(id: current, name: prettify(current), kind: .unprofiled))
            }
        }

        var out = [StockGroup(role: .basics, choices: basics)]
        if !shipped.isEmpty { out.append(StockGroup(role: .shipped, choices: shipped)) }
        if !user.isEmpty { out.append(StockGroup(role: .user, choices: user)) }
        return out
    }

    /// Every choice the picker offers, in draw order. The flattening of `groups`, kept
    /// because the tooltip and the checks want one list and not the blocks.
    static func list(from profiles: ProfileLibrary?, current: String?) -> [StockChoice] {
        groups(from: profiles, current: current).flatMap(\.choices)
    }

    private static func aliasKind(_ profiles: ProfileLibrary, _ alias: String, _ target: String) -> StockChoice.Kind {
        .alias(target: profiles.films[target]?.name ?? prettify(target),
               crossProcessed: profiles.crossProcessedAliases.contains(alias))
    }

    /// Generic first, then every stock of one maker together (Kodak, Fujifilm, CineStill,
    /// Lomography, anything else), natural order within a maker, Black & White last, and
    /// anything unprofiled just before it.
    static func grouped(_ choices: [StockChoice]) -> [StockChoice] {
        func rank(_ c: StockChoice) -> Int {
            switch c.kind {
            case .generic: return 0
            case .mono: return 9
            case .unprofiled: return 8
            default: break
            }
            let n = c.name.lowercased()
            if n.hasPrefix("kodak") { return 1 }
            if n.hasPrefix("fuji") { return 2 }
            if n.hasPrefix("cinestill") { return 3 }
            if n.hasPrefix("lomography") { return 4 }
            return 5
        }
        return choices.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            if ra != rb { return ra < rb }
            if ra == 0 || ra >= 8 { return a.offset < b.offset }
            return a.element.name.localizedStandardCompare(b.element.name) == .orderedAscending
        }.map(\.element)
    }

    /// "ektacolor-pro-400" reads as "Kodak Ektacolor Pro 400" rather than as a slug. Kodak
    /// market names that do not carry the maker get it, so they sort with the rest of Kodak.
    static func prettify(_ id: String) -> String {
        let words = id.split(separator: "-")
            .map { part -> String in
                if part.allSatisfy(\.isNumber) { return String(part) }
                // "Lomography CN 400" reads as "Lomography 400".
                if part == "cn" { return "" }
                if part == "cinestill" { return "CineStill" }
                // An initialism nobody writes in lower case. "ahu" is the anti-halation
                // undercoat Reflx Lab uses in place of remjet, and it is part of the
                // product's printed name.
                if part == "ahu" { return "AHU" }
                // A speed with its balance letter: 250d, 800t, 320d. The letter is part of
                // the manufacturer's own name (Vision3 250D, CineStill 800T), so it is
                // capitalised rather than left as the slug wrote it.
                if part.first?.isNumber == true { return part.uppercased() }
                return part.prefix(1).uppercased() + part.dropFirst()
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let kodakFamilies = ["ektacolor", "ektar", "gold", "portra", "ultramax", "vision3", "colorplus", "pro image", "ektachrome"]
        if kodakFamilies.contains(where: { id.hasPrefix($0) }) { return "Kodak " + words }
        return words
    }
}
