import Foundation
import os

/// Slider to pixel, measured with `OSSignposter`.
///
/// The interval opens when an inspector control writes a new value through
/// `AppModel.apply`, and closes when pixels for that new state actually reach a view: the
/// histogram reads `RenderCoordinator`'s cached image, and the cache entry carries the
/// `RenderRequest` that produced it, so "the pixels on screen match the current sidecar"
/// is a fact the view can observe rather than a moment it has to guess.
///
/// That is the whole chain the criterion is about: value change, `apply`, invalidate,
/// render, cache, SwiftUI update, pixels. Ending the interval anywhere earlier (at `apply`,
/// or when the render task is spawned) would measure the cheap half and always pass.
///
/// Set `FP_SIGNPOST_LOG=1` to also print each interval and a summary to stdout, which is
/// how the number gets recorded from a headless ssh run.
@MainActor
final class SliderLatency {
    static let shared = SliderLatency()

    static let subsystem = "co.wonders.filmpositive"
    private let signposter = OSSignposter(subsystem: SliderLatency.subsystem, category: "Inspector")
    private let logToStdout = ProcessInfo.processInfo.environment["FP_SIGNPOST_LOG"] == "1"

    private struct Pending {
        let id: OSSignpostID
        let state: OSSignpostIntervalState
        let started: DispatchTime
        let control: String
    }

    private var pending: [URL: Pending] = [:]
    /// Every completed interval in milliseconds, in order, for the summary.
    private(set) var samples: [Double] = []

    private init() {}

    /// Called by an inspector control the moment it writes a new value.
    func edited(frame: URL, control: String) {
        // A drag fires many times. The open interval is the oldest edit whose pixels have
        // not landed, which is the honest thing to measure: it is what the eye is waiting
        // for. Replacing it on every tick would measure only the last tick of a drag.
        guard pending[frame] == nil else { return }
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval("slider-to-pixel", id: id, "\(control, privacy: .public)")
        pending[frame] = Pending(id: id, state: state, started: .now(), control: control)
    }

    /// Called when a view has pixels whose `RenderRequest` matches the frame's current
    /// state. Returns the elapsed milliseconds when an interval was open.
    @discardableResult
    func pixelsLanded(frame: URL) -> Double? {
        guard let p = pending.removeValue(forKey: frame) else { return nil }
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- p.started.uptimeNanoseconds) / 1_000_000
        signposter.endInterval("slider-to-pixel", p.state, "\(p.control, privacy: .public)")
        samples.append(ms)
        if logToStdout {
            print(String(format: "[signpost] slider-to-pixel %@ %.1f ms", p.control, ms))
            fflush(stdout)
        }
        return ms
    }

    /// Drops an open interval without recording it (the frame went away mid-render).
    func cancel(frame: URL) {
        guard let p = pending.removeValue(forKey: frame) else { return }
        signposter.endInterval("slider-to-pixel", p.state, "cancelled")
    }

    func resetSamples() { samples.removeAll() }

    var summary: String {
        guard !samples.isEmpty else { return "no slider-to-pixel intervals recorded" }
        let sorted = samples.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let mean = samples.reduce(0, +) / Double(samples.count)
        return String(format: "slider-to-pixel n=%d min %.1f ms  p50 %.1f ms  mean %.1f ms  p95 %.1f ms  max %.1f ms",
                      samples.count, sorted.first ?? 0, p50, mean, p95, sorted.last ?? 0)
    }
}
