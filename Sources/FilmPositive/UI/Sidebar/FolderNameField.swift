import SwiftUI
import AppKit

/// The name field a folder row shows while it is being renamed: the whole name selected,
/// Return commits, Escape cancels, and clicking away commits.
///
/// A refused name leaves the field open with the typed text and shakes it once, and the
/// banner line says why. Never an alert: a refusal asks nothing, it only says what to fix.
struct FolderNameField: View {
    @Environment(AppModel.self) private var model
    let folder: FolderSession
    /// Called when Return or Escape closes the field, so the list can take the keyboard back.
    var onKeyClose: () -> Void = {}

    @State private var text: String
    @FocusState private var focused: Bool
    @State private var shakes: CGFloat = 0
    /// Set once the field has closed, so the focus loss that follows does not commit again.
    @State private var closed = false

    init(folder: FolderSession, onKeyClose: @escaping () -> Void = {}) {
        self.folder = folder
        self.onKeyClose = onKeyClose
        _text = State(initialValue: folder.name)
    }

    var body: some View {
        // Plain, with its own outline, so the row keeps the height and baseline of the
        // name it replaces and the folder icon does not move.
        TextField("Name", text: $text)
            .labelsHidden()
            .textFieldStyle(.plain)
            .padding(.horizontal, 3)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 1))
            .focused($focused)
            .modifier(Shake(shakes: shakes))
            .onSubmit {
                if commit() { onKeyClose() }
            }
            .onExitCommand {
                closed = true
                model.cancelRename()
                onKeyClose()
            }
            .onChange(of: focused) { _, now in
                // Clicking away commits. A refusal there keeps the field and its keyboard.
                guard !now, !closed else { return }
                if !commit() { focused = true }
            }
            .onChange(of: model.renameRefusals) { _, _ in
                withAnimation(.linear(duration: 0.35)) { shakes += 1 }
            }
            .onAppear {
                // A turn later, so a context menu has finished closing before the field
                // takes the keyboard, then the whole name is selected the way Finder does.
                DispatchQueue.main.async {
                    focused = true
                    DispatchQueue.main.async {
                        (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
                    }
                }
            }
            .accessibilityLabel("Folder name")
            .accessibilityIdentifier("sidebar.rename")
    }

    private func commit() -> Bool {
        guard !closed else { return true }
        let done = model.commitRename(text)
        if done { closed = true }
        return done
    }
}

/// A short side to side shake, three swings per refusal.
private struct Shake: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(shakes * .pi * 6), y: 0))
    }
}
