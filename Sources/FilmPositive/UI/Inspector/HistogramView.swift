import SwiftUI

/// The RGB histogram, three channels overlaid.
///
/// Drawn in a `Canvas` rather than as stacked shapes so a slider drag redraws one layer
/// instead of rebuilding 768 views, and with `.plusLighter` so overlapping channels read
/// as the additive color the eye expects (red over green over blue where all three sit on
/// top of each other gives white).
struct HistogramView: View {
    let histogram: FrameHistogram?

    private static let channelColours: [Color] = [
        Color(red: 1, green: 0.23, blue: 0.19),
        Color(red: 0.20, green: 0.84, blue: 0.29),
        Color(red: 0.20, green: 0.48, blue: 1),
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
            if let histogram, !histogram.isEmpty, histogram.peak > 0 {
                Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                    context.blendMode = .plusLighter
                    for channel in 0..<3 {
                        context.fill(path(histogram.channel(channel), peak: histogram.peak, in: size),
                                     with: .color(Self.channelColours[channel].opacity(0.75)))
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 3)
            } else {
                Text("No render yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel("Histogram")
        // Built as a String on its own line, and that is not a style choice.
        //
        // `accessibilityValue` takes either a LocalizedStringKey or a StringProtocol, and
        // Swift picks the concrete LocalizedStringKey for a literal, so an inline
        // interpolation hands SwiftUI a format string with one Int in it. Foundation then
        // logs a fault on every pass: String(format:locale:arguments:): Provided argument
        // types ["Swift.Int"] (with inferred specifiers ["%lld"]) do not match the format
        // string's specifiers. Naming the type makes it an ordinary string that nothing
        // tries to localize.
        .accessibilityValue(accessibilityText)
    }

    private var accessibilityText: String {
        guard let histogram else { return "not available" }
        return "\(histogram.sampleCount) pixels sampled"
    }

    /// A filled area under the counts. The vertical scale is the square root of the count
    /// because a linear scale on a real frame is one spike and fifteen invisible bins.
    private func path(_ counts: [Int], peak: Int, in size: CGSize) -> Path {
        var p = Path()
        guard counts.count > 1, peak > 0 else { return p }
        let step = size.width / CGFloat(counts.count - 1)
        let scale = sqrt(Double(peak))
        p.move(to: CGPoint(x: 0, y: size.height))
        for (i, count) in counts.enumerated() {
            let h = CGFloat(sqrt(Double(count)) / scale) * size.height
            p.addLine(to: CGPoint(x: CGFloat(i) * step, y: size.height - h))
        }
        p.addLine(to: CGPoint(x: size.width, y: size.height))
        p.closeSubpath()
        return p
    }
}
