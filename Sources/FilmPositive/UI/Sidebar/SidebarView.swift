import SwiftUI
import AppKit

/// The library column: one row per added folder, its name and how many frames it holds,
/// add and remove, and the selection that drives the grid.
///
/// Plain `List` with selection, a source list style, SF Symbols and a small add and
/// remove bar along the bottom, which is what a Mac sidebar looks like. No custom chrome.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// The folder list's own keyboard focus. Escape clears it.
    @FocusState private var listFocused: Bool

    /// Where the pinned heading's text starts, matching a sidebar list header's position
    /// (x 412 against a sidebar edge of 398 on a 1x screen).
    static let headingLeading: CGFloat = 14

    /// The drop box's geometry. Acceptance is at least 4 pt of clear space between the
    /// stroke and every row's text and selection highlight, on all four sides. The stroke
    /// sits `dropInset` in from the panel and is `dropStroke` wide, so its inner edge is 6
    /// pt in. Top and bottom: the rows begin `dropGutter` = 10 pt in, 4 pt clear. Sides: the
    /// sidebar draws its selection highlight 10 pt in from the list edge (measured: panel
    /// 398 to 637, highlight 408 to 627), 4 pt clear.
    static let dropInset: CGFloat = 4
    static let dropStroke: CGFloat = 2
    static let dropGutter: CGFloat = 10

    var body: some View {
        @Bindable var model = model
        // The Folders heading sits ABOVE the list rather than as its Section header, so it
        // never scrolls. A sidebar List's section header scrolls away with the rows, and the
        // drop box, which has to sit under the heading and not through it, would then have
        // nothing fixed to sit under and would strike through whichever folder name
        // scrolled to that height. Pinned, the box can cover exactly the list and nothing
        // else.
        VStack(alignment: .leading, spacing: 0) {
            Text("Folders")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, Self.headingLeading)
                .padding(.vertical, 4)
                .accessibilityAddTraits(.isHeader)
            // Written through `selectFolderFromSidebar`, never straight to the model, so the
            // gallery knows the change came from here and leaves the keyboard on the list.
            // The arrows then walk the folders, as in Finder's sidebar.
            List(selection: Binding(get: { model.selectedFolderID },
                                    set: { model.selectFolderFromSidebar($0) })) {
                ForEach(model.folders) { folder in
                    FolderRow(folder: folder, colour: model.folderColours[folder.id],
                              isRenaming: model.renamingFolderID == folder.id,
                              onRenameKeyClose: { listFocused = true })
                        .tag(folder.id)
                        .contextMenu { menu(for: folder) }
                }
                // Drag a folder to reorder the list, and the order is remembered.
                .onMove { model.moveFolders(from: $0, to: $1) }
            }
            .listStyle(.sidebar)
            .focused($listFocused)
            .onChange(of: listFocused) { _, now in model.sidebarFocusChanged(now) }
            // Return renames the selected folder, as in Finder, and Escape lets go of the
            // keyboard. Both only while the list holds focus, since that is when a key
            // reaches it at all. While the name field is open both keys are the field's.
            .onKeyPress(.return) {
                guard model.renamingFolderID == nil else { return .ignored }
                guard let id = model.selectedFolderID, model.renameBlocker(id) == nil else { return .ignored }
                model.beginRename(id)
                return .handled
            }
            .onKeyPress(.escape) {
                guard model.renamingFolderID == nil else { return .ignored }
                listFocused = false
                model.releaseSidebarKeyboard()
                NSApp.keyWindow?.makeFirstResponder(nil)
                return .handled
            }
            // A permanent gutter above and below the rows, so the list's own edge, where
            // rows start and where scrolled rows are clipped, sits INSIDE the drop box.
            // Without it the box sits on the list's edge, and at scroll zero row 1 starts on
            // that edge, so the stroke would cross the first row's highlight and name. With
            // the gutter, no row, scrolled or not, can ever reach the stroke.
            .padding(.vertical, Self.dropGutter)
            // Where a Finder drag will land, while it is over the window.
            .overlay {
                if model.isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: Self.dropStroke)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .padding(Self.dropInset)
                        .allowsHitTesting(false)
                }
            }
        }
        .onDeleteCommand(perform: removeSelected)
        // No placeholder here at all. One per column, each centered in a column of a
        // different height, would put their titles at three different heights. The grid
        // owns the one empty state. This column keeps its Folders header and the plus in
        // the footer, which already say what to do.
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .toolbar {
            ToolbarItem {
                Button { model.presentAddFolder() } label: { Label("Add Folder", systemImage: "plus") }
                    .help("Add a folder of raw scans")
            }
        }
        .navigationTitle("Library")
    }

    /// The add and remove bar Finder puts under a source list.
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 2) {
                Button { model.presentAddFolder() } label: {
                    Image(systemName: "plus").frame(width: 22, height: 18)
                }
                .help("Add a folder of raw scans")
                .accessibilityLabel("Add Folder")

                Button(action: removeSelected) {
                    Image(systemName: "minus").frame(width: 22, height: 18)
                }
                .disabled(model.selectedFolderID == nil)
                .help("Remove from the sidebar. Files stay on disk.")
                .accessibilityLabel("Remove Folder")

                Spacer()

                // Move to Folder. The same action as the frame menu and File menu, on the
                // selection.
                // At the far end so it does not read as a third folder button.
                Button { model.presentMoveSelection() } label: {
                    Image(systemName: "folder.badge.plus").frame(width: 26, height: 18)
                }
                .disabled(model.selectedFrames.isEmpty)
                .help("Move the selected frames to another folder (⇧⌘M)")
                .accessibilityLabel("Move to Folder")
                .accessibilityIdentifier("sidebar.move")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(.bar)
    }

    @ViewBuilder
    private func menu(for folder: FolderSession) -> some View {
        // Removing takes the folder out of the library only. `AppModel.removeFolder` is
        // undoable and never touches the files.
        Button("Remove from Library", systemImage: "minus.circle") { model.removeFolder(folder.id) }
        Divider()
        Button("Rescan", systemImage: "arrow.clockwise") { model.rescan(folder.id) }
        Button("Reveal in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([folder.url])
        }
        // Renames the folder on disk. Disabled, with the reason as its help, when the
        // folder that holds it cannot be written to or a run is going.
        let renameBlocker = model.renameBlocker(folder.id)
        Button("Rename…", systemImage: "pencil") { model.beginRename(folder.id) }
            .disabled(renameBlocker != nil)
            .help(renameBlocker ?? "Rename the folder on disk")
        Divider()
        // The folder's Finder color tag, the seven Finder colors plus None. Checked
        // on the current one. Nothing is stored by the app: the pick writes the tag, and any
        // other tags the folder has are kept.
        Picker("Color", selection: Binding(
            get: { model.folderColours[folder.id] },
            set: { model.setFolderColour($0, for: folder.id) }
        )) {
            ForEach(FolderColour.allCases) { c in
                Label { Text(c.tagName) } icon: { Image(nsImage: c.menuDot) }
                    .tag(Optional(c))
            }
            Text("None").tag(FolderColour?.none)
        }
        .pickerStyle(.inline)
    }

    private func removeSelected() {
        guard model.renamingFolderID == nil, let id = model.selectedFolderID else { return }
        model.removeFolder(id)
    }
}

/// One folder: the name, the frame count as a badge, and how many are developed, which is
/// the one number that tells the user where a roll stands at a glance.
struct FolderRow: View {
    let folder: FolderSession
    /// The folder's Finder color tag, drawn the way `colourMark` says.
    var colour: FolderColour? = nil
    /// The name shows as a field while the folder is being renamed.
    var isRenaming = false
    var onRenameKeyClose: () -> Void = {}
    var mark: ColourMark = FolderRow.colourMark

    /// Where a folder's color shows in its row.
    enum ColourMark: Sendable, CaseIterable {
        /// The folder icon is filled with the color, no dot.
        case icon
        /// An 8 pt dot before the folder icon, nothing after the name.
        case leadingDot
        /// An 8 pt dot after the name, where Finder draws its tag dots.
        case trailingDot
    }

    /// The one line to change to pick a different mark.
    static let colourMark: ColourMark = .icon

    /// What a row draws for a color under a mark, as plain values so a test can read it.
    struct Look: Equatable {
        var symbol = "folder"
        /// Nil keeps the sidebar's own icon tint.
        var iconColour: FolderColour?
        var leadingDot: FolderColour?
        var trailingDot: FolderColour?
        /// A leading dot mode keeps the dot's slot on untagged rows too, so the icons line up.
        var reservesLeadingSlot = false
    }

    static func look(_ colour: FolderColour?, _ mark: ColourMark) -> Look {
        switch mark {
        case .icon:
            guard let colour else { return Look() }
            return Look(symbol: "folder.fill", iconColour: colour)
        case .leadingDot:
            return Look(leadingDot: colour, reservesLeadingSlot: true)
        case .trailingDot:
            return Look(trailingDot: colour)
        }
    }

    static let dotSize: CGFloat = 8

    private var developed: Int { folder.frames.filter(\.isDeveloped).count }

    var body: some View {
        let look = Self.look(colour, mark)
        // Only the leading dot mode wraps the row, so the other two keep the row's
        // accessibility tree unchanged.
        if look.reservesLeadingSlot {
            HStack(spacing: 4) {
                Circle()
                    .fill(look.leadingDot?.color ?? .clear)
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .accessibilityHidden(true)
                label(look)
            }
        } else {
            label(look)
        }
    }

    private func label(_ look: Look) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    // While renaming, the name stays for layout, hidden, and the field sits
                    // over it. A text field has no first text baseline of its own, so in
                    // its place the Label would align the icon with the second line.
                    Text(folder.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(isRenaming ? 0 : 1)
                        .frame(maxWidth: isRenaming ? .infinity : nil, alignment: .leading)
                        .overlay {
                            if isRenaming { FolderNameField(folder: folder, onKeyClose: onRenameKeyClose) }
                        }
                    if let dot = look.trailingDot {
                        Circle()
                            .fill(dot.color)
                            .frame(width: Self.dotSize, height: Self.dotSize)
                            .accessibilityHidden(true)
                    }
                }
                if !folder.frames.isEmpty {
                    Text(developed == folder.frames.count ? "All developed" : "\(developed) of \(folder.frames.count) developed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            FolderIcon(look: look)
        }
        .badge(folder.frames.count)
        .help(folder.url.path)
        .accessibilityLabel("\(folder.name), \(colour.map { "\($0.tagName), " } ?? "")\(folder.frames.count) frames, \(developed) developed")
    }
}

/// The row's folder symbol. Untagged, it is the plain outline in the sidebar's own tint.
/// Colored, the fill is set explicitly, so the sidebar cannot retint it with the accent
/// color, and on a selected row in a focused list (the accent highlight) it gains a white
/// outline: the row still reads as selected, and a blue folder on a blue highlight keeps
/// its edge.
private struct FolderIcon: View {
    let look: FolderRow.Look
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if let colour = look.iconColour {
            Image(systemName: look.symbol)
                .foregroundStyle(colour.color)
                .overlay {
                    if prominence == .increased {
                        Image(systemName: "folder").foregroundStyle(.white)
                    }
                }
        } else {
            Image(systemName: look.symbol)
        }
    }
}
