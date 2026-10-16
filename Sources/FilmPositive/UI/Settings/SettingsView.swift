import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FilmPositiveCore

/// Settings: film stocks, cropping and export. Nothing here measures the scanning setup or
/// fits a stock.
struct SettingsView: View {
    var body: some View {
        TabView {
            FilmStocksPane()
                .tabItem { Label("Film Stocks", systemImage: "film") }
            CroppingPane()
                .tabItem { Label("Cropping", systemImage: "crop") }
            ExportPane()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            // Only a build with a feed has an updater to switch.
            if let updater = AppUpdates.updater {
                UpdatesPane(updater: updater)
                    .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            }
        }
        .frame(width: 560, height: 400)
    }
}

/// The stock list and the profile import button. Each row is the stock's name, linked to
/// its maker's published curve where one exists.
struct FilmStocksPane: View {
    @Environment(AppModel.self) private var model
    @State private var profiles: ProfileLibrary? = nil
    @State private var importing = false
    @State private var note: String?

    var body: some View {
        Form {
            // Not "Shipped", no per-stock export, no notes, and nothing about what is or is
            // not a profile yet. A list of stocks, a link to the maker's curve where one
            // exists, and an import button.
            Section("Film Stocks") {
                // The name IS the link where the maker publishes a curve, underlined and in
                // the text color, and there is no right column.
                ForEach(rows, id: \.id) { row in
                    HStack {
                        if let raw = row.url, let link = URL(string: raw) {
                            Link(destination: link) { Text(row.name).underline() }
                                .foregroundStyle(.primary)
                                .help(row.publication ?? "")
                        } else {
                            Text(row.name)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                Button("Import Profile…") { importing = true }
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { profiles = model.renders.profiles }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.filmPositiveProfile, .json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let (_, profile) = try ProfilePackage.decode(data)
                try ProfilePackage.install(data)
                // The library is loaded once at launch, so a freshly imported profile is
                // announced rather than pretended to be live.
                note = "Imported \(profile.name). It takes effect the next time the app starts."
            } catch {
                note = "\(error)"
            }
        }
    }

    struct Row: Identifiable {
        let id: String
        let name: String
        /// The manufacturer's publication, shown as a link so it is obvious it lives on
        /// their site and not in this app.
        let publication: String?
        let url: String?
    }

    /// A row is the name, and a LINK to the manufacturer's datasheet where one exists. A link
    /// says the publication lives on the manufacturer's site, not in the app.
    ///
    /// The same list, in the same order and with the same names, as the Film Stock picker.
    /// One source, `StockChoices`, so the two cannot drift. A market name that renders
    /// through another stock links to that stock's published curve.
    private var rows: [Row] {
        guard let profiles else { return [] }
        return StockChoices.list(from: profiles, current: nil).compactMap { choice in
            if case .unprofiled = choice.kind { return nil }
            var sheet = profiles.films[choice.id]?.datasheetDyeGamma?.source
            if case .alias = choice.kind, sheet == nil, let target = profiles.aliases[choice.id] {
                sheet = profiles.films[target]?.datasheetDyeGamma?.source
            }
            return Row(id: choice.id, name: choice.name, publication: sheet?.publication, url: sheet?.url)
        }
    }
}

extension UTType {
    /// Derived from the extension rather than declared, the same way the looks type is:
    /// the type is ours, the bytes are plain JSON, and JSON is offered alongside so a file
    /// somebody renamed still opens.
    static var filmPositiveProfile: UTType {
        UTType(filenameExtension: ProfilePackage.fileExtension) ?? .json
    }
}


/// Where exports go. The default is a Positives folder within the working folder, and a
/// person who wants everything in one place picks a fixed folder, so it is a setting with
/// two modes rather than a behavior inferred from the last folder anybody picked.
struct ExportPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Hoisted above the Form because the Section's `footer:` is a separate closure
        // from its content, so a binding declared inside the content is not in scope there.
        let choice = Binding<ExportDestination>(
            get: { model.prefs.exportDestination },
            set: { model.prefs.exportDestination = $0; settingChanged() }
        )
        Form {
            Section {
                Picker("Exports go to", selection: choice) {
                    Text("A Positives folder in each working folder").tag(ExportDestination.positivesInFolder)
                    Text("Always this folder").tag(ExportDestination.fixedFolder)
                }
                .pickerStyle(.radioGroup)

                if choice.wrappedValue == .fixedFolder {
                    LabeledContent("Folder") {
                        HStack {
                            Text(chosenFolderLabel)
                                .foregroundStyle(model.prefs.exportFolder == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                            Button("Choose…") { choose() }
                        }
                    }
                }
            } footer: {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                // The sheet's picker can beat this pane, so the pane says where the next
                // export is ACTUALLY going and offers the way back. A setting something
                // else can quietly override, with no sign of it here, is a setting that
                // reads as broken.
                if let session = model.sessionExportFolder {
                    Text("Right now exports go to \(abbreviate(session.path)), which you picked in the Export window. It goes back to the setting above when you quit Film Positive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Use My Setting Now") { model.sessionExportFolder = nil }
                } else {
                    Text("Picking a different folder in the Export window uses it for the rest of the time the app is open. It goes back to this setting the next time you open Film Positive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// A home-relative path, because nobody needs to read their own user name back.
    private func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private var chosenFolderLabel: String {
        model.prefs.exportFolder.map(abbreviate) ?? "None chosen yet"
    }

    /// The footer says what will actually happen, including "Always this folder" with no
    /// folder picked, which must not sit under a sentence promising every export goes there.
    private var footerText: String {
        guard model.prefs.exportDestination == .fixedFolder else {
            return "Exports go next to the scans they came from, in a folder called Positives. It is made for you the first time you export."
        }
        guard model.prefs.exportFolder != nil else {
            return "Choose a folder above. Until you do, exports go next to the scans they came from, in a folder called Positives."
        }
        return "Every export goes here, whichever folder you are working in."
    }

    /// Going to Settings is a later instruction than picking in the sheet, so changing
    /// either the mode or the folder drops the session pick. Without this, a user sets
    /// "Always this folder", exports, watches it land somewhere else, and is right to
    /// conclude the setting does nothing.
    private func settingChanged() {
        model.sessionExportFolder = nil
        model.prefs.save()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        // Not "Export Here": nothing is exported from this pane, a folder is named for
        // later, and a button promising an export now is a button that lies.
        panel.prompt = "Use This Folder"
        if let p = model.prefs.exportFolder { panel.directoryURL = URL(fileURLWithPath: p) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.prefs.exportFolder = url.path
        settingChanged()
    }
}

/// Where autocrop sits relative to the film edge, which is taste rather than measurement.
///
/// WHERE the film edge is, is a measurement, and nothing here may move it. HOW FAR INSIDE it
/// a person likes to sit is a preference: a set of 114 accepted crops varies in that amount,
/// so no amount of measuring settles it.
///
/// It lives in Settings rather than in the crop tool because it is a decision about the
/// scanning setup and the operator. Changing it mid roll should be rare, and changing it
/// once, after seeing a few frames, is the whole point.
struct CroppingPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                let value = Binding<Double>(
                    get: { model.prefs.autoCropInset },
                    set: { model.prefs.autoCropInsetPercent = $0; model.prefs.save() }
                )
                LabeledContent("Inset from the film edge") {
                    HStack {
                        Slider(value: value, in: 0...5, step: 0.25)
                        Text(String(format: "%.2f%%", value.wrappedValue))
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            } footer: {
                Text("How far inside the detected film edge a new crop starts. Zero sits exactly on the edge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
