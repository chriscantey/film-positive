import Foundation
import CoreGraphics

/// Bounding box of everything in a frame that is not the background: the seed for the
/// crop tool. The sampler reads our 16-bit frame.
///
/// The approach suits a copy stand: the frame is overwhelmingly background (light table
/// or holder mask) with one rectangular region that differs from it. Estimate the
/// background from the border ring, mark every pixel unlike it, and take the bounding box
/// of the mask on projection profiles, so an isolated speck contributes one count to its
/// row and column and is filtered by the coverage threshold while a real film edge counts
/// in every row it spans.
public enum CropDetector {
    public enum Edge: String, CaseIterable, Sendable { case left, right, top, bottom }

    public struct Result: Equatable, Sendable {
        /// Normalized [0,1]², y-down, in the frame's own orientation.
        public let rect: CGRect
        /// Fraction of sampled pixels that differed from the background.
        public let coverage: Double
        /// Sides where content runs to the frame edge: the negative continues beyond view.
        public let unboundedEdges: Set<Edge>
        public var isFullyBounded: Bool { unboundedEdges.isEmpty }
        public init(rect: CGRect, coverage: Double, unboundedEdges: Set<Edge> = []) {
            self.rect = rect; self.coverage = coverage; self.unboundedEdges = unboundedEdges
        }
    }

    /// Width the frame is reduced to before analysis; edges are a large-scale feature.
    public static let analysisWidth = 256
    /// Luminance difference from the background that counts as content, 0 to 1.
    public static let defaultThreshold = 0.10
    /// Fraction of a row or column that must be marked; the dust filter.
    public static let defaultCoverage = 0.20

    public static func detect(in frame: DecodedFrame, threshold: Double = defaultThreshold,
                              minCoverage: Double = defaultCoverage, marginFraction: Double = 0) -> Result? {
        guard let sample = luminanceGrid(of: frame) else { return nil }
        return detect(grid: sample, threshold: threshold, minCoverage: minCoverage, marginFraction: marginFraction)
    }

    static func detect(grid sample: Grid, threshold: Double, minCoverage: Double, marginFraction: Double) -> Result? {
        let w = sample.width, h = sample.height
        guard w > 2, h > 2 else { return nil }
        // Background = median of the border ring, so a negative running off the edge or a
        // bright speck on the mask does not drag the estimate toward the content.
        var border: [Double] = []
        border.reserveCapacity(2 * (w + h))
        for x in 0..<w { border.append(sample[x, 0]); border.append(sample[x, h - 1]) }
        for y in 0..<h { border.append(sample[0, y]); border.append(sample[w - 1, y]) }
        border.sort()
        let background = border[border.count / 2]

        var rowCounts = [Int](repeating: 0, count: h)
        var colCounts = [Int](repeating: 0, count: w)
        var marked = 0
        for y in 0..<h {
            for x in 0..<w where abs(sample[x, y] - background) > threshold {
                rowCounts[y] += 1; colCounts[x] += 1; marked += 1
            }
        }
        let coverage = Double(marked) / Double(w * h)
        guard marked > 0 else { return nil }
        guard let (top, bottom) = span(rowCounts, of: w, minCoverage: minCoverage),
              let (left, right) = span(colCounts, of: h, minCoverage: minCoverage) else { return nil }

        var rect = CGRect(x: Double(left) / Double(w), y: Double(top) / Double(h),
                          width: Double(right - left + 1) / Double(w), height: Double(bottom - top + 1) / Double(h))
        var unbounded: Set<Edge> = []
        if left == 0 { unbounded.insert(.left) }
        if right == w - 1 { unbounded.insert(.right) }
        if top == 0 { unbounded.insert(.top) }
        if bottom == h - 1 { unbounded.insert(.bottom) }
        guard unbounded.count < Edge.allCases.count else { return nil }
        if marginFraction > 0 {
            rect = rect.insetBy(dx: -marginFraction, dy: -marginFraction).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Result(rect: rect, coverage: coverage, unboundedEdges: unbounded)
    }

    private static func span(_ counts: [Int], of extent: Int, minCoverage: Double) -> (Int, Int)? {
        let needed = Int((Double(extent) * minCoverage).rounded(.up))
        guard let first = counts.firstIndex(where: { $0 >= needed }), let last = counts.lastIndex(where: { $0 >= needed }) else { return nil }
        return (first, last)
    }

    struct Grid {
        let width: Int
        let height: Int
        let values: [Double]
        subscript(x: Int, y: Int) -> Double { values[y * width + x] }
    }

    /// Box-averaged luminance at `analysisWidth`, from a display-referred 16-bit frame.
    /// Averaging is what shrinks specks.
    static func luminanceGrid(of f: DecodedFrame) -> Grid? {
        guard f.width > 0, f.height > 0 else { return nil }
        let w = min(analysisWidth, f.width)
        let h = max(1, Int((Double(f.height) / Double(f.width) * Double(w)).rounded()))
        var values = [Double](repeating: 0, count: w * h)
        f.pixels.withUnsafeBufferPointer { p in
            for gy in 0..<h {
                let y0 = gy * f.height / h, y1 = max(y0 + 1, (gy + 1) * f.height / h)
                for gx in 0..<w {
                    let x0 = gx * f.width / w, x1 = max(x0 + 1, (gx + 1) * f.width / w)
                    var sum = 0.0
                    for y in y0..<y1 {
                        var i = (y * f.width + x0) * 3
                        for _ in x0..<x1 {
                            sum += 0.2126 * Double(p[i]) + 0.7152 * Double(p[i + 1]) + 0.0722 * Double(p[i + 2])
                            i += 3
                        }
                    }
                    values[gy * w + gx] = sum / Double((y1 - y0) * (x1 - x0)) / 65535
                }
            }
        }
        return Grid(width: w, height: h, values: values)
    }
}
