import XCTest
import CoreGraphics
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The crop grips reach the editor with the crop at full frame.
///
/// At full frame every grip sits on the picture's edge. A pane that takes presses only from
/// the picture's own rectangle leaves the outer half of a side grip and three quarters of a
/// corner grip outside it: measured that way, 9 of 40 presses resized under Original and 8 of
/// 40 under Freeform at full frame, and 40 of 40 in both with an inset crop. A side drag under
/// Original shrinks the box about its center, which pulls all four corners inside the
/// picture, so corners worked only after a side had been dragged.
///
/// The pane's hit area grows by one grip target (`CropPane.hitArea`), and a press outside the
/// picture takes a grip and nothing else (`CropEditor.zone`).
final class CropGripReachTests: XCTestCase {
    /// An 814 by 543 point box, the size measured on screen.
    static let box = CGSize(width: 814, height: 543)
    static var tolerance: CGSize {
        CGSize(width: CropPane.gripPoints / box.width, height: CropPane.gripPoints / box.height)
    }
    static var band: CGSize {
        CGSize(width: CropPane.bandPoints / box.width, height: CropPane.bandPoints / box.height)
    }
    static let inset = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
    static let handles: [CropBox.Handle] = [.topLeft, .top, .topRight, .left, .right, .bottomLeft, .bottom, .bottomRight]
    /// The scatter the on-screen matrix used: dead center and 3 points each way.
    static let offsets: [CGVector] = [.init(dx: 0, dy: 0), .init(dx: -3, dy: 0), .init(dx: 3, dy: 0),
                                      .init(dx: 0, dy: -3), .init(dx: 0, dy: 3)]

    private func editor(_ aspect: CropAspect, full: Bool) -> CropEditor {
        var e = CropEditor(geometry: GeometrySettings(), originalAspect: 1.5)
        if !full {
            e.aspect = .freeform
            e.begin(at: CGPoint(x: 0, y: 0))
            e.drag(to: CGPoint(x: Self.inset.minX, y: Self.inset.minY))
            e.end()
            e.begin(at: CGPoint(x: 1, y: 1))
            e.drag(to: CGPoint(x: Self.inset.maxX, y: Self.inset.maxY))
            e.end()
        }
        e.aspect = aspect
        return e
    }

    private func grip(_ h: CropBox.Handle, in r: CGRect) -> CGPoint {
        CropBox.handlePositions(in: r).first { $0.0 == h }!.1
    }

    /// Inward, in normalized units, 40 points on the box.
    private func inward(_ h: CropBox.Handle) -> CGSize {
        let x: CGFloat = [.topLeft, .left, .bottomLeft].contains(h) ? 1 : ([.topRight, .right, .bottomRight].contains(h) ? -1 : 0)
        let y: CGFloat = [.topLeft, .top, .topRight].contains(h) ? 1 : ([.bottomLeft, .bottom, .bottomRight].contains(h) ? -1 : 0)
        return CGSize(width: x * 40 / Self.box.width, height: y * 40 / Self.box.height)
    }

    private func fmt(_ r: CGRect) -> String {
        String(format: "x %.4f..%.4f y %.4f..%.4f", r.minX, r.maxX, r.minY, r.maxY)
    }

    /// The cause itself: every grip's whole target lies inside the rectangle the pane takes
    /// presses from, for a full frame box and an inset one, on a wide and a tall pane.
    func testEveryGripTargetIsInsideThePaneHitArea() {
        for box in [Self.box, CGSize(width: 400, height: 600)] {
            let hit = CropPane.hitArea(box: box)
            for rect in [CropEditor.unit, Self.inset] {
                for (h, p) in CropBox.handlePositions(in: rect) {
                    let centre = CGPoint(x: p.x * box.width, y: p.y * box.height)
                    let target = CGRect(x: centre.x - CropPane.gripPoints, y: centre.y - CropPane.gripPoints,
                                        width: CropPane.gripPoints * 2, height: CropPane.gripPoints * 2)
                    XCTAssertTrue(hit.contains(target), "\(h) on \(fmt(rect)) in \(box): target \(target) outside \(hit)")
                }
            }
        }
    }

    /// Every grip, both modes, full frame and inset, five presses each: the press takes the
    /// grip it is on and an inward drag resizes. Prints the zone for every press.
    func testEveryGripTakesEveryPressFirstTime() {
        for full in [true, false] {
            for aspect in [CropAspect.freeform, .original] {
                var resized = 0, total = 0
                for h in Self.handles {
                    for o in Self.offsets {
                        var e = editor(aspect, full: full)
                        let before = e.displayRect
                        let g = grip(h, in: before)
                        let p = CGPoint(x: g.x + o.dx / Self.box.width, y: g.y + o.dy / Self.box.height)
                        let zone = e.begin(at: p, tolerance: Self.tolerance, rotateBand: Self.band)
                        let d = inward(h)
                        e.drag(to: CGPoint(x: p.x + d.width, y: p.y + d.height))
                        e.end()
                        let after = e.displayRect
                        let changedSize = abs(after.width - before.width) > 1e-6 || abs(after.height - before.height) > 1e-6
                        total += 1
                        if zone == .resize(h) && changedSize { resized += 1 }
                        print(String(format: "GRIP %@ %@ %@ off(%+.0f,%+.0f) zone=%@ before[%@] after[%@]",
                                     full ? "full" : "inset", aspect.name, "\(h)", o.dx, o.dy, "\(zone)",
                                     fmt(before), fmt(after)))
                        XCTAssertEqual(zone, .resize(h), "\(full ? "full" : "inset") \(aspect.name) \(h) off \(o)")
                        XCTAssertTrue(changedSize, "\(full ? "full" : "inset") \(aspect.name) \(h) off \(o) did not resize")
                    }
                }
                print("GRIP SUMMARY \(full ? "full" : "inset") \(aspect.name): \(resized)/\(total)")
            }
        }
    }

    /// Outside the picture a press takes a grip or nothing. The rotate band and the move
    /// stay where they were reachable before the hit area grew.
    func testOutsideThePictureOnlyAGripAnswers() {
        let e = editor(.original, full: true)
        // 8 points out past the left edge, 20 points down from the top left grip: outside
        // the grip target, inside the band the arithmetic alone would call rotate.
        let p = CGPoint(x: -8 / Self.box.width, y: 20 / Self.box.height)
        let raw = CropBox.zone(at: p, in: e.displayRect, tolerance: Self.tolerance, rotateBand: Self.band)
        guard case .rotate = raw else { return XCTFail("the fixture should be in the rotate band, got \(raw)") }
        XCTAssertEqual(CropEditor.zone(at: p, in: e.displayRect, tolerance: Self.tolerance, rotateBand: Self.band),
                       CropBox.Zone.none)
        // and the grip out there still answers
        let q = CGPoint(x: -3 / Self.box.width, y: 0)
        XCTAssertEqual(CropEditor.zone(at: q, in: e.displayRect, tolerance: Self.tolerance, rotateBand: Self.band),
                       .resize(.topLeft))
        print("GRIP outside: raw \(raw), editor \(CropEditor.zone(at: p, in: e.displayRect, tolerance: Self.tolerance, rotateBand: Self.band))")
    }

    /// Inside the picture the rotate band straightens, the interior moves the box, and a
    /// corner still resizes from its corner.
    func testRotateBandInteriorAndCornersAreAsBefore() {
        for aspect in [CropAspect.freeform, .original] {
            var e = editor(aspect, full: false)
            let start = e.displayRect

            // rotate band: 20 points out from the top left grip, inside the picture
            var r = e
            let rp = CGPoint(x: start.minX - 20 / Self.box.width, y: start.minY - 20 / Self.box.height)
            let rz = r.begin(at: rp, tolerance: Self.tolerance, rotateBand: Self.band)
            guard case .rotate = rz else { return XCTFail("\(aspect.name): expected rotate, got \(rz)") }
            r.drag(to: CGPoint(x: rp.x + 0.02, y: rp.y - 0.02))
            r.end()
            XCTAssertNotEqual(r.degrees, 0)
            XCTAssertEqual(r.displayRect, start, "straightening leaves the box alone")
            print("GRIP rotate \(aspect.name) zone=\(rz) degrees \(r.degrees) before[\(fmt(start))] after[\(fmt(r.displayRect))]")

            // interior moves
            var m = e
            let mz = m.begin(at: CGPoint(x: start.midX, y: start.midY), tolerance: Self.tolerance, rotateBand: Self.band)
            XCTAssertEqual(mz, .move)
            m.drag(to: CGPoint(x: start.midX + 0.05, y: start.midY + 0.03))
            m.end()
            XCTAssertEqual(m.displayRect.width, start.width, accuracy: 1e-9)
            XCTAssertEqual(m.displayRect.minX, start.minX + 0.05, accuracy: 1e-9)
            XCTAssertEqual(m.displayRect.minY, start.minY + 0.03, accuracy: 1e-9)
            print("GRIP move \(aspect.name) zone=\(mz) before[\(fmt(start))] after[\(fmt(m.displayRect))]")

            // a corner keeps its opposite corner
            let cz = e.begin(at: CGPoint(x: start.maxX, y: start.maxY), tolerance: Self.tolerance, rotateBand: Self.band)
            XCTAssertEqual(cz, .resize(.bottomRight))
            e.drag(to: CGPoint(x: start.maxX - 0.05, y: start.maxY - 0.05))
            e.end()
            XCTAssertEqual(e.displayRect.minX, start.minX, accuracy: 1e-9)
            XCTAssertEqual(e.displayRect.minY, start.minY, accuracy: 1e-9)
            print("GRIP corner \(aspect.name) zone=\(cz) before[\(fmt(start))] after[\(fmt(e.displayRect))]")
        }
    }
}
