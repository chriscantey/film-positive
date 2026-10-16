import XCTest
import AppKit
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Arrow presses away from a slider's resting value and back land ON the resting value, not
/// next to it.
///
/// A step such as 0.01 has no exact binary form, so plain addition drifts: three presses
/// right and three left from 0 end on -3.5e-18. The readout rounds that to "0.00", but every
/// question that compares against 0 (the reset mark, the summary, `isIdentity`, the sidecar
/// writer) still sees an adjusted row. `CentreOriginTrack.stepped` removes the residue where
/// the value is produced, so every caller sees the exact resting value.
final class SliderStepRestTests: XCTestCase {

    private typealias T = CentreOriginTrack

    /// Press counts, chosen to include the first counts that drift with plain addition.
    private let counts = [1, 2, 3, 4, 5, 7, 10, 13, 25, 50, 99]

    /// `count` presses of `step` from `start`, then `count` presses back, through the
    /// track's own arithmetic.
    private func roundTrip(from start: Double, step: Double, keyStep: Double, neutral: Double, count: Int) -> Double {
        var v = start
        for _ in 0..<count { v = T.stepped(v, by: step, keyStep: keyStep, neutral: neutral) }
        for _ in 0..<count { v = T.stepped(v, by: -step, keyStep: keyStep, neutral: neutral) }
        return v
    }

    /// Every track that steps by arrow key, with its own step and neutral: an Enhance row,
    /// a Base color axis, and the Tone rows, whose steps are 0.1, 0.05 and 1.
    private var tracks: [(name: String, keyStep: Double, neutral: Double)] {
        [("enhance", T.defaultKeyStep, 0), ("colour axis", ColourAxis.keyStep, 0)]
            + ToneSlider.allCases.map { ("tone \($0.rawValue)", $0.keyStep, $0.neutral) }
    }

    /// The negative control: plain addition, which is what an arrow press computed before,
    /// does NOT come back to 0, while the readout says it did. Without this the test below
    /// could pass on arithmetic that never drifted.
    func testPlainAdditionDriftsWhileTheReadoutSaysZero() {
        var v = 0.0
        for _ in 0..<3 { v += T.defaultKeyStep }
        for _ in 0..<3 { v -= T.defaultKeyStep }
        XCTAssertNotEqual(v, 0, "plain addition came back exactly, so this test proves nothing")
        XCTAssertEqual((v * 100).rounded() / 100 + 0, 0, "the readout should round the residue to 0.00")
    }

    func testStepsAwayAndBackByTheRowStepLandOnTheNeutralExactly() {
        for t in tracks {
            let step = T.step(t.keyStep, modifiers: [])
            for n in counts {
                for direction in [1.0, -1.0] {
                    let v = roundTrip(from: t.neutral, step: direction * step, keyStep: t.keyStep, neutral: t.neutral, count: n)
                    XCTAssertEqual(v, t.neutral, "\(t.name): \(n) presses \(direction > 0 ? "right" : "left") and back ended on \(v)")
                }
            }
        }
    }

    func testStepsAwayAndBackByTheFineStepLandOnTheNeutralExactly() {
        for t in tracks {
            let step = T.step(t.keyStep, modifiers: .shift)
            XCTAssertLessThan(step, t.keyStep, "\(t.name): shift should be the fine step")
            for n in counts {
                for direction in [1.0, -1.0] {
                    let v = roundTrip(from: t.neutral, step: direction * step, keyStep: t.keyStep, neutral: t.neutral, count: n)
                    XCTAssertEqual(v, t.neutral, "\(t.name): \(n) fine presses \(direction > 0 ? "right" : "left") and back ended on \(v)")
                }
            }
        }
    }

    /// One row step out, ten fine steps back: the two step sizes share one grid.
    func testOneRowStepUndoneByTenFineStepsLandsOnTheNeutral() {
        for t in tracks {
            let coarse = T.step(t.keyStep, modifiers: [])
            let fine = T.step(t.keyStep, modifiers: .shift)
            for presses in [1, 3, 5] {
                var v = t.neutral
                for _ in 0..<presses { v = T.stepped(v, by: coarse, keyStep: t.keyStep, neutral: t.neutral) }
                for _ in 0..<(presses * 10) { v = T.stepped(v, by: -fine, keyStep: t.keyStep, neutral: t.neutral) }
                XCTAssertEqual(v, t.neutral, "\(t.name): \(presses) row steps out and fine steps back ended on \(v)")
            }
        }
    }

    /// A value between grid points, which a drag or a typed number puts there, is carried
    /// exactly: the snap only removes rounding residue, it never moves a real value.
    func testAValueBetweenGridPointsIsNotMoved() {
        for v in [0.3456, -0.0044, 0.12345678, 1.8e-7, -2.75] {
            XCTAssertEqual(T.stepped(v, by: 0.01, keyStep: T.defaultKeyStep, neutral: 0), v + 0.01)
            XCTAssertEqual(T.stepped(v, by: -0.001, keyStep: T.defaultKeyStep, neutral: 0), v - 0.001)
        }
    }

    // MARK: the row, the summary and the sidecar

    private func developedSidecar() -> Sidecar {
        var s = Sidecar(source: SidecarSource(name: "IMG_0001.CR2", size: 64,
                                              mtime: Date(timeIntervalSince1970: 1_700_000_000), fingerprint: "f"))
        s.develop = DevelopSettings(stock: "kodak-gold-200", autoTone: true, base: BaseSettings(mode: .anchor))
        return s
    }

    /// One arrow press on an Enhance row, written the way the inspector writes it: the
    /// row's value stepped by the track, then set through the control onto the sidecar.
    private func press(_ control: EnhanceControl, _ sidecar: Sidecar, by delta: Double) -> Sidecar {
        let current = sidecar.enhance ?? .identity
        let v = T.stepped(control.value(in: current), by: delta, keyStep: T.defaultKeyStep, neutral: 0)
        let updated = control.setting(current, to: v)
        guard updated != current else { return sidecar }
        return SidecarEdits.setEnhance(sidecar, updated)
    }

    private func bytes(_ s: Sidecar) throws -> Data {
        try XMPSidecarCodec.encode(s.withLiveFields, into: XMPSidecarCodec.emptyPacket())
    }

    /// Stepped away and back on four controls (Vignette Amount carries a sign of -1), by
    /// the row step and by the fine step: the row reads 0, the summary says 0, the layer
    /// is gone and the sidecar encodes to the same bytes as one never touched.
    func testAnEnhanceRowSteppedBackReadsUntouchedAndWritesTheSameBytes() throws {
        let untouched = developedSidecar()
        let untouchedBytes = try bytes(untouched)
        let ids = ["exposure", "warmth", "noiseReduction", "vignette"]
        let controls = EnhanceControl.all.filter { ids.contains($0.id) }
        XCTAssertEqual(controls.count, ids.count)
        for control in controls {
            for modifiers in [NSEvent.ModifierFlags(), .shift] {
                let step = T.step(T.defaultKeyStep, modifiers: modifiers)
                for n in [3, 5, 7, 10] {
                    var s = untouched
                    for _ in 0..<n { s = press(control, s, by: step) }
                    XCTAssertNotNil(s.enhance, "\(control.id): stepping away should write an enhance layer")
                    for _ in 0..<n { s = press(control, s, by: -step) }
                    let label = "\(control.id), \(n) \(modifiers.isEmpty ? "row" : "fine") steps"
                    XCTAssertEqual(control.value(in: s.enhance ?? .identity), 0, label)
                    XCTAssertNil(s.enhance, "\(label): the enhance layer should be gone")
                    XCTAssertEqual(SelectionSummary([s]).value(for: control), .uniform(0), label)
                    XCTAssertEqual(s, untouched, label)
                    XCTAssertEqual(try bytes(s), untouchedBytes, "\(label): sidecar bytes differ from untouched")
                }
            }
        }
    }
}
