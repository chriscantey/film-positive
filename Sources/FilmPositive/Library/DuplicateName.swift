import Foundation

/// Finder's duplicate naming, without the word "duplicate": the copy
/// of `IMG_0001.CR2` is `IMG_0001-2.CR2`, then `-3`, `-4`, as many as you like.
///
/// Pure and folder-listing driven so the rule can be asserted without a disk: every
/// decision it makes is a function of the names already in the folder.
///
/// Two rules, and the second one is the only interesting one.
///
/// 1. The first FREE number from 2 upward, never the next one after the highest. A folder
///    holding `-2` and `-4` gets a `-3`, because `-4` is somebody's file and the counter
///    is not allowed to reuse a name that exists.
///
/// 2. The counter runs on the BASE name, so duplicating `IMG_0001-2` gives `IMG_0001-3`
///    rather than `IMG_0001-2-2`. That needs a rule for a name that legitimately ends in
///    `-<digits>` (`DSC-2024`, `roll-3`), and here it is: **a trailing `-N` is treated as
///    ours only when the un-suffixed sibling is in the same folder.** Duplicating
///    `roll-3.CR2` in a folder that has no `roll.CR2` therefore gives `roll-3-2.CR2`,
///    which keeps the original name intact. In a folder that does have `roll.CR2` the
///    `-3` is read as a counter, so the answer comes from rule 1 and is `roll-2.CR2`:
///    the first FREE number, not the one after the highest.
enum DuplicateName {
    /// The stem the counter runs on. See rule 2 above.
    ///
    /// `stems` is every stem in the folder, lowercased, extension dropped: a sibling is a
    /// NAME in the folder whatever it is attached to, so a lone `IMG_0001.xmp` counts.
    static func base(of stem: String, in stems: Set<String>) -> String {
        guard let dash = stem.lastIndex(of: "-") else { return stem }
        let tail = stem[stem.index(after: dash)...]
        guard !tail.isEmpty, tail.allSatisfy(\.isNumber) else { return stem }
        let head = String(stem[stem.startIndex..<dash])
        guard !head.isEmpty, stems.contains(head.lowercased()) else { return stem }
        return head
    }

    /// The file name for a duplicate of `stem.ext`, given every file name in the folder.
    ///
    /// The extension is carried through verbatim, so a `.CR2` duplicates to a `.CR2` and
    /// never to a `.cr2`. Occupancy is judged on the STEM and case-insensitively, because
    /// the sidecar shares the stem and because the volume may well be case-insensitive:
    /// a free name has to be free for the raw and for the `.xmp` beside it at once.
    static func next(for stem: String, extension ext: String, among names: [String]) -> String {
        let stems = Set(names.map { ($0 as NSString).deletingPathExtension.lowercased() })
        let base = base(of: stem, in: stems)
        var n = 2
        while stems.contains("\(base)-\(n)".lowercased()) { n += 1 }
        let name = "\(base)-\(n)"
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    /// The same rule against a real folder. The listing is read once per duplicate, which
    /// is what makes duplicating a selection of forty frames pick forty distinct names
    /// even though each copy lands between two reads.
    static func nextURL(for url: URL) throws -> URL {
        let dir = url.deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let stem = url.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent(next(for: stem, extension: url.pathExtension, among: names))
    }
}
