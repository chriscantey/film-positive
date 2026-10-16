import SwiftUI
import AppKit
import FilmSidecar
import FilmPositiveCore

/// Export over the selection, the only way the app exports, like its other global actions.
///
/// Mode, format and color space are preferences and never sidecar fields, so
/// the sheet reads its defaults from `Preferences` and writes them back on Export. The
/// engine side is the shipped `Exporter`: develop at full scale with identity enhance,
/// then the one pipeline bakes the look or not. One frame is in flight at a time and each
/// is released before the next starts.
struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var mode: ExportMode = .neutral
    @State private var format: ExportFormat = .heic
    @State private var colorSpace: ExportColorSpace = .sRGB
    @State private var folder: URL?

    @State private var run: Task<Void, Never>?
    @State private var done = 0
    @State private var total = 0
    @State private var current = ""
    @State private var written: [URL] = []
    @State private var failures: [String] = []
    @State private var finished = false

    private var targets: [ExportTarget] { model.exportTargets }
    private var skipped: Int { model.selectedFrames.count - targets.count }
    private var running: Bool { run != nil && !finished }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if finished { summary } else { form }
            Divider()
            buttons
        }
        .frame(width: 460)
        .onAppear {
            mode = ExportMode(rawValue: model.prefs.exportMode) ?? .neutral
            format = ExportFormat(rawValue: model.prefs.exportFormat) ?? .heic
            colorSpace = ExportColorSpace(rawValue: model.prefs.exportColorSpace) ?? .sRGB
            folder = model.defaultExportFolder
        }
        .onDisappear { run?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Export").font(.headline)
                Text(countText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var form: some View {
        Form {
            Section {
                // A yes or no, so a switch. The stored mode is unchanged.
                // Every row carries its explanation on an info icon after the label, for the
                // CURRENT choice, rather than as a stack of footer sentences.
                Toggle(isOn: enhancementsBinding) {
                    Label { Self.infoTitle("Enhancements", Self.blurb(mode), "export.info.enhancements") }
                        icon: { Image(systemName: "sparkles") }
                }
                Picker(selection: familyBinding) {
                    ForEach(ExportFamily.allCases, id: \.self) { f in Text(Self.name(f)).tag(f) }
                } label: {
                    Label { Self.infoTitle("Format", Self.blurb(format.family), "export.info.format") }
                        icon: { Image(systemName: "doc") }
                }
                // Two rows: the plain format name above, its bit or compression options
                // below. Every format has the row, and one with a single option shows that
                // option greyed out.
                Picker(selection: $format) {
                    ForEach(qualities, id: \.self) { q in Text(Self.qualityName(q)).tag(q) }
                } label: {
                    // The quality rows look alike, so the icon names the chosen one.
                    Label { Self.infoTitle("Quality", Self.qualityBlurb(format), "export.info.quality") }
                        icon: { Image(systemName: "slider.horizontal.3") }
                }
                    .disabled(qualities.count == 1)
                Picker(selection: $colorSpace) {
                    Text("sRGB").tag(ExportColorSpace.sRGB)
                    Text("Display P3").tag(ExportColorSpace.displayP3)
                } label: {
                    Label { Self.infoTitle("Color", Self.blurb(colorSpace), "export.info.color") }
                        icon: { Image(systemName: "paintpalette") }
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        // Capped, so a long path truncates in the middle on the label's
                        // line. Uncapped, the grouped Form measures the whole path, finds it
                        // does not fit beside "To", and drops the row onto a second line.
                        Text(folder?.path ?? "Choose a folder")
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: Self.pathWidth, alignment: .trailing)
                            .foregroundStyle(folder == nil ? .secondary : .primary)
                            .help(folder?.path ?? "")
                        Button("Choose…") { choose() }
                    }
                } label: {
                    Label { Self.infoTitle("To", Self.namingText, "export.info.to") }
                        icon: { Image(systemName: "folder") }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(running)
    }

    private var summary: some View {
        Form {
            Section {
                LabeledContent("Written", value: "\(written.count) \(written.count == 1 ? "file" : "files")")
                if let folder {
                    // One line, truncated in the middle so the folder name at the tail stays
                    // readable, the whole path on hover. Same shape as the To row
                    // before the export, wider here because there is no Choose button.
                    LabeledContent("To") {
                        Text(folder.path)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: Self.summaryPathWidth, alignment: .trailing)
                            .help(folder.path)
                    }
                }
                if !failures.isEmpty {
                    LabeledContent("Failed", value: "\(failures.count)")
                    ForEach(failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }
                if run?.isCancelled == true { Text("Stopped after \(done) of \(total).").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private var buttons: some View {
        HStack {
            if finished, let first = written.first {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([first]) }
            }
            // The progress lives here beside Stop rather than under the options, so the form
            // is the same height running or not and its margins above and below match (an
            // empty footer leaves 10 pt more below than above).
            if running {
                ProgressView(value: Double(done), total: Double(max(total, 1))) {
                    Text("Exporting \(min(done + 1, total)) of \(total): \(current)")
                        .lineLimit(1).truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)
            }
            Spacer()
            if finished {
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else if running {
                // A frame in flight finishes before the loop stops, so the button says so.
                Button(run?.isCancelled == true ? "Stopping…" : "Stop") { run?.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(run?.isCancelled == true)
            } else {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(targets.isEmpty || folder == nil)
            }
        }
        .padding(16)
    }

    // MARK: actions

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        if let folder { panel.directoryURL = folder }
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            // The pick, and only the pick, overrides the setting, and only until the app
            // quits. It is never saved: a destination that outlives the session is
            // something the user chooses in Settings, not something we infer from here.
            model.sessionExportFolder = url
        }
    }

    private func start() {
        guard let folder else { return }
        let jobs = targets
        total = jobs.count
        done = 0
        // Named before the loop starts, so the progress line reads "Exporting 1 of N: <stem>"
        // from the first frame rather than catching up one frame late.
        current = jobs.first?.stem ?? ""
        written = []
        failures = []
        // The choices persist as preferences, never in a sidecar.
        model.prefs.exportMode = mode.rawValue
        model.prefs.exportFormat = format.rawValue
        model.prefs.exportColorSpace = colorSpace.rawValue
        // The FOLDER is deliberately not saved here. Exporting to the default must not
        // turn that default into a pin.
        model.prefs.save()
        let service = model.renders.service
        let exporter = Exporter()
        let (mode, format, colorSpace) = (mode, format, colorSpace)
        let appVersion = AppInfo.display
        run = Task {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                failures.append("Could not create \(folder.path): \(error)")
                finished = true
                return
            }
            // Core owns the loop and the one-frame-in-flight guarantee; the sheet owns the
            // counter, the Stop button and the failure list. `BatchExport.run` is
            // nonisolated, so it leaves the main actor on its own and each frame's develop
            // and write happen in a detached task inside it. The state writes below are the
            // only part that comes back here, which is why they hop explicitly.
            await BatchExport.run(jobs, with: service, exporter: exporter, to: folder,
                                  mode: mode, format: format, colorSpace: colorSpace, appVersion: appVersion,
                                  isCancelled: { Task.isCancelled },
                                  progress: { i, outcome in
                await MainActor.run {
                    switch outcome {
                    case .success(let url): written.append(url)
                    case .failure(let error): failures.append("\(jobs[i].stem): \(error)")
                    }
                    done = i + 1
                    if i + 1 < jobs.count { current = jobs[i + 1].stem }
                }
            })
            finished = true
        }
    }

    // MARK: copy

    private var countText: String {
        guard !targets.isEmpty else { return "No frame in the selection is developed yet" }
        let frames = targets.count == 1 ? "1 frame" : "\(targets.count) frames"
        guard skipped > 0 else { return frames }
        return "\(frames), skipping \(skipped) not yet developed"
    }

    /// The Quality row's options for whatever format is picked, smallest file first.
    /// One option means the row is shown greyed out with that option.
    private var qualities: [ExportFormat] { format.family.options }

    /// The Format row reads the family off the concrete pick and writes back that
    /// family's default. It only writes on a real change, so re-picking the family already
    /// shown does not throw away a quality the user chose.
    private var familyBinding: Binding<ExportFamily> {
        Binding(get: { format.family },
                set: { newFamily in if newFamily != format.family { format = newFamily.default } })
    }

    static func name(_ f: ExportFamily) -> String {
        switch f {
        case .tiff16: return "TIFF"
        case .png16: return "PNG"
        case .heic: return "HEIC"
        case .avif: return "AVIF"
        case .jpeg: return "JPEG"
        case .jxl: return "JPEG XL"
        }
    }

    /// The Quality row's labels. Depth is what a HEIC row differs by, a named step is
    /// what a JPEG or JPEG XL row differs by, and a format with one option shows its
    /// depth greyed out.
    static func qualityName(_ f: ExportFormat) -> String {
        switch f {
        case .heic8: return "8-bit"
        case .heic: return "10-bit"
        case .jpegMedium: return "Medium"
        case .jpeg: return "High"
        case .jpegMaximum: return "Maximum"
        case .jxlSmall: return "High"
        case .jxlFine: return "Maximum"
        case .jxlLossless: return "Lossless"
        case .tiff16, .png16: return "16-bit"
        case .avif: return "10-bit"
        }
    }

    static func blurb(_ f: ExportFamily) -> String {
        switch f {
        case .tiff16: return "TIFF: the full-quality master, largest file."
        case .png16: return "PNG: lossless, nothing is lost."
        case .heic: return "HEIC: small files, 8- or 10-bit color."
        case .avif: return "AVIF: small files with 10-bit color, like HEIC."
        case .jpeg: return "JPEG: 8-bit, opens everywhere, for sharing."
        case .jxl: return "JPEG XL: 16-bit, small at every quality."
        }
    }

    /// The To row's info text: what the files are called and what happens to an older one.
    static let namingText = "Files take the scan's name and replace an earlier export."

    /// A row title with its info icon, the shape every row of the form shares.
    static func infoTitle(_ title: String, _ info: String, _ identifier: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            InfoGlyph(text: info, identifier: identifier)
        }
    }

    /// The Quality row's info text, one per option, in plain words: the measured JPEG ratios
    /// live in JPEGQualityTests, not here.
    static func qualityBlurb(_ f: ExportFormat) -> String {
        switch f {
        case .heic8: return "8-bit: smaller, opens in more apps."
        case .heic: return "10-bit: smoother gradients than JPEG."
        case .jpegMedium: return "Medium: smaller files for sharing."
        case .jpeg: return "High: the everyday choice."
        case .jpegMaximum: return "Maximum: best quality, much larger files."
        case .jxlSmall: return "High: small files for sharing."
        case .jxlFine: return "Maximum: nearly lossless."
        case .jxlLossless: return "Lossless: nothing lost, still smaller than TIFF."
        case .tiff16, .png16: return "16-bit: full quality, the only option."
        case .avif: return "10-bit: the only option."
        }
    }

    static func blurb(_ m: ExportMode) -> String {
        switch m {
        case .neutral: return "Off: the plain positive, for editing elsewhere."
        case .withLook: return "On: each frame's Enhance settings are baked in."
        }
    }

    static func blurb(_ c: ExportColorSpace) -> String {
        switch c {
        case .sRGB: return "sRGB: the standard for the web and most screens."
        case .displayP3: return "Display P3: a wider range of color for wide-gamut screens."
        }
    }

    /// The widest the To row's path may draw before it truncates. The sheet is a fixed 460
    /// pt; this leaves room for the "To" label and the Choose button on one line.
    static let pathWidth: CGFloat = 220

    /// The same cap for the To row after the export, which has only the label beside it.
    static let summaryPathWidth: CGFloat = 320

    private var enhancementsBinding: Binding<Bool> {
        Binding(get: { mode == .withLook }, set: { mode = $0 ? .withLook : .neutral })
    }
}
