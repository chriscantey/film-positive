import SwiftUI
import AppKit
import FilmPositiveCore

/// Film Positive. Version and build live here because a SwiftPM executable has no
/// Info.plist until the bundle step wraps it, and the bundle step copies these into the
/// plist.
public enum AppInfo {
    public static let version = "0.1.0"
    /// Incremented at every bundle.
    public static let build = 125
    public static var display: String { "\(version) (\(build))" }
    /// Stamped into Info.plist by the bundle step. A shipping build identifies itself by its
    /// git hash, a pre-shipping build by its build number. An unbundled dev run has neither
    /// key.
    public static var gitHash: String? { Bundle.main.infoDictionary?["GitHash"] as? String }
    public static var isShipping: Bool { (Bundle.main.infoDictionary?["Shipping"] as? Bool) ?? false }
    public static var aboutIdentity: String { isShipping ? (gitHash ?? "\(build)") : "\(build)" }
}

@main
struct FilmPositiveApp: App {
    /// What Command V does. Pure so the order is testable.
    enum PasteRoute: Equatable { case text, settings }
    static func pasteRoute(textFieldHasFocus: Bool, framesSelected: Bool, settingsCopied: Bool) -> PasteRoute {
        if textFieldHasFocus { return .text }
        return framesSelected && settingsCopied ? .settings : .text
    }

    /// What Command C does, the mirror of `pasteRoute`. Text wherever a text field has
    /// the keyboard, otherwise All settings from the cursor frame (`copySettingsSource`).
    enum CopyRoute: Equatable { case text, settings }
    static func copyRoute(textFieldHasFocus: Bool, hasSourceFrame: Bool) -> CopyRoute {
        !textFieldHasFocus && hasSourceFrame ? .settings : .text
    }

    /// Command Backspace. In a text field it is the system's delete to the start of
    /// the line, and a menu key equivalent is seen BEFORE the text view's own key binding, so
    /// without this route a person clearing a Metadata field would trash the selected frames.
    /// And while the folder list holds the keyboard it does nothing: a person looking at
    /// the folders is not pointing at the frames, and Finder's own Command Backspace there would
    /// mean the folder.
    enum TrashRoute: Equatable { case text, frames, nothing }
    static func trashRoute(textFieldHasFocus: Bool, sidebarHasKeyboard: Bool = false) -> TrashRoute {
        textFieldHasFocus ? .text : (sidebarHasKeyboard ? .nothing : .frames)
    }

    /// Command Z inside a text field undoes the typing, not a frame edit. The same
    /// focus test Paste and Select All use.
    enum UndoRoute: Equatable { case text, model }
    static func undoRoute(textFieldHasFocus: Bool) -> UndoRoute { textFieldHasFocus ? .text : .model }

    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup("Film Positive") {
            ContentView()
                .environment(model)
                .onAppear { AppUpdates.start() }
                // The window minimum is the SUM of the three column minimums plus the
                // dividers and the split view's leading inset, never a number chosen by
                // hand. `ShellLayout` carries the measurement that says why.
                .frame(minWidth: ShellLayout.windowMinWidth,
                       minHeight: ShellLayout.windowMinHeight)
        }
        // Without this the root's minWidth is advice rather than a constraint: the scene
        // sizes itself and the content clips inside it. `.contentMinSize` makes the window
        // refuse to go narrower than the sum above.
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(model: model)
        }
        // Settings: stocks, cropping and export.
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

extension FilmPositiveApp {
    /// The standard About panel with the version, the build, and credits that link to the
    /// contributors rather than listing them, plus the libraries this app is built on.
    @MainActor
    static func showAboutPanel() {
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        // Kept short on purpose: a longer credits block overflows the panel's text view
        // and draws it with a bordered scroll box.
        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(
            string: "Other people have put work into this app. They're listed under ",
            attributes: body))
        credits.append(NSAttributedString(
            string: "Contributors",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .link: URL(string: "https://github.com/chriscantey/film-positive#contributors")!,
            ]))
        credits.append(NSAttributedString(
            string: ", and huge thanks to them.\n\n"
                  + "Built on LibRaw (LGPL 2.1 or later) and libjxl (BSD 3-Clause). "
                  + "Thanks to their maintainers.\n\n"
                  + AppUpdates.aboutSentence,
            attributes: body))
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Film Positive",
            // The bundle's own string, so a beta build says "0.1.0 beta 3" here as it
            // does in Sparkle's sheets. The source constant is the fallback for `swift run`.
            .applicationVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? AppInfo.version,
            // "Version 0.1.0 (20)" before shipping, "Version 0.1.0 (a1b2c3d)" once shipped.
            .version: AppInfo.aboutIdentity,
            .credits: credits,
        ])
    }
}

/// Menu commands. Every edit goes through `AppModel.apply`, so undo and redo are the
/// standard Edit menu items and nothing else needs wiring.
struct AppCommands: Commands {
    let model: AppModel

    @MainActor
    static func undoOrRedo(_ model: AppModel, redo: Bool) {
        switch FilmPositiveApp.undoRoute(textFieldHasFocus: NSApp.keyWindow?.firstResponder is NSText) {
        case .text: NSApp.sendAction(redo ? Selector(("redo:")) : Selector(("undo:")), to: nil, from: nil)
        case .model: if redo { model.undoManager.redo() } else { model.undoManager.undo() }
        }
    }

    var body: some Commands {
        // `AppModel` owns its own `UndoManager()`, while the Edit menu's default Undo is
        // driven by the window's responder chain. These items call the model's undo manager,
        // so Command Z reaches the one that holds every edit's registration.
        //
        // Deliberately NOT disabled on `canUndo`. `UndoManager` is not Observable, so SwiftUI
        // has nothing to invalidate on and the flag would be read from stale state, and a
        // `.disabled` command also kills its KEYBOARD SHORTCUT. A dead Command Z is far worse
        // than a menu item that is always enabled, and undo with an empty stack is a no-op.
        //
        // The titles name the action ("Undo Straighten") through `undoTitles`, and a
        // text field with the keyboard gets its own typing undone rather than a frame edit.
        // The title cannot follow focus (focus is not observable here), so in a text field it
        // still names the frame edit while the key undoes the typing. The key is what matters.
        CommandGroup(replacing: .undoRedo) {
            Button(model.undoTitles.undoTitle.isEmpty ? "Undo" : model.undoTitles.undoTitle) { Self.undoOrRedo(model, redo: false) }
                .keyboardShortcut("z", modifiers: [.command])
            Button(model.undoTitles.redoTitle.isEmpty ? "Redo" : model.undoTitles.redoTitle) { Self.undoOrRedo(model, redo: true) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        // App menu > About Film Positive, with the credits panel above.
        CommandGroup(replacing: .appInfo) {
            Button("About Film Positive") { FilmPositiveApp.showAboutPanel() }
            // Check for Updates… sits under About. A build with no feed (a dev build) has
            // no updater and no item. Inside this group, because the commands builder
            // takes ten groups and this file already has them.
            if let updater = AppUpdates.updater {
                Divider()
                CheckForUpdatesButton(updater: updater)
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Folder…") { model.presentAddFolder() }
                .keyboardShortcut("o", modifiers: [.command])
        }
        CommandGroup(replacing: .importExport) {
            // Export acts on the selection, like Positive and Detect Crop. Select All then
            // Export is the whole-roll path.
            Button("Export…") { model.showsExportSheet = true }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(model.selectedFrames.isEmpty)
            // Shift Command M was free in every menu and in macOS itself.
            Button("Move to Folder…") { model.presentMoveSelection() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(model.selectedFrames.isEmpty)
            // Finder's key and Finder's menu. Undoable, so no dialog.
            Button("Move to Trash") {
                switch FilmPositiveApp.trashRoute(textFieldHasFocus: NSApp.keyWindow?.firstResponder is NSText,
                                                  sidebarHasKeyboard: model.sidebarHasKeyboard) {
                case .frames: model.trashSelection()
                case .text: NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
                case .nothing: break
                }
            }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selectedFrames.isEmpty)
            // The context menu's Duplicate, in the menu bar too. No key: Command D is
            // Develop, and the menu is what makes it findable.
            Button("Duplicate") { model.duplicateSelection() }
                .disabled(model.selectedFrames.isEmpty)
                .help("Copy the frame next to the original, with no undo.")
            Divider()
            // Option Command R because Command R is Reset Enhance here.
            Button("Reveal in Finder") { model.revealSelectionInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model.selectedFrames.isEmpty)
        }
        // The verb is Develop, the same word as the menu and the inspector section it
        // mostly serves. Its Reset and the
        // film color items all act on that section's settings.
        CommandMenu("Develop") {
            Button("Develop") { model.developSelection() }
                .keyboardShortcut("d", modifiers: [.command])
            Button("Reset Develop") { model.resetDevelopSelection() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Reset Enhance") { model.resetEnhanceSelection() }
                .keyboardShortcut("r", modifiers: [.command])
            Divider()
            // The eyedropper. Three items and not one, because the three things a person
            // wants here are different: measure a base, put THAT base on more frames, and
            // hand a frame back to auto.
            Button("Pick Film Color…") { model.beginPickingBase() }
                .disabled(!model.canPickBase)
            Button("Reuse Last Film Color") { model.reusePickedBase() }
                .disabled(!model.canReusePickedBase)
            Button("Clear Film Color") { model.clearBase() }
                .disabled(!model.canClearBase)
        }
        // An Image menu for Rotate. Command [ and Command ] were free in every menu here.
        // Acts on the grid selection, or the shown frame in the closeup, like every other
        // control.
        CommandMenu("Image") {
            Button("Rotate Left") { model.rotateSelection(clockwise: false) }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(model.selectedFrames.isEmpty)
            Button("Rotate Right") { model.rotateSelection(clockwise: true) }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(model.selectedFrames.isEmpty)
            Divider()
            // The context menu's Reset Crop, where the menu bar can find it. No key.
            Button("Reset Crop") { model.resetCropSelection() }
                .disabled(model.selectedFrames.isEmpty)
                .help("Clear the crop, straighten and rotation.")
        }
        // The standard pasteboard group is REPLACED, not extended, because AppKit's own
        // Select All lives in it and owns Command A. A second item beside it loses its key
        // equivalent entirely (SwiftUI drops the duplicate), and the standard one stays
        // disabled because a SwiftUI grid is not a responder, so Command A would do nothing.
        // Cut, Copy, Paste and Delete come back as the same responder-chain
        // actions the standard items send, which is what keeps them working in text fields
        // and lets the sidebar's onDeleteCommand keep its menu item.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                .keyboardShortcut("x", modifiers: .command)
            // Command C copies All settings from the cursor frame when no text field has
            // the keyboard, so Command C then Command V moves a look between frames the way it
            // moves text. Shift Command C stays on Copy Settings > All.
            Button("Copy") {
                switch FilmPositiveApp.copyRoute(textFieldHasFocus: NSApp.keyWindow?.firstResponder is NSText,
                                                 hasSourceFrame: model.copySettingsSource != nil) {
                case .settings: if let f = model.copySettingsSource { model.copySettings(FrameSettingsSection.all, from: f.id) }
                case .text: NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
            }
                .keyboardShortcut("c", modifiers: .command)
            // Text paste wherever a text field has the keyboard, the same test Select All
            // uses, then copied settings onto the selected frames, then the ordinary
            // responder-chain paste. Command Shift V stays on Paste Settings.
            Button("Paste") {
                switch FilmPositiveApp.pasteRoute(textFieldHasFocus: NSApp.keyWindow?.firstResponder is NSText,
                                       framesSelected: !model.selection.isEmpty,
                                       settingsCopied: FrameSettingsPasteboard.hasPayload()) {
                case .settings: model.pasteSettings()
                case .text: NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
            }
                .keyboardShortcut("v", modifiers: .command)
            Button("Delete") { NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: nil) }
            Divider()
            // A text field with focus still gets text selection, because that is what
            // Command A means there. The grid gets every frame, and the anchor moves with it
            // so a following Shift click extends from the top of the roll.
            Button("Select All") {
                if let responder = NSApp.keyWindow?.firstResponder, responder is NSText {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    return
                }
                model.selectAllInView()
                model.anchor = model.framesInView.first?.id
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(model.framesInView.isEmpty)
            .help("Select every frame in this folder")
        }
        CommandGroup(after: .pasteboard) {
            // Copy and paste of settings, the menu half of the frame context menu, on
            // Command Shift C and Command Shift V.
            //
            // A submenu cannot carry a shortcut, so Command Shift C sits on All, which is
            // what an unqualified "copy the settings" means.
            Menu("Copy Settings") {
                ForEach(FrameSettingsSection.allCases, id: \.self) { section in
                    Button(section.title) {
                        if let f = model.copySettingsSource { model.copySettings([section], from: f.id) }
                    }
                    .disabled(section == .positive && model.copySettingsSource?.isDeveloped != true)
                }
                Divider()
                Button("All") {
                    if let f = model.copySettingsSource { model.copySettings(FrameSettingsSection.all, from: f.id) }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            .disabled(model.copySettingsSource == nil)
            // Gated on the SELECTION and not on the pasteboard, deliberately. SwiftUI
            // re-evaluates this body when the model changes and a pasteboard is not the
            // model, so a pasteboard test here would be read once and then be stale, and a
            // `.disabled` command kills its keyboard shortcut as well as its menu item
            // (the same reason Undo above is never disabled). A paste with nothing copied
            // is a no-op. The context menu, which is rebuilt every time it opens, does test
            // the pasteboard and greys itself out.
            //
            // The help line is written to be true of EVERY pasteboard rather than of the
            // current one, for the same staleness reason: this item cannot re-read the
            // pasteboard when the pasteboard changes. The live wording lives on the
            // context menu's copy of this item, and the note after the fact lives in the
            // inspector.
            Button("Paste Settings") { model.pasteSettings() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(model.selection.isEmpty)
                .help("Apply the copied settings to every selected frame.")
            Divider()
            // A way out of a selection other than clicking empty space. Escape does it
            // wherever the grid has focus, this is the one that is discoverable, and Command
            // Shift A is the macOS convention.
            Button("Deselect All") { model.deselectAllInView() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.selection.isEmpty)
        }
        // Not a `CommandMenu("View")`, which puts a SECOND menu called View in the menu bar
        // beside AppKit's own (Show Tab Bar, Show All Tabs, Enter Full Screen).
        // `CommandGroup(after: .sidebar)` appends into the system View menu
        // instead, so there is one of them and ours sit under the system items.
        CommandGroup(after: .sidebar) {
            Button(model.viewerFrameID == nil ? "Open Frame" : "Back to Grid") { model.toggleViewer() }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.framesInView.isEmpty)
            // A view mode of the closeup, so the menu item is a check mark rather than a
            // verb. From the grid it opens the closeup on the cursor with the rectangle
            // already up; in the closeup it shows and hides the rectangle, and it stays on
            // while the arrows walk the roll.
            Toggle("Show Crop Overlay", isOn: Binding(get: { model.showsCropOverlay },
                                                      set: { _ in model.toggleCropOverlay() }))
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(!model.canToggleCropOverlay)
            Divider()
            // The closeup's picture only: grey with the crop rectangle up or the
            // eyedropper armed. The keys zoom around the pointer, and ⌘= works as ⌘+ does
            // (`ZoomKeyAlias`), so the unshifted key people press is covered too.
            Button("Zoom In") { model.zoomCloseupIn() }
                .keyboardShortcut("+", modifiers: [.command])
                .disabled(!model.canZoomCloseupIn)
            Button("Zoom Out") { model.zoomCloseupOut() }
                .keyboardShortcut("-", modifiers: [.command])
                .disabled(!model.canZoomCloseupOut)
            Button("Zoom to Fit") { model.zoomCloseupToFit() }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(!model.canZoomCloseupToFit)
            // Command 1 is the usual Actual Size key on the Mac.
            Button("Actual Size") { model.zoomCloseupToActualSize() }
                .keyboardShortcut("1", modifiers: [.command])
                .disabled(!model.canZoomCloseupToActualSize)
            Divider()
            // Command Y, not Option Command H, which is the system's Hide Others.
            // Flips the Histogram section's fold.
            Toggle("Show Histogram", isOn: Binding(get: { model.histogramOpen }, set: { model.histogramOpen = $0 }))
                .keyboardShortcut("y", modifiers: [.command])
        }
        // HELP, and for the same reason the View group above is a CommandGroup: a
        // `CommandMenu("Help")` would put a SECOND menu called Help in the menu bar beside
        // the system's own.
        //
        // REPLACING rather than appending. The `.help` group's stock item is
        // "Film Positive Help", which opens a help book this app does not have, so it is a
        // dead item. Replacing it drops that and leaves this menu holding only things that
        // work.
        CommandGroup(replacing: .help) {
            // ⌘/ is borrowed from web apps. It is NOT a native macOS convention, because
            // native Mac apps mostly do not have a shortcuts panel at all. The nearest
            // native key is ⇧⌘/, and the SYSTEM owns that one for Help menu search.
            //
            // Free to take: nothing in this app binds "/" at all.
            Button("Keyboard Shortcuts") { model.showsShortcuts = true }
                .keyboardShortcut("/", modifiers: [.command])
        }
    }
}
