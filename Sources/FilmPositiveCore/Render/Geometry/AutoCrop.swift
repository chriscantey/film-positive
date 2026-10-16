import Foundation
import CoreGraphics

/// Which detector answered, and how far to believe it.
///
/// This lives in Core rather than beside the crop editor because it is domain logic, not UI.
/// A headless render has to draw the box the app would actually choose, and a rule written
/// out twice is a rule that will eventually disagree with itself.
public enum AutoCrop {

    /// Which of the four rungs produced a box. Measured on a set of 114 frames, best first,
    /// so the order is a measurement not a guess.
    public enum Route: String, Sendable {
        /// `CropPlanner` believed its own sweep. 46 of 114, median aspect error 0.77%, area
        /// 1.058x the kept crop. The sharpest answer we have.
        case plannerDetected
        /// `FrameFinder` closed a box on all four sides. 63 of 114 on its own, and 29 of those
        /// are frames the planner gives up on, which is the whole reason both are here.
        /// 2.38% aspect error, area 1.048x.
        case frameFinderBounded
        /// `CropPlanner` disbelieved the sweep and built the box from the expected format,
        /// sliding it onto one detected edge. Right shape by construction, so its shape score
        /// says nothing; area runs 1.243x, noticeably loose.
        case plannerAnchored
        /// `FrameFinder` found edges but could not close the box, a strip running off the
        /// picture. A real measurement of the sides it did find.
        case frameFinderPartial
        /// `CropDetector`, a box around everything that is not background. Last resort, and
        /// wrong whenever more than one frame is in view.
        case coarse
        /// `PerforationFrame` anchored the box on the film's own sprocket holes. It is not part
        /// of the ranking above, so it is listed last rather than ranked among the others.
        ///
        /// It is a MEASUREMENT despite building its width from the format's ratio, and the
        /// distinction is worth stating because `plannerAnchored` does something that looks
        /// similar and is not. The planner assumes the whole box and slides it until one side
        /// touches something. This rung measures the top and bottom edges against the
        /// perforations, measures both side edges by their own gradient and polarity, and uses
        /// the ratio only to choose among widths those edges already support.
        case perforationAnchored

        /// The box is a measurement of the film rather than a shape we assumed.
        public var isMeasured: Bool {
            self == .plannerDetected || self == .frameFinderBounded || self == .perforationAnchored
        }
    }

    public struct Result: Sendable {
        public let route: Route
        public let rect: CGRect
        /// Rotation the planner measured, degrees clockwise, zero on every other rung.
        /// Carried and deliberately NOT applied: straighten is the user's own control, and
        /// autocrop does not turn the picture as a side effect.
        public let angle: Double
        /// The format the planner built on. Only meaningful on `plannerDetected`: on
        /// `plannerAnchored` it is the size we told it to expect, so reading it back would be
        /// learning our own assumption.
        public let size: FilmSize?
        /// Sides where the film ran past what the camera could see.
        public let unboundedEdges: Set<CropDetector.Edge>

        public var isFullyBounded: Bool { unboundedEdges.isEmpty }
        /// False from the coarse fallback and the anchored plan, so a caller can say so rather
        /// than presenting a constructed box with the confidence of a found edge.
        public var isFrameEdge: Bool { route != .coarse && route != .plannerAnchored }

        public init(route: Route, rect: CGRect, angle: Double, size: FilmSize?,
                    unboundedEdges: Set<CropDetector.Edge>) {
            self.route = route; self.rect = rect; self.angle = angle
            self.size = size; self.unboundedEdges = unboundedEdges
        }
    }

    /// Run the perforation rung ahead of everything else. On by default.
    ///
    /// Scored against a set of 114 accepted crops: with the rung the chain measures 109 frames
    /// instead of 79, calibrated area error 5.65% to 5.01%, Vision3 18.3% to 4.9%, Arista 17.8%
    /// to 5.5%, and with it off the run reproduces the chain's own numbers to the digit. `FP_PERF=0` is the opt-out, kept so the two ladders can still be compared
    /// on the same frames rather than argued about.
    public static var perforationEnabled =
        ProcessInfo.processInfo.environment["FP_PERF"] != "0"

    /// The referee. When the perforation rung and the old chain BOTH measure a frame and
    /// their boxes disagree by more than this overlap, the old chain's box is kept and the
    /// event counted. The rung was tested on one rig, one holder and one format; a referee
    /// that needs no ground truth is what catches a confidently wrong box on a stranger's
    /// roll. Only measured chain routes referee: an anchored or coarse box is a guess and
    /// cannot outvote a measurement.
    public static var refereeMinOverlap = 0.5
    /// How many times the referee kept the chain's box, for a scoring run to report.
    public static var refereeKeptChain = 0

    /// The perforation rung on its own, exposed so a scoring run can measure it per frame
    /// rather than inferring it from which route the ladder happened to take.
    public static func perforation(in frame: DecodedFrame, expecting: FilmSize?,
                                   negative: DecodedFrame? = nil) -> Result? {
        guard var grid = ColorGrid.sample(frame, width: FrameRegion.analysisWidth) else { return nil }
        var negativeGrid = negative.flatMap { ColorGrid.sample($0, width: FrameRegion.analysisWidth) }
        // The rung measures the height ACROSS the strip, between the hole rows, and builds
        // the width ALONG it, so the ratio it needs is along over across: 36/24 for a full
        // frame, 18/24 for a half frame. `FilmSize.aspectRatio` is long over short and cannot
        // tell those two apart, so read the millimeters, with 24 as the across dimension.
        let want: Double
        if let e = expecting, let wmm = e.widthMM, let hmm = e.heightMM, wmm == 24 || hmm == 24 {
            want = (wmm == 24 ? hmm : wmm) / 24
        } else {
            want = expecting?.aspectRatio ?? 1.5
        }
        // The half-frame preset is the gate for the mat path and for the sideways case: a
        // half frame is shown upright, so the strip may arrive turned through a quarter and
        // the hole rows then run down the sides. Detect on the transposed grids and turn the
        // box back. Nothing here runs unless that preset is selected.
        let half = expecting?.name.lowercased().contains("half") ?? false
        let sideways = half && grid.height > grid.width
        if sideways {
            grid = transposed(grid)
            negativeGrid = negativeGrid.map(transposed)
        }
        guard let found = PerforationFrame.detect(in: grid, negative: negativeGrid,
                                                  aspect: want, mat: half)
        else { return nil }
        // A box that ran off the picture is a lower bound on the frame, so its shape says
        // nothing. Same rule, same reason, as `CropPlanner.accept`.
        guard !found.touchesBorder else { return nil }
        let w = Double(found.rect.width) * Double(grid.width)
        let h = Double(found.rect.height) * Double(grid.height)
        guard w > 0, h > 0 else { return nil }
        // A matted width is a measurement of the holder's window, not a ratio, so it is not
        // checked against one. Everything else must be the shape it was built to be.
        if !found.matted {
            let got = w / h
            guard abs(got - want) / want <= CropPlanner.aspectTolerance else { return nil }
        }
        var rect = found.rect
        if sideways {
            rect = CGRect(x: found.rect.minY, y: found.rect.minX,
                          width: found.rect.height, height: found.rect.width)
        }
        return Result(route: .perforationAnchored, rect: rect, angle: 0,
                      size: expecting, unboundedEdges: [])
    }

    /// The grid with rows and columns swapped, so a strip that arrived turned through a
    /// quarter reads as the horizontal strip the rung expects.
    static func transposed(_ g: ColorGrid) -> ColorGrid {
        var px: [ColorGrid.Pixel] = []
        px.reserveCapacity(g.width * g.height)
        for x in 0..<g.width {
            for y in 0..<g.height { px.append(g[x, y]) }
        }
        return ColorGrid(width: g.height, height: g.width, pixels: px)
    }

    /// Autocrop, ordered by what each rung scored on a set of scanned frames rather than by
    /// what each detector claims about itself.
    ///
    /// The two good detectors are complementary. There are 29 frames where `FrameFinder`
    /// closes a box and `CropPlanner` gives up, and 12 the other way. Either alone reaches a
    /// confident answer on 40 to 55 percent of the roll. Chained, they reach one on 66
    /// percent, which is why both are carried.
    ///
    /// `CropPlanner` goes first because when it detects it is the sharpest thing we
    /// have. Its OVERALL score looks better still and is not to be trusted: on the frames
    /// where it gives up it builds a box from the format it was told to expect, so of course
    /// that box measures 3:2. Only the detected route is evidence, which is also why
    /// `expecting` may be learned from that route alone.
    ///
    /// - Parameter expecting: the format this folder has been showing us. Without it the
    ///   anchored rung cannot build anything and about a third of a roll drops to the coarse
    ///   box.
    public static func detect(in frame: DecodedFrame, expecting: FilmSize? = nil,
                              negative: DecodedFrame? = nil) -> Result? {
        guard perforationEnabled,
              let anchored = perforation(in: frame, expecting: expecting, negative: negative)
        else { return chain(in: frame, expecting: expecting) }
        // The chain still runs, as the referee and the only second opinion available in the
        // field. It may overrule only with a box that could be a frame at all. Without that
        // check the referee defers to planner "detections" covering 3% and 6% of the picture
        // (Gold 0007 and 0013), which no 35mm frame on a copy stand can be, and throws away
        // two right boxes to do it. A second opinion that is absurd is not one.
        if let other = chain(in: frame, expecting: expecting), other.route.isMeasured,
           plausibleFrame(other.rect, expecting: expecting),
           overlap(anchored.rect, other.rect) < refereeMinOverlap {
            refereeKeptChain += 1
            return other
        }
        return anchored
    }

    /// Could this box be the frame? A single 35mm frame fills most of a copy-stand capture
    /// (the smallest of a set of 114 kept crops covers 0.70 of the picture) and has the
    /// format's shape. Loose on both counts: this only has to reject the absurd.
    static func plausibleFrame(_ rect: CGRect, expecting: FilmSize?) -> Bool {
        guard Double(rect.width * rect.height) >= 0.35 else { return false }
        guard let want = expecting?.aspectRatio, rect.width > 0, rect.height > 0 else { return true }
        // Normalized box on a 3:2 sensor, the same correction the scoring applies.
        let got = Double(max(rect.width, rect.height) / min(rect.width, rect.height)) * 1.5
        let ratio = max(got, want) / min(got, want)
        return ratio - 1 <= CropPlanner.aspectTolerance * 2
    }

    /// Intersection over union of two normalized boxes.
    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = Double(i.width * i.height)
        let union = Double(a.width * a.height + b.width * b.height) - inter
        return union > 0 ? inter / union : 0
    }

    /// The ladder without the perforation rung: planner, FrameFinder, anchored plan, partial
    /// FrameFinder, coarse.
    static func chain(in frame: DecodedFrame, expecting: FilmSize?) -> Result? {
        let plan = CropPlanner.plan(in: frame, expecting: expecting)

        if let plan, plan.route == .detected {
            return Result(route: .plannerDetected, rect: plan.rect, angle: plan.angle,
                          size: plan.size, unboundedEdges: [])
        }
        if let found = FrameFinder.detect(in: frame), found.unboundedEdges.isEmpty {
            return Result(route: .frameFinderBounded, rect: found.rect, angle: 0,
                          size: nil, unboundedEdges: [])
        }
        if let plan {
            // Every side except the one it pinned is an assumption, and saying so is what
            // keeps `isFullyBounded` honest: a useful crop, never a measurement.
            let unbounded = Set(CropDetector.Edge.allCases)
                .subtracting(plan.anchoredEdge.map { [$0] } ?? [])
            return Result(route: .plannerAnchored, rect: plan.rect, angle: plan.angle,
                          size: nil, unboundedEdges: unbounded)
        }
        // FrameFinder may still have an answer, just not a closed one: a strip running off
        // both sides bounds two edges and not the other two. Better than the coarse box,
        // which would put the crop around the whole strip.
        if let found = FrameFinder.detect(in: frame) {
            return Result(route: .frameFinderPartial, rect: found.rect, angle: 0,
                          size: nil, unboundedEdges: found.unboundedEdges)
        }
        if let coarse = CropDetector.detect(in: frame) {
            return Result(route: .coarse, rect: coarse.rect, angle: 0,
                          size: nil, unboundedEdges: coarse.unboundedEdges)
        }
        return nil
    }
}

/// What a folder has taught us about the frames in it.
///
/// The anchored route builds its box from a format's NOMINAL dimensions and whatever scale it
/// can infer from one picture. Measured over a set of 114 frames it lands consistently large:
/// median area 0.9375 of the picture against 0.7647 for the frames the sweep actually
/// measured, a tight band rather than scattered noise. A consistent error with a small spread
/// is a calibration problem, not a detection problem, and it is the cheaper one to fix.
///
/// So: remember the size of every box we genuinely MEASURED in this folder, and use the median
/// of those to resize a box we merely BUILT. An operator works a stack of the same film on the
/// same stand, so by the third or fourth frame the roll knows its own scale far better than
/// any single fallback can guess it.
///
/// Only measured routes teach. Learning from an anchored box would feed the fallback its own
/// output, which is the same circularity `CropPlanner` avoids by learning film size from
/// `.detected` alone.
public struct FrameScale: Sendable {
    private var widths: [CGFloat] = []
    private var heights: [CGFloat] = []

    public init() {}

    /// How many measurements before the median is worth trusting. Two is not a median and one
    /// is an anecdote; three is the point where a single odd frame stops deciding the roll.
    public static let minSamples = 3

    public var sampleCount: Int { widths.count }
    public var isCalibrated: Bool { widths.count >= Self.minSamples }

    /// Learn from a result, if it is the kind of result that may teach.
    public mutating func learn(from result: AutoCrop.Result) {
        guard result.route.isMeasured else { return }
        widths.append(result.rect.width)
        heights.append(result.rect.height)
    }

    private func median(_ v: [CGFloat]) -> CGFloat {
        let s = v.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }

    /// Resize a built box to the size this folder has been measuring, holding the edge the
    /// planner pinned so the correction shrinks away from the anchor rather than sliding the
    /// box off the frame it found.
    ///
    /// A measured result is returned untouched. It is the evidence; correcting it against a
    /// median of itself would only blur it.
    public func refined(_ result: AutoCrop.Result) -> AutoCrop.Result {
        guard result.route == .plannerAnchored, isCalibrated else { return result }
        let w = median(widths), h = median(heights)
        guard w > 0, h > 0 else { return result }

        // Hold the anchored edge still; otherwise hold the center.
        let pinned = Set(CropDetector.Edge.allCases).subtracting(result.unboundedEdges).first
        var x = result.rect.midX - w / 2
        var y = result.rect.midY - h / 2
        switch pinned {
        case .left:   x = result.rect.minX
        case .right:  x = result.rect.maxX - w
        case .top:    y = result.rect.minY
        case .bottom: y = result.rect.maxY - h
        case nil:     break
        }
        return AutoCrop.Result(route: .plannerAnchored,
                               rect: CGRect(x: x, y: y, width: w, height: h),
                               angle: result.angle, size: result.size,
                               unboundedEdges: result.unboundedEdges)
    }
}
