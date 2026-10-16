import Foundation

/// The arithmetic behind returning to the gallery from the closeup, kept apart from
/// the view so it can be tested without one.
enum GalleryReturn {
    /// Whether the frame at `cursor` falls outside the rows shown when `top` is the first
    /// frame on screen. Unknown geometry (no columns, no rows measured) never scrolls:
    /// keeping the user's place is the point, and a guess would throw it away.
    static func needsScroll(cursor: Int, top: Int, columns: Int, visibleRows: Int) -> Bool {
        guard columns > 0, visibleRows > 0 else { return false }
        let cursorRow = cursor / columns
        let topRow = top / columns
        return cursorRow < topRow || cursorRow >= topRow + visibleRows
    }

    /// Whole rows that fit in the viewport. The row pitch comes from the grid's own content
    /// height, since a cell's height follows the thumbnail and is not a constant. A grid
    /// shorter than the viewport shows every row.
    static func visibleRows(viewport: Double, content: Double, frames: Int, columns: Int,
                            padding: Double, spacing: Double) -> Int {
        guard frames > 0, columns > 0, viewport > 0 else { return 0 }
        let rows = (frames + columns - 1) / columns
        guard content > viewport else { return rows }
        let pitch = (content - 2 * padding + spacing) / Double(rows)
        guard pitch > 0 else { return 0 }
        return max(1, Int((viewport - padding) / pitch))
    }

    /// The rows wholly inside the viewport when the content is scrolled down by `offset`,
    /// for keyboard navigation. Stricter than `needsScroll`, which counts the row at
    /// the top as on screen even when most of it has scrolled off: arrowing up into a row
    /// with a sliver showing has to bring it in. A point of slack absorbs rounding. Nil
    /// when nothing is measured or no whole row fits.
    static func fullyVisibleRows(offset: Double, viewport: Double, content: Double, frames: Int,
                                 columns: Int, padding: Double, spacing: Double) -> ClosedRange<Int>? {
        guard frames > 0, columns > 0, viewport > 0 else { return nil }
        let rows = (frames + columns - 1) / columns
        guard content > viewport else { return 0...(rows - 1) }
        let pitch = (content - 2 * padding + spacing) / Double(rows)
        guard pitch > spacing else { return nil }
        let slack = 1.0
        // Row r spans padding + r * pitch to padding + (r + 1) * pitch - spacing.
        let first = Int(((offset - padding - slack) / pitch).rounded(.up))
        let last = Int(((offset + viewport - padding + spacing + slack) / pitch).rounded(.down)) - 1
        let lo = max(0, first), hi = min(rows - 1, last)
        return lo <= hi ? lo...hi : nil
    }
}
