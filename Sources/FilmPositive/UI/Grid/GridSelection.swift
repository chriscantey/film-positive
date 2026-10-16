import Foundation

/// The grid's selection semantics as a pure value transform, so they can be tested
/// without a window. They are the Finder rules, not an approximation:
///
/// - plain click replaces the selection with the clicked item and moves the anchor to it
/// - command click toggles that one item and moves the anchor to it
/// - shift click replaces the selection with the run from the anchor to the clicked item
///   and leaves the anchor alone, so a second shift click re-ranges from the same place
/// - command shift click unions that run into the existing selection, anchor unchanged
/// - select all takes every item in the current order and anchors on the first
///
/// Generic over the identifier so the tests can use integers and the view can use
/// `Frame.ID`.
enum GridSelection<ID: Hashable> {

    struct Modifiers: OptionSet, Sendable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }
        static var command: Modifiers { Modifiers(rawValue: 1 << 0) }
        static var shift: Modifiers { Modifiers(rawValue: 1 << 1) }
    }

    /// The selection plus the anchor the next shift click ranges from. The anchor is
    /// deliberately separate from the selection: a range click does not move it.
    struct State: Equatable {
        var selected: Set<ID>
        var anchor: ID?

        init(selected: Set<ID> = [], anchor: ID? = nil) {
            self.selected = selected
            self.anchor = anchor
        }
    }

    /// The new state after clicking `id` while `modifiers` are held.
    static func click(_ id: ID, order: [ID], state: State, modifiers: Modifiers) -> State {
        let shift = modifiers.contains(.shift)
        let command = modifiers.contains(.command)

        if shift, let anchor = state.anchor, let run = run(from: anchor, to: id, in: order) {
            // A range click keeps the anchor so repeated shift clicks pivot on one item.
            return State(selected: command ? state.selected.union(run) : run, anchor: anchor)
        }
        if command {
            var next = state.selected
            if next.contains(id) { next.remove(id) } else { next.insert(id) }
            return State(selected: next, anchor: id)
        }
        // Plain click, and the fallback when a shift click has no usable anchor.
        return State(selected: [id], anchor: id)
    }

    static func selectAll(order: [ID], state: State) -> State {
        State(selected: Set(order), anchor: state.anchor ?? order.first)
    }

    static func clear() -> State { State() }

    /// Drops anything no longer present, used when the folder list changes underneath.
    static func prune(_ state: State, to order: [ID]) -> State {
        let live = Set(order)
        let anchor = state.anchor.flatMap { live.contains($0) ? $0 : nil }
        return State(selected: state.selected.intersection(live), anchor: anchor)
    }

    /// The inclusive run between two items in display order, in either direction.
    private static func run(from a: ID, to b: ID, in order: [ID]) -> Set<ID>? {
        guard let i = order.firstIndex(of: a), let j = order.firstIndex(of: b) else { return nil }
        let lower = min(i, j), upper = max(i, j)
        return Set(order[lower...upper])
    }
}
