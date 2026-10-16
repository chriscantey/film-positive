import Foundation
import FilmSidecar

// The batch export loop.
//
// Export always runs over a selection: every entry point in the app (the menu bar, the
// gallery toolbar, the closeup toolbar, the frame context menu) opens the Export sheet,
// and the sheet exports one frame at a time. The memory guarantee is a property of THAT
// loop, so the loop lives here where it can be stated and tested rather than in the view
// that happens to draw the progress bar.
//
// The discipline is one sentence: develop a frame, write it, drop it, then start the next
// one. Nothing about a finished frame is retained across an iteration, so the resident
// working set of a hundred-frame export is the working set of its largest single frame.

/// Everything the export loop needs about one frame, as values, so the work can run off
/// the main actor while the sidecars keep changing under the user.
///
/// Values rather than a frame reference on purpose: a type reaching into the main-actor
/// model would not be free to cross to a detached task, and a snapshot taken when Export
/// is pressed is also the honest thing to write. What the user saw in the dialog is what
/// lands on disk, whatever they edit while it runs.
public struct ExportTarget: Sendable {
    /// The raw the frame is developed from.
    public let url: URL
    /// The output basename, before the format's extension.
    public let stem: String
    public let develop: DevelopSettings
    public let geometry: GeometrySettings
    public let enhance: EnhanceSettings
    public let lookID: String?
    public let capture: CaptureInfo?

    public init(url: URL, stem: String, develop: DevelopSettings, geometry: GeometrySettings,
                enhance: EnhanceSettings, lookID: String?, capture: CaptureInfo?) {
        self.url = url; self.stem = stem; self.develop = develop; self.geometry = geometry
        self.enhance = enhance; self.lookID = lookID; self.capture = capture
    }
}

public enum BatchExport {

    /// One frame: develop at full scale with identity enhance, bake the look through the
    /// exporter's one pipeline, write. Runs wherever it is called from.
    public static func exportOne(_ t: ExportTarget, with service: any RenderService, exporter: Exporter,
                                 to folder: URL, mode: ExportMode, format: ExportFormat,
                                 colorSpace: ExportColorSpace, appVersion: String) async throws -> URL {
        let request = RenderRequest(imageURL: t.url, develop: t.develop, geometry: t.geometry, enhance: .identity, scale: .full)
        let developed = try await service.render(request).frame
        let raw = try? RawMetadata.read(t.url)
        let meta = ExportMetadata.from(raw: raw, capture: t.capture, develop: t.develop, mode: mode,
                                       lookName: t.lookID, appVersion: appVersion)
        let out = folder.appendingPathComponent(t.stem).appendingPathExtension(format.fileExtension)
        // Written beside the target and swapped in whole, so a Stop or a crash mid-write
        // never leaves a truncated file where a good earlier export was.
        let part = folder.appendingPathComponent(".\(t.stem).\(UUID().uuidString).\(format.fileExtension)")
        try autoreleasepool {
            let rendered = try exporter.render(developed: developed, mode: mode, look: t.enhance)
            try exporter.write(rendered, to: part, format: format, colorSpace: colorSpace, metadata: meta)
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: out.path) {
            _ = try fm.replaceItemAt(out, withItemAt: part)
        } else {
            try fm.moveItem(at: part, to: out)
        }
        return out
    }

    /// The whole selection, sequentially, one frame in flight.
    ///
    /// Each frame's develop and write happen inside a detached task whose only result is a
    /// URL, so the frame itself is unreachable the moment that task returns and cannot be
    /// held into the next iteration. That detach is also what keeps the pixels off the main
    /// actor when the caller's task is a main-actor one, which every caller in the app is.
    ///
    /// A frame in flight always finishes: `isCancelled` is read between frames, never
    /// inside one, so Stop never leaves a half-written export behind.
    ///
    /// `progress` is called once per target, in order, with that target's index and what
    /// became of it. A failure is reported and the loop continues, because one unreadable
    /// raw in a selection of ninety is not a reason to abandon the other eighty-nine.
    ///
    /// The caller creates `folder`. The loop does not, so that a folder that cannot be
    /// created is one failure the caller reports rather than N identical ones.
    public static func run(_ targets: [ExportTarget], with service: any RenderService, exporter: Exporter,
                           to folder: URL, mode: ExportMode, format: ExportFormat,
                           colorSpace: ExportColorSpace, appVersion: String,
                           isCancelled: @Sendable () -> Bool = { false },
                           progress: @Sendable (Int, Result<URL, Error>) async -> Void) async {
        for (i, t) in targets.enumerated() {
            if isCancelled() { return }
            let outcome: Result<URL, Error>
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try await exportOne(t, with: service, exporter: exporter, to: folder,
                                        mode: mode, format: format, colorSpace: colorSpace, appVersion: appVersion)
                }.value
                outcome = .success(url)
            } catch {
                outcome = .failure(error)
            }
            await progress(i, outcome)
        }
    }
}
