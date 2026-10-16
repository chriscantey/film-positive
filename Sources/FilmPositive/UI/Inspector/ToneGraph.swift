import SwiftUI
import FilmSidecar
import FilmPositiveCore

// The parts Levels and Curves share: the Section they each ride in, the histogram of
// the picture entering their step, and that histogram drawn as a backdrop.

/// A Levels or Curves group: its title line (the fold and a Reset that appears only while the
/// group holds something), then its body while open. The header of a Section of its own, with
/// the same title gap, inset and group gap as the slider groups
/// (`InspectorView.enhanceSections`), so every Enhance group reads as one family.
struct ToneGroupSection<Content: View>: View {
    let fold: InspectorSection
    let open: Bool
    let inUse: Bool
    let toggle: () -> Void
    let reset: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Section {
        } header: {
            VStack(alignment: .leading, spacing: InspectorView.enhanceTitleToRows) {
                HStack(spacing: 6) {
                    FoldTitle(fold.title, open: open, action: toggle) {
                        // The group-title style (`InspectorView.groupTitle`), so Levels and
                        // Curves read as peers of Light, Color and Detail.
                        Text(fold.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    // Laid out always and shown only while the group holds something, so the
                    // title line never changes height under the pointer. The link style the
                    // section headers' Reset uses.
                    Button("Reset", action: reset)
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Reset \(fold.title)")
                        .opacity(inUse ? 1 : 0)
                        .allowsHitTesting(inUse)
                        .accessibilityHidden(!inUse)
                        .accessibilityIdentifier("\(fold.rawValue).reset")
                }
                if open {
                    content()
                        .padding(.horizontal, -InspectorView.headerInset)
                        // The Form picks a header's type; pinned as the slider groups pin it.
                        .font(.body)
                        .fontWeight(.regular)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
            .padding(.bottom, InspectorView.enhanceGroupGap)
        }
    }
}

/// The histogram of the picture as it enters a tone step: the lead frame's request with only
/// the stages before that step (`CoreImageEnhance.entering`), at `.preview`, the smallest scale
/// the engine renders (1300 px on the long side), counted off the main actor.
enum EnteringHistogram {
    /// The request for `stage`, from the request the frame's current state wants.
    static func request(_ stage: EnhanceToneStage, from desired: RenderRequest?) -> RenderRequest? {
        guard var r = desired else { return nil }
        r.enhance = CoreImageEnhance.entering(stage, r.enhance)
        r.scale = .preview
        return r
    }

    /// Waits out a short pause first, so a drag upstream (Levels, for the Curves histogram)
    /// renders once when it rests rather than on every tick. A changed request cancels the
    /// wait through `.task(id:)`.
    static func load(_ request: RenderRequest?, service: any RenderService) async -> FrameHistogram? {
        guard let request else { return nil }
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return nil }
        return await Task.detached(priority: .utility) { () -> FrameHistogram? in
            guard let result = try? await service.render(request) else { return nil }
            let f = result.frame
            return FrameHistogram(pixels: f.pixels, width: f.width, height: f.height)
        }.value
    }
}

/// A histogram drawn as a backdrop: all three channels over each other (`.plusLighter`, as the
/// main histogram draws them), or one channel alone in its own color. Square-root scale, as
/// the main histogram, so a real frame is not one spike.
struct ToneHistogramBackdrop: View {
    let histogram: FrameHistogram?
    /// 0 red, 1 green, 2 blue, nil all three.
    var channel: Int? = nil
    var opacity: Double = 0.55

    static let colors: [Color] = [
        Color(red: 1, green: 0.23, blue: 0.19),
        Color(red: 0.20, green: 0.84, blue: 0.29),
        Color(red: 0.20, green: 0.48, blue: 1),
    ]

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            guard let h = histogram, !h.isEmpty else { return }
            let channels = channel.map { [$0] } ?? [0, 1, 2]
            let peak = channels.map { h.channel($0).max() ?? 0 }.max() ?? 0
            guard peak > 0 else { return }
            if channel == nil { context.blendMode = .plusLighter }
            for c in channels {
                context.fill(Self.path(h.channel(c), peak: peak, in: size),
                             with: .color(Self.colors[c].opacity(opacity)))
            }
        }
        .accessibilityHidden(true)
    }

    static func path(_ counts: [Int], peak: Int, in size: CGSize) -> Path {
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
