import SwiftUI

/// Auto Enhance. A wand beside the Enhance title, with Reset alone at the right. It never
/// sits in the Looks row, so a collapsed Looks row cannot hide it.
///
/// It has no info icon. The wand's hover help, `help`, is the whole explanation.
///
/// Lit (accent) while every selected frame's layer still holds what the wand wrote, dim the
/// moment a slider moves. Dim, a click runs the wand. Lit, a click takes the layer back to 0.
/// Both are `AppModel.autoEnhanceClicked`.
struct AutoEnhanceButton: View {
    @Environment(AppModel.self) private var model
    /// The wand's hover help. One constant, so the words can change in one place.
    static let help = "Auto-adjust light and color. Click again to clear."

    var body: some View {
        // A spinner in the wand's place while a bulk run reads its frames, in a slot the
        // wand's size so nothing beside it moves. The spinner is the Stop, and it sits in the
        // slot of the wand that was clicked, so a Color run spins there instead.
        if model.enhanceRunning && !model.colorRunning {
            WandStopButton()
                .accessibilityIdentifier("enhance.auto.stop")
        } else {
            AutoWandButton(lit: model.autoEnhanceLit, help: Self.help) {
                model.autoEnhanceClicked()
            }
            .disabled(model.enhanceRunning)
            .accessibilityIdentifier("enhance.auto")
        }
    }
}

/// The wand both Autos draw: the Enhance Auto beside the Enhance title, and the Color
/// group's beside that group's title. One view, so the two are the same symbol at the same
/// size by construction, and the only thing that ever tells them apart is where they sit.
///
/// Accent when lit and secondary when dim, so the state is the color of the glyph and
/// nothing else is drawn. The accessibility label is "Auto" on both, and the hover help says
/// which Auto it is and what lit means.
struct AutoWandButton: View {
    let lit: Bool
    let help: String
    let action: () -> Void

    static let symbol = "wand.and.stars"
    /// The body size, pinned rather than inherited, because the two headers it sits in are
    /// styled by different code and a Form picks header type as it likes.
    static let font: Font = .body
    /// The square the glyph is drawn in, so the Stop spinner can hold the same place.
    static let slot: CGFloat = 18

    var body: some View {
        Button(action: action) {
            Image(systemName: Self.symbol)
                .font(Self.font)
                .foregroundStyle(lit ? Color.accentColor : Color.secondary)
                .frame(width: Self.slot, height: Self.slot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel("Auto")
        .accessibilityValue(lit ? "on" : "off")
        .accessibilityAddTraits(lit ? [.isSelected] : [])
    }
}


/// Neutralize cast, the Color group's own Auto. The same wand as the Enhance Auto
/// (`AutoWandButton`), beside the Color group's title, with no info icon: its hover help is
/// the explanation. A group header may carry an Auto that does only that group's part, while
/// the Enhance Auto does everything.
///
/// It has the Enhance Auto's states: lit while the frame's Warmth and Tint still equal the
/// pair it wrote (kept per frame as `Sidecar.colorAuto`), dim once either moves. Dim, a click
/// neutralizes. Lit, a click sets Warmth and Tint back to 0. Running it clears
/// the Enhance Auto's record, and the Enhance Auto clears this one, because each means the
/// layer no longer holds the other's write.
struct NeutraliseCastButton: View {
    @Environment(AppModel.self) private var model
    /// The wand's hover help. One constant, so the words can change in one place.
    static let help = "Remove a color cast. Click again to clear."

    var body: some View {
        // While its own bulk run reads, the Stop takes the wand's slot, as the Enhance Auto's
        // does. During an Enhance run it stays a wand, disabled.
        if model.enhanceRunning && model.colorRunning {
            WandStopButton()
                .accessibilityIdentifier("enhance.neutralise.stop")
        } else {
            AutoWandButton(lit: model.colorAutoLit, help: Self.help) { model.colorAutoClicked() }
                .disabled(model.enhanceRunning)
                .accessibilityIdentifier("enhance.neutralise")
        }
    }
}
