import SwiftUI

/// The window's non-modal channel for news the user did not ask for and cannot act on: a
/// folder that vanished while the app was running, a frame deleted in Finder under a render.
///
/// Why this exists rather than another alert. An alert is a QUESTION, and it stops the app
/// until it is answered. Nothing here is a question: the folder is already gone, the deed
/// was done in Finder, and the only useful act is to say so once and get out of the way.
/// An alert reading `Error Domain=NSCocoaErrorDomain Code=260 ... NSFilePath=` would
/// interrupt the user to tell them something they had just done themselves, in the one
/// vocabulary that could not help them.
///
/// It clears itself. A banner that waits to be dismissed is a modal with worse manners.
struct NoticeBanner: View {
    @Environment(AppModel.self) private var model

    /// Long enough to read a sentence twice, short enough that it is gone before it is
    /// furniture. A click dismisses it sooner.
    static let dwell: Duration = .seconds(6)

    var body: some View {
        ZStack {
            if let text = model.notice {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.thickMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.separator))
                    .shadow(radius: 10, y: 2)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { model.notice = nil }
                    .accessibilityIdentifier("NoticeBanner")
                    .accessibilityAddTraits(.isStaticText)
                    // Keyed on the text: a second notice arriving while the first is up
                    // restarts the clock instead of inheriting the first one's remaining
                    // time, and the task is canceled if the banner goes early.
                    .task(id: text) {
                        try? await Task.sleep(for: Self.dwell)
                        guard !Task.isCancelled, model.notice == text else { return }
                        model.notice = nil
                    }
            }
        }
        .animation(.snappy, value: model.notice)
    }
}
