import SwiftUI
import FilmSidecar
import FilmPositiveCore

/// The editor's hit rules, as pure functions over a curve's points in 0...1, so they
/// have tests without a window. The view only converts the pointer to these coordinates.
enum CurveEditing {
    /// The least x distance between two points, so no move or add can make two meet (the file
    /// keeps 4 decimals, and the sanitiser drops a point whose x repeats there).
    static let minGap = 0.01

    /// The point nearest `p` within `radius`, or nil.
    static func hit(_ points: [CurvePoint], at p: CurvePoint, radius: Double) -> Int? {
        var best: (i: Int, d: Double)?
        for (i, q) in points.enumerated() {
            let d = ((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)).squareRoot()
            if d <= radius, d < (best?.d ?? .infinity) { best = (i, d) }
        }
        return best?.i
    }

    /// A new point at `p`, in x order, and its index. Nil when the curve already holds
    /// `CurvePoints.maxPoints`, or when `p` is within `minGap` in x of a point already there.
    static func add(_ points: [CurvePoint], at p: CurvePoint) -> (points: [CurvePoint], index: Int)? {
        guard points.count < CurvePoints.maxPoints else { return nil }
        let q = CurvePoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
        guard !points.contains(where: { abs($0.x - q.x) < minGap }) else { return nil }
        let index = points.firstIndex { $0.x > q.x } ?? points.count
        var out = points
        out.insert(q, at: index)
        return (out, index)
    }

    /// Point `index` moved to `p`: y held to 0...1, x held between its neighbors (`minGap` in
    /// from each), and an end point between its one neighbor and its edge. Order never changes.
    static func move(_ points: [CurvePoint], index: Int, to p: CurvePoint) -> [CurvePoint] {
        guard points.indices.contains(index), p.x.isFinite, p.y.isFinite else { return points }
        let lo = index > 0 ? points[index - 1].x + minGap : 0
        let hi = index < points.count - 1 ? points[index + 1].x - minGap : 1
        var out = points
        out[index] = CurvePoint(x: min(max(p.x, lo), max(lo, hi)), y: min(max(p.y, 0), 1))
        return out
    }

    /// The curve without point `index`. Nil for either end point, which can move but never go.
    static func remove(_ points: [CurvePoint], index: Int) -> [CurvePoint]? {
        guard index > 0, index < points.count - 1 else { return nil }
        var out = points
        out.remove(at: index)
        return out
    }
}

/// The Curves group's body: a channel picker, then a square graph the width of the
/// group with the histogram of the picture entering Curves behind it, a faint 4 by 4 grid, the
/// identity diagonal, the curve and its points.
///
/// Click on empty graph adds a point there and drags it; a drag moves a point, bounded by its
/// neighbors in x; a double click removes a point; the two end points move but stay. The whole
/// graph is one accessibility element, `curves.editor`, whose value is the point count.
struct CurvesGroup: View {
    let summary: SelectionSummary
    let entering: RenderRequest?
    let service: any RenderService
    let onSet: (CurveChannel, CurvePoints) -> Void
    let onEditing: (Bool) -> Void

    @State private var channel: CurveChannel = .all
    @State private var histogram: FrameHistogram?
    /// The point being dragged, the points as the drag left them, and where the point started.
    @State private var drag: (index: Int, points: [CurvePoint], origin: CurvePoint)?

    /// How far in from the graph's edge 0 and 1 sit, so an end point's circle is whole.
    static let inset: CGFloat = 5
    static let pointRadius: CGFloat = 3.5
    /// How near the pointer has to land to pick a point up, in points.
    static let hitRadius: CGFloat = 7

    private var points: [CurvePoint] { summary.curve(channel).points }

    var body: some View {
        VStack(spacing: 6) {
            Picker("Channel", selection: $channel) {
                ForEach(CurveChannel.allCases) { c in
                    // The dot marks a channel whose curve is not identity on some selected frame.
                    Text(c.title + (Self.inUse(summary, c) ? " \u{2022}" : "")).tag(c)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .help("Which curve the graph edits: all channels together, or red, green or blue alone.")
            .accessibilityIdentifier("curves.channel")
            GeometryReader { geo in
                graph(side: geo.size.width)
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .padding(.horizontal, 6)
        .task(id: entering) {
            if let h = await EnteringHistogram.load(entering, service: service) { histogram = h }
        }
    }

    static func inUse(_ s: SelectionSummary, _ c: CurveChannel) -> Bool {
        switch s.curves[c] ?? .empty {
        case .uniform(let p): return !p.isIdentity
        case .multiple: return true
        case .empty: return false
        }
    }

    static func color(_ c: CurveChannel) -> Color {
        switch c {
        case .all: return .white
        case .red: return ToneHistogramBackdrop.colors[0]
        case .green: return ToneHistogramBackdrop.colors[1]
        case .blue: return ToneHistogramBackdrop.colors[2]
        }
    }

    // MARK: the graph

    private func graph(side: CGFloat) -> some View {
        let s = max(1, side - 2 * Self.inset)
        let pts = drag?.points ?? points
        let shared = summary.curves[channel] ?? .empty
        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(white: 0.13))
            ToneHistogramBackdrop(histogram: histogram, channel: channel.histogramChannel, opacity: 0.4)
                .padding(Self.inset)
            Canvas(opaque: false, rendersAsynchronously: false) { ctx, _ in
                func at(_ x: Double, _ y: Double) -> CGPoint {
                    CGPoint(x: Self.inset + CGFloat(x) * s, y: Self.inset + CGFloat(1 - y) * s)
                }
                var grid = Path()
                for i in 1...3 {
                    let t = Double(i) / 4
                    grid.move(to: at(t, 0)); grid.addLine(to: at(t, 1))
                    grid.move(to: at(0, t)); grid.addLine(to: at(1, t))
                }
                ctx.stroke(grid, with: .color(.white.opacity(0.10)), lineWidth: 0.5)
                var diagonal = Path()
                diagonal.move(to: at(0, 0)); diagonal.addLine(to: at(1, 1))
                ctx.stroke(diagonal, with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
                let curve = MonotoneCurve(CurvePoints(points: pts))
                var line = Path()
                let steps = 160
                for i in 0...steps {
                    let x = Double(i) / Double(steps)
                    let p = at(x, curve.value(at: x))
                    if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                }
                let ink = Self.color(channel).opacity(shared.isMultiple ? 0.45 : 1)
                ctx.stroke(line, with: .color(ink), lineWidth: 1.5)
                for q in pts {
                    let c = at(q.x, q.y), r = Self.pointRadius
                    let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                    ctx.fill(dot, with: .color(Color(white: 0.13)))
                    ctx.stroke(dot, with: .color(ink), lineWidth: 1.25)
                }
            }
            if shared.isMultiple {
                Text("Multiple")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .gesture(dragGesture(s))
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { removeAt($0.location, s) })
        .accessibilityElement(children: .ignore)
        .help("Click to add a point and drag to move it. Double-click a point to remove it.")
        .accessibilityLabel("\(channel.title) curve")
        .accessibilityValue(Self.pointCount(pts.count))
        .accessibilityIdentifier("curves.editor")
    }

    static func pointCount(_ n: Int) -> String { n == 1 ? "1 point" : "\(n) points" }

    private func normalized(_ loc: CGPoint, _ s: CGFloat) -> CurvePoint {
        CurvePoint(x: Double((loc.x - Self.inset) / s), y: Double(1 - (loc.y - Self.inset) / s))
    }

    private func dragGesture(_ s: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if drag == nil {
                    let start = normalized(g.startLocation, s)
                    let current = points
                    if let i = CurveEditing.hit(current, at: start, radius: Double(Self.hitRadius / s)) {
                        drag = (i, current, current[i])
                        onEditing(true)
                    } else if let added = CurveEditing.add(current, at: start) {
                        // Click on empty graph: the point goes in where the click landed and
                        // the drag carries on with it.
                        drag = (added.index, added.points, added.points[added.index])
                        onEditing(true)
                        onSet(channel, CurvePoints(sanitising: added.points))
                    } else {
                        return
                    }
                }
                guard let d = drag, g.translation != .zero else { return }
                let to = CurvePoint(x: d.origin.x + Double(g.translation.width / s),
                                    y: d.origin.y - Double(g.translation.height / s))
                let moved = CurveEditing.move(d.points, index: d.index, to: to)
                drag = (d.index, moved, d.origin)
                onSet(channel, CurvePoints(sanitising: moved))
            }
            .onEnded { _ in
                guard drag != nil else { return }
                drag = nil
                onEditing(false)
            }
    }

    private func removeAt(_ loc: CGPoint, _ s: CGFloat) {
        let current = points
        guard let i = CurveEditing.hit(current, at: normalized(loc, s), radius: Double(Self.hitRadius / s)),
              let fewer = CurveEditing.remove(current, index: i) else { return }
        onSet(channel, CurvePoints(sanitising: fewer))
    }
}
