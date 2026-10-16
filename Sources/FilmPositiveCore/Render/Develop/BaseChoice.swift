import Foundation
import FilmSidecar

/// The inspector's three-way Base control, as a VIEW of two sidecar fields that already
/// exist. There is no new key, so every sidecar on disk reads
/// straight into it and Film Tether's shared package is untouched.
///
///   Picked  `base.mode == .measured` with a stored pair.
///   Auto    anything else with `autoBalance` on: the film edge, then the picture estimate.
///   None    anything else with `autoBalance` off: neutral, nothing guessed.
///
/// Choosing Auto or None after a pick leaves the pair in the sidecar and only moves the mode
/// to `.anchor`, so Picked can be chosen again without picking again. `BaseResolver` reads the
/// mode for exactly that reason.
public enum BaseChoice: String, CaseIterable, Identifiable, Sendable {
    case auto, picked, none

    public var id: String { rawValue }

    /// The segment's word. The only text the control carries.
    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .picked: return "Picked"
        case .none: return "None"
        }
    }

    /// What one frame's develop layer reads as.
    public init(_ develop: DevelopSettings) {
        if develop.base.mode == .measured, develop.base.ratios != nil {
            self = .picked
        } else {
            self = develop.autoBalance ? .auto : .none
        }
    }

    /// The develop layer with this choice written in, or nil when the sidecar alone cannot
    /// make it: Picked with no stored pair, where the caller starts Pick Base instead.
    ///
    /// Auto and None touch the mode and the switch and nothing else. Picked touches the mode
    /// alone, so a later Auto or None finds the switch where the person left it.
    public func applied(to develop: DevelopSettings) -> DevelopSettings? {
        var d = develop
        switch self {
        case .auto:
            d.base.mode = .anchor
            d.autoBalance = true
        case .none:
            d.base.mode = .anchor
            d.autoBalance = false
        case .picked:
            guard d.base.ratios != nil else { return nil }
            d.base.mode = .measured
        }
        return d
    }
}
