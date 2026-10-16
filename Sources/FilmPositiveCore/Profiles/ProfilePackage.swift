import Foundation

/// Export and import of one film profile as a single open JSON file, so a stock
/// somebody measures can be used by somebody else.
///
/// The file is the profile's own JSON, canonically encoded: pretty-printed with sorted
/// keys, so two exports of the same profile are byte-equal and a diff between two people's
/// files is readable. It is deliberately NOT a re-encode of the typed `FilmProfile`: a
/// file from an older build or another tool may carry keys this build does not read, and
/// a typed round trip would quietly drop them. So the whole dictionary travels, and the
/// typed view is derived from it.
///
/// Two things are refused on import, both about where numbers come from. A profile that
/// declares itself FilmLab-derived, or that mentions FilmLab anywhere, is rejected: this
/// app ships no vendor-derived spectra and importing one through a share would put them
/// back. A profile whose dye gammas do not say where they came from is rejected too,
/// because a shared number whose origin nobody can state is what the source exists to
/// prevent. A profile with no dye gammas at all carries no number, so it needs no source.
public enum ProfilePackage {

    public static let fileExtension = "fpprofile"

    public enum PackageError: Error, CustomStringConvertible, Equatable {
        case notAnObject
        case missing(String)
        case filmlabDerived(String)
        case noSource
        case unsupportedProcess(String)

        public var description: String {
            switch self {
            case .notAnObject: return "that file is not a film profile (the top level is not an object)"
            case .missing(let key): return "the profile has no \(key)"
            case .filmlabDerived(let why): return "that profile carries data derived from another app (\(why)), which this app does not ship or import"
            case .noSource: return "the profile's dye gammas do not say where they came from"
            case .unsupportedProcess(let p): return "process \(p) is not supported yet"
            }
        }
    }

    /// Canonical bytes for a profile dictionary: sorted keys, pretty printed, one trailing
    /// newline, so the same profile always exports to the same file.
    public static func encode(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    /// The profile in a file, validated. Returns the whole dictionary and the typed view of
    /// it, because a caller needs both: the dictionary to store the file as it arrived, the
    /// typed view to render with.
    @discardableResult
    public static func decode(_ data: Data) throws -> (object: [String: Any], profile: FilmProfile) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PackageError.notAnObject
        }
        for key in ["id", "name"] where (object[key] as? String)?.isEmpty ?? true {
            throw PackageError.missing(key)
        }
        if let gamma = object["datasheetDyeGamma"] {
            let source = (gamma as? [String: Any])?["source"] as? [String: Any]
            for key in ["publication", "method"] where (source?[key] as? String)?.isEmpty ?? true {
                throw PackageError.noSource
            }
        }
        // An older file may still carry a `provenance` block, and its flag is honored when
        // it does.
        if (object["provenance"] as? [String: Any])?["filmlabDerived"] as? Bool == true {
            throw PackageError.filmlabDerived("its provenance says so")
        }
        // The flag is a claim, so the content is checked too: a profile carrying vendor
        // numbers under some other key would pass a flag check and fail this one.
        //
        // Scanned over keys and string values rather than over the raw bytes, and with the
        // sanctioned flag name itself excluded. A plain text search matches
        // `"filmlabDerived": false`, which every honest profile carries, so it rejects
        // exactly the files it is meant to accept.
        if let offender = mentionsFilmLab(object) {
            throw PackageError.filmlabDerived("another app is named in \(offender)")
        }
        if let process = object["process"] as? String {
            let p = process.uppercased()
            if p.contains("E-6") || p.contains("E6") { throw PackageError.unsupportedProcess(process) }
        }
        let profile = try JSONDecoder().decode(FilmProfile.self, from: data)
        return (object, profile)
    }

    /// Any key or string value naming FilmLab, other than the `filmlabDerived` flag that
    /// exists to declare the absence of it.
    static func mentionsFilmLab(_ value: Any, path: String = "") -> String? {
        switch value {
        case let dictionary as [String: Any]:
            for (key, child) in dictionary {
                if key.lowercased() != "filmlabderived", key.lowercased().contains("filmlab") {
                    return path.isEmpty ? key : "\(path).\(key)"
                }
                if let found = mentionsFilmLab(child, path: path.isEmpty ? key : "\(path).\(key)") { return found }
            }
        case let array as [Any]:
            for (i, child) in array.enumerated() {
                if let found = mentionsFilmLab(child, path: "\(path)[\(i)]") { return found }
            }
        case let text as String:
            if text.lowercased().contains("filmlab") { return path.isEmpty ? "a value" : path }
        default:
            return nil
        }
        return nil
    }

    /// Where an imported profile lands: `~/Library/Application Support/Film Positive/Profiles/films`.
    /// Beside the app's other user state, never in a folder of photographs and never in a
    /// sidecar, because a profile is about a stock and not about one frame.
    /// `FP_USER_PROFILES` overrides it, and an empty value turns the folder off entirely.
    /// A test that asserts what the shipped library holds has to be able to say "ignore
    /// whatever is on this machine", or it passes or fails according to files the test
    /// never created.
    public static func userProfilesDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["FP_USER_PROFILES"] {
            guard !override.isEmpty else { throw CocoaError(.fileNoSuchFile) }
            let dir = URL(fileURLWithPath: override)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("Film Positive/Profiles/films", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a profile into the user's own profile folder, replacing one with the same id.
    /// Returns where it landed.
    @discardableResult
    public static func install(_ data: Data, into directory: URL? = nil) throws -> URL {
        let (object, profile) = try decode(data)
        let dir = try directory ?? userProfilesDirectory()
        let url = dir.appendingPathComponent("\(profile.id).json")
        try encode(object).write(to: url, options: .atomic)
        return url
    }

    /// The profile behind an id, as the file on disk holds it, for export. The user's own
    /// folder wins over the shipped bundle, which is the same order the library loads in.
    public static func export(_ id: String, from library: ProfileLibrary) throws -> Data {
        for root in [try? userProfilesDirectory(), library.root.appendingPathComponent("films")] {
            guard let root else { continue }
            let url = root.appendingPathComponent("\(id).json")
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            return try encode(object)
        }
        throw PackageError.missing(id)
    }
}
