/// Who holds the keyboard after a folder is chosen.
///
/// Clicking a folder highlights it, and the sidebar then keeps focus for up and down arrow
/// navigation until the user clicks into the gallery or the right panel, presses Return
/// (into the gallery) or Escape (drop focus). If the gallery took focus on every folder
/// change, the list would lose the keyboard the moment it was clicked and the arrows would
/// walk the frames instead.
enum SidebarFocus {
    /// Whether a folder change, or the gallery appearing, should put the keyboard in the
    /// gallery. Not while the folder list holds it: that change came from the list.
    static func galleryTakesFocus(sidebarHasKeyboard: Bool) -> Bool { !sidebarHasKeyboard }
}
