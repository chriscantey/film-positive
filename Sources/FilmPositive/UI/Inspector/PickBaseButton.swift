import SwiftUI

/// The eyedropper, in the Base row between its title and the Base control. Everything about
/// what it DOES lives here and on the model, so the wiring in `InspectorView` is one line and
/// cannot carry a second opinion about the behavior.
///
/// Icon only, no label, `.borderless`: it sits in a row beside a segmented control, and a
/// worded button there would read as the row's own control rather than as a tool.
struct PickBaseButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.beginPickingBase()
        } label: {
            Image(systemName: "eyedropper")
        }
        .buttonStyle(.borderless)
        .disabled(!model.canPickBase)
        .help("Pick film color by clicking clear film between frames.")
    }
}
