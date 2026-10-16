import SwiftUI
import FilmSidecar
import FilmPositiveCore

/// The Levels group's body: a small histogram of the picture as it enters Levels, an
/// input track with black, midtone and white handles under it, and a black to white strip with
/// the two output handles. One set for the whole picture.
///
/// Every handle is its own accessibility slider (`levels.inBlack` and the rest) that answers
/// increment and decrement, with a one-sentence hover help. A drag is relative to where it
/// started, so a click that does not move writes nothing. A double click puts that one handle
/// back where it starts.
struct LevelsGroup: View {
    let summary: SelectionSummary
    /// The lead frame's request with only the stages before Levels, or nil with no render.
    let entering: RenderRequest?
    let service: any RenderService
    let onSet: (LevelsHandle, Double) -> Void
    let onEditing: (Bool) -> Void

    @State private var histogram: FrameHistogram?
    /// The handle being dragged and where it, or the midtone's track position, started.
    @State private var drag: (handle: LevelsHandle, start: Double)?

    static let histogramHeight: CGFloat = 46
    static let handleWidth: CGFloat = 11
    static let handleHeight: CGFloat = 9
    static let stripHeight: CGFloat = 8
    /// The track is inset by half a handle at each end, so a handle at 0 or 1 is whole.
    static var inset: CGFloat { handleWidth / 2 + 1 }
    static let space = "levels.track"

    private var levels: Levels { summary.shownLevels }

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width - 2 * Self.inset)
            VStack(spacing: 2) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary)
                    ToneHistogramBackdrop(histogram: histogram)
                        .padding(.horizontal, Self.inset)
                        .padding(.vertical, 3)
                }
                .frame(height: Self.histogramHeight)
                inputTrack(width: w)
                outputStrip(width: w)
            }
            .coordinateSpace(name: Self.space)
        }
        .frame(height: Self.histogramHeight + 2 + (Self.stripHeight + Self.handleHeight + 2) * 2 + 2)
        .padding(.horizontal, 6)
        .task(id: entering) {
            if let h = await EnteringHistogram.load(entering, service: service) { histogram = h }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("levels.group")
    }

    // MARK: the two tracks

    private func inputTrack(width w: CGFloat) -> some View {
        VStack(spacing: 1) {
            Capsule()
                .fill(LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing))
                .frame(width: w, height: 3)
                .opacity(0.6)
                .frame(maxWidth: .infinity)
                .frame(height: Self.stripHeight)
            ZStack(alignment: .topLeading) {
                handle(.inBlack, at: levels.inBlack, width: w)
                handle(.inWhite, at: levels.inWhite, width: w)
                handle(.gamma, at: LevelsGeometry.midtonePosition(levels), width: w)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: Self.handleHeight + 1)
        }
    }

    private func outputStrip(width w: CGFloat) -> some View {
        VStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing))
                .frame(width: w, height: Self.stripHeight)
                .frame(maxWidth: .infinity)
            ZStack(alignment: .topLeading) {
                handle(.outBlack, at: levels.outBlack, width: w)
                handle(.outWhite, at: levels.outWhite, width: w)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: Self.handleHeight + 1)
        }
    }

    // MARK: a handle

    private func handle(_ h: LevelsHandle, at position: Double, width w: CGFloat) -> some View {
        let shared = summary.levels[h] ?? .empty
        let value = summary.levelsPosition(h)
        let x = Self.inset + CGFloat(min(max(position, 0), 1)) * w
        return LevelsHandleMark(handle: h)
            .opacity(shared.isMultiple ? 0.45 : 1)
            .frame(width: Self.handleWidth + 6, height: Self.handleHeight + 1)
            .contentShape(Rectangle())
            .offset(x: x - (Self.handleWidth + 6) / 2)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { g in
                    if drag == nil {
                        drag = (h, h == .gamma ? LevelsGeometry.midtonePosition(levels) : value)
                        onEditing(true)
                    }
                    // No movement, no write: a click on a handle the frames disagree on would
                    // otherwise write its parked identity value to all of them.
                    guard let d = drag, d.handle == h, g.translation.width != 0 else { return }
                    let moved = d.start + Double(g.translation.width / w)
                    onSet(h, h == .gamma ? LevelsGeometry.gamma(atPosition: moved, levels) : moved)
                }
                .onEnded { _ in
                    drag = nil
                    onEditing(false)
                })
            // The double click resets this handle only. A click that does not move wrote
            // nothing above, so the two clicks before it leave no trace.
            .simultaneousGesture(TapGesture(count: 2).onEnded { onSet(h, h.identity) })
            // After the element, or the tooltip stays on a child the element ignores and the
            // handle reports no help.
            .accessibilityElement(children: .ignore)
            .help(h.help)
            .accessibilityLabel(h.label)
            .accessibilityValue(shared.isMultiple ? "Multiple" : h.describe(value))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onSet(h, value + h.step)
                case .decrement: onSet(h, value - h.step)
                @unknown default: break
                }
            }
            .accessibilityIdentifier(h.id)
    }
}

/// A small triangle pointing up at the track, filled in the tone it sets: black, grey or
/// white, with an edge that shows on both.
struct LevelsHandleMark: View {
    let handle: LevelsHandle

    private var fill: Color {
        switch handle {
        case .inBlack, .outBlack: return .black
        case .gamma: return Color(white: 0.5)
        case .inWhite, .outWhite: return .white
        }
    }

    var body: some View {
        Triangle()
            .fill(fill)
            .overlay(Triangle().stroke(Color.primary.opacity(0.55), lineWidth: 0.75))
            .frame(width: LevelsGroup.handleWidth, height: LevelsGroup.handleHeight)
    }

    struct Triangle: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }
}
