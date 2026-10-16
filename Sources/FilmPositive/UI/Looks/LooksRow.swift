import SwiftUI
import UniformTypeIdentifiers
import FilmSidecar
import FilmPositiveCore

/// The looks row.
///
/// A strip of bordered buttons, one per look, the applied one filled in. Every look is one
/// tap, including the black and white ones, which get no treatment of their own. The row
/// wraps onto a second line rather than scrolling, because seven presets do not fit across an
/// inspector column and a hidden four are not one tap away. The menu at the end holds Save
/// Look, Export Looks, Import Looks, Reset Presets and a Delete submenu. Blurbs are help
/// tooltips, so the row stays a row.
///
/// Applying a look goes through `model.apply` like every other edit, which is what puts it on
/// the one undo stack and schedules the sidecar write.
struct LooksRow: View {
    @Environment(AppModel.self) private var model
    /// Which look the SELECTION carries: one shared look, none, or Multiple. The row fills
    /// a button in only on a shared look, because a filled button on a mixed selection
    /// would claim every frame carries it.
    let applied: SharedValue<String?>

    @State private var looks = LooksModel.shared
    @State private var isNamingLook = false
    @State private var newLookName = ""
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument = LooksDocument(data: Data())

    /// Save Look reads the sliders the inspector is showing, which on a mixed selection is
    /// not a thing that exists. The menu item is disabled there rather than silently
    /// saving one frame's numbers under a name the user thinks describes the group.
    private var current: EnhanceSettings? {
        let frames = model.selectedFrames
        guard let first = frames.first else { return nil }
        let settings = first.sidecar.enhance ?? .identity
        for f in frames.dropFirst() where (f.sidecar.enhance ?? .identity) != settings { return nil }
        return settings
    }

    private var appliedLookID: String? { applied.value.flatMap { $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WrappingRow(spacing: 6, lineSpacing: 6) {
                ForEach(looks.looks) { look in
                    button(for: look)
                }
                menu
            }
            if let status = looks.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { report(looks.takeStartupProblem()) }
        .alert("Save Look", isPresented: $isNamingLook) {
            TextField("Name", text: $newLookName)
            Button("Save") { saveLook() }
            Button("Cancel", role: .cancel) { newLookName = "" }
        } message: {
            Text("Saves the current enhance sliders as a preset.")
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument,
                      contentType: .filmPositiveLooks, defaultFilename: "Film Positive Looks") { result in
            switch result {
            case .success: looks.exported(count: looks.looks.count)
            case .failure(let error): report("Could not export the looks: \(error)")
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.filmPositiveLooks, .json]) { result in
            switch result {
            case .success(let url): report(looks.importLooks(from: url))
            case .failure(let error): report("Could not open that file: \(error)")
            }
        }
    }

    // MARK: the buttons

    /// One look, one tap. The applied one is filled in and stays that way until a
    /// slider edit clears `sidecar.look`. A tap on the filled one takes the layer back to 0,
    /// the same as the Enhance Auto: `AppModel.lookClicked`.
    private func button(for look: Look) -> some View {
        let isApplied = appliedLookID == look.id
        return Button(look.name) {
            model.lookClicked(look)
            looks.status = nil
        }
        .buttonStyle(.bordered)
        .tint(isApplied ? .accentColor : nil)
        .background {
            if isApplied {
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.18))
            }
        }
        .help(look.blurb)
        .accessibilityIdentifier("look-\(look.id)")
        .accessibilityAddTraits(isApplied ? [.isSelected] : [])
    }

    private var menu: some View {
        Menu {
            Button("Save Look…") {
                newLookName = ""
                isNamingLook = true
            }
            .help(current == nil
                  ? "Frames have different settings, so there is nothing to save."
                  : "Save these settings as a look.")
            .disabled(current.map(\.isIdentity) ?? true)

            Divider()

            Button("Export Looks…") {
                let (data, error) = looks.exportData()
                guard let data else { report(error); return }
                exportDocument = LooksDocument(data: data)
                isExporting = true
            }
            Button("Import Looks…") { isImporting = true }

            Divider()

            Menu("Delete") {
                ForEach(looks.looks) { look in
                    Button(look.name) { report(looks.delete(look.id)) }
                }
            }
            .disabled(looks.looks.isEmpty)

            Button("Reset Presets") { report(looks.restoreAll()) }
                .disabled(looks.hiddenCount == 0)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Save, import, export and delete looks.")
        .accessibilityIdentifier("looks-menu")
    }

    // MARK: actions

    private func saveLook() {
        let name = newLookName
        newLookName = ""
        guard let current else {
            report("The selected frames have different sliders, so there is no one look to save.")
            return
        }
        report(looks.saveLook(named: name, settings: current))
    }

    /// Engine and file errors reach the user with their complete text through the window's
    /// one alert rather than a second alert of our own.
    private func report(_ error: String?) {
        guard let error else { return }
        model.lastError = error
    }
}

/// The `.fplooks` document, a `LookFile` JSON blob and nothing else. The codec lives in the
/// engine (`LookFile.encode`/`decode`), so this type only carries bytes.
struct LooksDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.filmPositiveLooks, .json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = bytes
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension UTType {
    /// Derived from the extension rather than declared, because the app has no Info.plist
    /// until it is wrapped in a bundle. Exporter and importer both use this one value,
    /// so they agree whatever the system resolves it to.
    static var filmPositiveLooks: UTType {
        UTType(filenameExtension: LookFile.fileExtension) ?? .json
    }
}

/// A row of buttons that uses a second line rather than hiding half the set.
///
/// The looks section sits in a 300 to 420 point inspector column and the shipped set alone is
/// seven presets, so a single line fits three. A horizontal scroller shows three buttons, no
/// scrollbar, and nothing on screen saying the other four exist. Wrapping keeps every preset
/// one tap away, which is the whole point of the row.
///
/// The menu is the last subview, so it lands at the end of the last line however the presets
/// happen to fall.
struct WrappingRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = self.lines(width: proposal.width ?? .infinity, subviews: subviews)
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width ?? (lines.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in line.range {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var range: Range<Int>
        var width: CGFloat
        var height: CGFloat
    }

    private func lines(width: CGFloat, subviews: Subviews) -> [Line] {
        var out: [Line] = []
        var start = 0
        var x: CGFloat = 0
        var height: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = index == start ? size.width : x + spacing + size.width
            if needed > width, index > start {
                out.append(Line(range: start..<index, width: x, height: height))
                start = index
                x = size.width
                height = size.height
            } else {
                x = needed
                height = max(height, size.height)
            }
        }
        if start < subviews.count { out.append(Line(range: start..<subviews.count, width: x, height: height)) }
        return out
    }
}
