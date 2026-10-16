import Foundation

/// The inspector's parts that fold from their title, with a small icon beside a closed one.
///
/// The five sections (Develop, Frame, Metadata, Histogram, Enhance), and inside Enhance its
/// Looks title and its groups. Every section folds the same way, from its title, and none
/// carries a header switch.
///
/// The raw value is what `Preferences` stores, so it must never change. The DISPLAYED name
/// is `title`, which for the Enhance groups is `EnhanceControl.Group.rawValue`, so a group
/// renamed on screen (the `light` id shows "Light") keeps its stored fold.
enum InspectorSection: String, CaseIterable, Sendable {
    /// `vignette` is appended, so every id stored before it keeps its meaning.
    case develop, frame, enhance, looks, light, color, detail, histogram, metadata, vignette
    /// Appended after `vignette` for the same reason: the two tone groups that sit between
    /// Color and Detail on screen.
    case levels, curves

    /// The name on screen, and the first half of the title button's accessibility label.
    var title: String {
        switch self {
        case .develop: return "Develop"
        case .frame: return "Frame"
        case .enhance: return "Enhance"
        case .looks: return "Looks"
        case .light: return EnhanceControl.Group.tone.rawValue
        case .color: return EnhanceControl.Group.colour.rawValue
        case .detail: return EnhanceControl.Group.detail.rawValue
        case .histogram: return "Histogram"
        case .metadata: return "Metadata"
        case .vignette: return EnhanceControl.Group.vignette.rawValue
        case .levels: return "Levels"
        case .curves: return "Curves"
        }
    }

    /// The fold an Enhance group's title toggles.
    static func group(_ group: EnhanceControl.Group) -> InspectorSection {
        switch group {
        case .tone: return .light
        case .colour: return .color
        case .detail: return .detail
        case .vignette: return .vignette
        }
    }
}

/// Which inspector parts are folded, as a value. Pure, so the rule has tests without a
/// window: the default, a toggle flips one part and only that part, and the stored form
/// round trips.
///
/// THE DEFAULT: Develop, Frame, Metadata and Histogram open, Enhance closed. Inside Enhance,
/// Looks and every group are open, so turning Enhance on shows all of it. Someone who
/// rearranges the panel keeps their arrangement in every later session.
///
/// Stored as every part's state BY ID, open or closed, rather than as one set. A part the
/// stored form does not name takes the default, so a part added in a later build starts
/// open unless `defaultClosed` names it, for someone with stored folds as much as for
/// someone without. And a change to the default never moves a part someone already has
/// stored, so it reaches fresh installs only. Remembered app-wide in
/// `Preferences.inspectorFold`.
struct SectionFold: Equatable, Sendable {
    private(set) var closed: Set<InspectorSection>

    /// The parts closed when nothing is stored.
    static let defaultClosed: Set<InspectorSection> = [.enhance]

    init(closed: Set<InspectorSection> = SectionFold.defaultClosed) { self.closed = closed }

    /// From the stored form. An id this build does not know is dropped rather than kept,
    /// since there is nothing on screen it could fold, and a part not named is the default.
    init(stored: [String: Bool]?) {
        let stored = stored ?? [:]
        closed = Set(InspectorSection.allCases.filter { section in
            !(stored[section.rawValue] ?? !Self.defaultClosed.contains(section))
        })
    }

    /// The stored form: every part this build knows, `true` for open.
    var stored: [String: Bool] {
        Dictionary(uniqueKeysWithValues: InspectorSection.allCases.map { ($0.rawValue, isOpen($0)) })
    }

    func isOpen(_ section: InspectorSection) -> Bool { !closed.contains(section) }

    mutating func toggle(_ section: InspectorSection) {
        if closed.contains(section) { closed.remove(section) } else { closed.insert(section) }
    }

    func toggled(_ section: InspectorSection) -> SectionFold {
        var out = self
        out.toggle(section)
        return out
    }

    /// What the title button says to Accessibility: the name, then what a press does.
    static func accessibilityLabel(_ title: String, open: Bool) -> String {
        "\(title), \(open ? "collapse" : "expand")"
    }

    /// The hover help, the same promise in words for a pointer.
    static func help(_ title: String, open: Bool) -> String {
        "\(open ? "Hide" : "Show") \(title)"
    }

    /// Drawn beside a CLOSED title only. An open title carries nothing extra.
    static let chevron = "chevron.right"
}
