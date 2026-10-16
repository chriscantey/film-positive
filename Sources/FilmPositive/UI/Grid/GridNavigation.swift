import Foundation

/// Keyboard navigation for the grid and the viewer, as a pure value transform so it can
/// be tested without a window. It works the way a gallery works: left and
/// right step one frame in display order, up and down step a row, shift extends the
/// selection from the anchor, and Home and End jump to the ends.
///
/// The cursor is separate from the anchor on purpose. A shift-extend moves the cursor and
/// leaves the anchor where it was, so holding shift and pressing right repeatedly grows
/// one run from the same pivot, which is what Finder does. `GridSelection` owns
/// the same distinction for clicks; this type keeps its own state rather than widening
/// that one, so the click rules and their tests stay untouched.
enum GridNavigation<ID: Hashable> {

    enum Move: Equatable {
        case left, right, up, down, first, last
        /// Page Up and Page Down, this many rows at a time (one screen of them).
        case pageUp(rows: Int), pageDown(rows: Int)
    }

    struct State: Equatable {
        var selected: Set<ID>
        /// Where a shift-extend ranges from.
        var anchor: ID?
        /// The focused frame, the one the arrows move.
        var cursor: ID?

        init(selected: Set<ID> = [], anchor: ID? = nil, cursor: ID? = nil) {
            self.selected = selected
            self.anchor = anchor
            self.cursor = cursor
        }
    }

    /// The state after an arrow (or Home or End) with `columns` frames per row. `extend`
    /// is shift. Returns nil when nothing can move, so a caller can leave the key
    /// unhandled and let the system have it.
    static func move(_ move: Move, order: [ID], state: State, columns: Int, extend: Bool = false) -> State? {
        guard !order.isEmpty else { return nil }
        let last = order.count - 1
        let columns = max(1, columns)

        // With no cursor yet, the first key lands at the end the key points away from, so
        // Right selects the first frame and Left the last.
        let current = (state.cursor ?? state.anchor).flatMap { order.firstIndex(of: $0) }
        guard let i = current else {
            let entry = (move == .left || move == .up || move == .last || Self.isPageUp(move)) ? last : 0
            return applied(target: entry, order: order, state: state, extend: false)
        }

        let target: Int
        switch move {
        case .left: target = i - 1
        case .right: target = i + 1
        // A row step that would leave the grid goes to the nearest end instead of
        // refusing, so the last short row is always reachable from the row above it.
        case .up: target = i - columns < 0 ? 0 : i - columns
        case .down: target = i + columns > last ? last : i + columns
        case .first: target = 0
        case .last: target = last
        // Like a row step, a page that would leave the grid stops at its end.
        case .pageUp(let rows): target = max(0, i - columns * max(1, rows))
        case .pageDown(let rows): target = min(last, i + columns * max(1, rows))
        }
        guard target >= 0, target <= last, target != i else { return nil }
        return applied(target: target, order: order, state: state, extend: extend)
    }

    private static func isPageUp(_ m: Move) -> Bool { if case .pageUp = m { return true } else { return false } }

    private static func applied(target: Int, order: [ID], state: State, extend: Bool) -> State {
        let id = order[target]
        guard extend, let anchor = state.anchor, let a = order.firstIndex(of: anchor) else {
            return State(selected: [id], anchor: id, cursor: id)
        }
        let run = Set(order[min(a, target)...max(a, target)])
        return State(selected: run, anchor: anchor, cursor: id)
    }

    /// Drops a cursor or anchor that is no longer on screen.
    static func prune(_ state: State, to order: [ID]) -> State {
        let live = Set(order)
        return State(selected: state.selected.intersection(live),
                     anchor: state.anchor.flatMap { live.contains($0) ? $0 : nil },
                     cursor: state.cursor.flatMap { live.contains($0) ? $0 : nil })
    }

    /// How many cells a `LazyVGrid` with `GridItem(.adaptive(minimum:))` puts in a row.
    /// The grid fits as many columns of at least `cellWidth` as the content width allows,
    /// which is what this computes, so the arrow keys move by the row the eye sees.
    static func columns(width: Double, cellWidth: Double, spacing: Double, padding: Double) -> Int {
        let content = width - 2 * padding
        guard content > 0, cellWidth > 0 else { return 1 }
        return max(1, Int((content + spacing) / (cellWidth + spacing)))
    }
}
