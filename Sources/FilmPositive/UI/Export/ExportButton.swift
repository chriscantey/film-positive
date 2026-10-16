import SwiftUI

/// The Export button, in its two places: the window toolbar's item at the top right, and
/// the inspector's button pinned under the form at the bottom right, so the inspector reads
/// as something to work through top to bottom and then export.
///
/// ONE view for both, so the action, the enabled rule and the hover help cannot drift: the
/// two places differ only in the label. The toolbar keeps its icon and the word Export,
/// and the inspector says the count the way the Develop button does (`PositiveButton`).
struct ExportButton: View {
    enum Place { case toolbar, inspector }

    @Environment(AppModel.self) private var model
    let place: Place

    var body: some View {
        Button { model.presentExport() } label: {
            switch place {
            case .toolbar: Label("Export", systemImage: "square.and.arrow.up")
            case .inspector: Text(Self.title(count: model.selectedFrames.count))
            }
        }
        .disabled(!Self.enabled(selectionCount: model.selectedFrames.count))
        .help(Self.help)
    }

    /// Export acts over the selection, so anything selected can export.
    /// Undeveloped frames in it are skipped, and the sheet says how many.
    static func enabled(selectionCount: Int) -> Bool { selectionCount > 0 }

    static let help = "Export the selected developed frames"

    /// The inspector button's words: no count for one frame, the count for several, as
    /// "Develop (3)" does.
    static func title(count: Int) -> String {
        count > 1 ? "Export (\(count))" : "Export"
    }
}

extension AppModel {
    /// What either Export button does: open the Export sheet over the selection, as File >
    /// Export (Command E) does.
    func presentExport() { showsExportSheet = true }
}
