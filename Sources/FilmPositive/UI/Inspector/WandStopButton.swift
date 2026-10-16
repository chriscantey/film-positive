import SwiftUI

/// The spinner a bulk wand run shows in the wand's slot, as a button. On hover the spinner
/// gives way to a stop glyph, so what a click will do shows before the click.
/// A click calls `AppModel.stopRun`, the same entry as Escape: the frame being read is not
/// written, the ones already written stay, and one Undo takes those back.
///
/// Its own file so the wand file keeps its one glyph drawer (`AutoWandButton`).
///
/// Disabled once pressed, while the frame under way finishes its read, so a second click
/// reads as the no-op it is.
struct WandStopButton: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    static let help = "Stop"
    static let symbol = "stop.circle.fill"

    var body: some View {
        Button { model.stopRun() } label: {
            Group {
                if hovering && !model.stopRequested {
                    Image(systemName: Self.symbol)
                        .font(AutoWandButton.font)
                        .foregroundStyle(Color.secondary)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: AutoWandButton.slot, height: AutoWandButton.slot)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(model.stopRequested)
        .onHover { hovering = $0 }
        .help(Self.help)
        // A spinner inside a Button reads to Accessibility as the spinner (AXBusyIndicator,
        // no press action), measured on the first screen check. The representation makes
        // it a plain "Stop" button whatever the label is drawing.
        .accessibilityRepresentation {
            Button(Self.help) { model.stopRun() }
                .disabled(model.stopRequested)
        }
    }
}
