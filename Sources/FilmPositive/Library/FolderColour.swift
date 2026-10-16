import Foundation
import SwiftUI
import AppKit

/// A folder's color label, which IS its Finder color tag.
///
/// The app stores nothing. The color is the folder's own `tagNames` resource value, the
/// same list Finder reads and writes, and a color set in either place shows in the other.
///
/// The seven names are Finder's own default color tags. Finder treats tag names without
/// regard to case, so the match here does too.
enum FolderColour: String, CaseIterable, Identifiable, Sendable {
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"
    case gray = "Gray"

    var id: String { rawValue }

    /// The Finder tag name, which is also the menu item's title.
    var tagName: String { rawValue }

    init?(tag: String) {
        guard let match = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(tag) == .orderedSame }) else { return nil }
        self = match
    }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }

    // MARK: the tag list, as pure functions

    /// The color a tag list carries: the FIRST color tag in it, or nil. A folder can hold
    /// more than one color tag if someone set them in Finder, and Finder then draws several
    /// dots. The sidebar shows one, so it takes the first, which is the one a set from here
    /// replaces in place.
    static func colour(in tags: [String]) -> FolderColour? {
        tags.lazy.compactMap(FolderColour.init(tag:)).first
    }

    /// The tag list with its color set to `colour`, every other tag kept in its order.
    ///
    /// The first existing color tag is replaced where it stands, and any further color
    /// tags are dropped, so the folder ends up with exactly one color. With no color there
    /// before, the new one is appended. `nil` removes every color tag and nothing else.
    /// A non-color tag is never touched, whatever it is called.
    static func tags(_ tags: [String], setting colour: FolderColour?) -> [String] {
        var out: [String] = []
        var placed = false
        for tag in tags {
            guard FolderColour(tag: tag) != nil else { out.append(tag); continue }
            if !placed, let colour {
                out.append(colour.tagName)
            }
            placed = true
        }
        if !placed, let colour { out.append(colour.tagName) }
        return out
    }

    // MARK: the folder on disk

    /// The folder's tags as they are on disk NOW.
    ///
    /// Through a fresh URL on purpose. A URL caches resource values on the underlying object
    /// it shares with every copy, so the session's stored `url` would keep answering with
    /// whatever it read first, and a color changed in Finder while the app runs would never
    /// show. A URL built from the path has no cache.
    static func readTags(_ url: URL) -> [String] {
        let fresh = URL(fileURLWithPath: url.path, isDirectory: true)
        return (try? fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    static func read(_ url: URL) -> FolderColour? { colour(in: readTags(url)) }

    /// Sets the folder's color tag and returns the color now on disk.
    ///
    /// Reads the tags immediately before writing, so a tag added in Finder a moment ago
    /// survives. Written through `NSURL` because `URLResourceValues.tagNames` has no setter.
    /// The access is bracketed in its own start and stop pair: the folder was opened with
    /// security scope when it joined the library, and a balanced pair here neither needs nor
    /// disturbs that one.
    @discardableResult
    static func write(_ colour: FolderColour?, to url: URL) throws -> FolderColour? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fresh = URL(fileURLWithPath: url.path, isDirectory: true)
        let merged = tags(readTags(fresh), setting: colour)
        try (fresh as NSURL).setResourceValue(merged as NSArray, forKey: .tagNamesKey)
        return read(url)
    }

    // MARK: drawing

    /// A filled dot for the menu. A context menu draws a symbol image as a template, which
    /// would make all seven items the same grey, so the dot is a plain bitmap in the color.
    var menuDot: NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
