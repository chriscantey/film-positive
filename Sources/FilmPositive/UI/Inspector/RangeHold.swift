import Foundation

/// What an enhance row's track SPANS, once someone has reached past the normal range.
///
/// A span that is a pure function of the value (-1...1 at rest, growing to the next whole
/// unit that contains the value) shrinks back the instant the value returns inside. A typed
/// 2.5 gives a -3...3 track, and dragging back to 0.4 would snap the track to -1...1 under
/// the pointer, moving the fill and the scale mid-gesture.
///
/// So a row that has been GROWN by an edit keeps its grown span, symmetric about 0, even with
/// the value back inside, until the person clicks away from that row or the inspector moves to
/// another frame. Then it drops to whatever contains the value, which is -1...1 unless the
/// value is still outside.
///
/// Only an EDIT in this row grows the hold (a drag, an arrow, a typed number). A value that
/// arrives from somewhere else, another frame, Auto Enhance, undo, still gets a span that
/// contains it, but it is not held, because nobody reached for it here.
///
/// Plain value type with no SwiftUI so the rule is asserted rather than described.
struct RangeHold: Equatable {
    /// The resting half span, 1 for every enhance control.
    let nominal: Double
    /// The grown half span being held, or nil when nothing is held.
    private(set) var held: Double?

    init(nominal: Double = EnhanceControl.range.upperBound) {
        self.nominal = nominal
    }

    /// The half span that contains a value: the resting bound, or the next whole unit past it.
    static func bound(containing value: Double, nominal: Double) -> Double {
        guard value.isFinite else { return nominal }
        return max(nominal, abs(value).rounded(.up))
    }

    /// Someone set this row to `value` from the row itself. Grows the hold if the value is past
    /// what the row normally spans. Never shrinks it.
    mutating func edited(to value: Double) {
        let need = Self.bound(containing: value, nominal: nominal)
        guard need > nominal else { return }
        held = max(held ?? nominal, need)
    }

    /// A click away from the row, or a different frame shown.
    mutating func release() { held = nil }

    var isHolding: Bool { held != nil }

    /// The span to draw and drag over for this value.
    func span(for value: Double) -> ClosedRange<Double> {
        let b = max(Self.bound(containing: value, nominal: nominal), held ?? nominal)
        return -b...b
    }

    /// Where the faint ticks go: the normal limits, whenever the span is wider than them.
    func ticks(for value: Double) -> [Double] {
        span(for: value).upperBound > nominal ? [-nominal, nominal] : []
    }
}
