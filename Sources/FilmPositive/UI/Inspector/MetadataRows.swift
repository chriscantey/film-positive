import SwiftUI
import AppKit
import FilmSidecar
import FilmPositiveCore

/// The camera and film a frame was shot on, the names Film Tether recorded at capture,
/// readable and correctable here.
///
/// These are metadata and nothing else. Editing Film does not change the Stock picker: a
/// film name picks a stock once, when a frame is first made positive, and the picker owns
/// it from then on.
struct MetadataSection: View {
    @Environment(AppModel.self) private var model
    let summary: SelectionSummary

    private var open: Bool { model.prefs.sectionFold.isOpen(.metadata) }

    var body: some View {
        // Folds from its title like every other section, open by default and remembered.
        // Closed, the body is empty and the header pays the missing card's gap itself. The
        // Histogram section explains why.
        Section {
            if open {
                LabeledContent("Camera") {
                    MetadataField(label: "Camera", shared: summary.camera, identifier: "metadata.camera",
                                  history: model.prefs.cameraHistory ?? [],
                                  onRemove: { model.forgetName($0, in: .camera) },
                                  selection: { model.selectedFrames.map(\.id) }) { name, ids in
                        model.setCamera(name, on: ids)
                    } onRelease: {
                        model.returnFocusToGrid()
                    }
                    .labelsHidden()
                }
                LabeledContent("Film") {
                    MetadataField(label: "Film", shared: summary.film, identifier: "metadata.film",
                                  history: model.prefs.filmHistory ?? [],
                                  onRemove: { model.forgetName($0, in: .film) },
                                  selection: { model.selectedFrames.map(\.id) }) { name, ids in
                        model.setFilm(name, on: ids)
                    } onRelease: {
                        model.returnFocusToGrid()
                    }
                    .labelsHidden()
                }
                // The day it was shot, typed or picked from a calendar, then two things the
                // scan recorded and nobody edits.
                // Every row is a LabeledContent, so all five values start on one line.
                LabeledContent {
                    MetadataField(label: "Taken", shared: summary.takenOn, identifier: "metadata.taken",
                                  history: model.prefs.takenHistory ?? [],
                                  onRemove: { model.forgetName($0, in: .taken) },
                                  selection: { model.selectedFrames.map(\.id) },
                                  prompt: "YYYY-MM-DD", calendar: true) { day, ids in
                        model.setTakenOn(day, on: ids)
                    } onRelease: {
                        model.returnFocusToGrid()
                    }
                    .labelsHidden()
                } label: {
                    RowLabel(title: "Taken", info: Self.takenInfo, identifier: "metadata.taken.info")
                }
                LabeledContent("Film size") {
                    ReadOnlyValue(text: Self.filmSizeText(summary.filmSize), identifier: "metadata.filmSize")
                }
                LabeledContent {
                    ReadOnlyValue(text: Self.scannedText(summary.scannedAt, count: summary.count), identifier: "metadata.scanned")
                } label: {
                    RowLabel(title: "Scanned", info: Self.scannedInfo, identifier: "metadata.scanned.info")
                }
            }
        } header: {
            InspectorView.foldHeader(.metadata, open: open) { model.toggleSection(.metadata) }
        }
    }

    static let takenInfo = "The day it was shot, used as the photo's date."
    static let scannedInfo = "When the negative was scanned."

    /// One frame's size as a person reads it. The capture app's own name wins, since
    /// it is the word the person picked there, and an id-less name (typed under Other) is
    /// the label as given. With no name: the catalog's name, then the sizes the catalog
    /// only names, then "Size N" for an id nothing here knows. The unknown id, or nothing
    /// at all, is nil.
    static func filmSizeLabel(id rawID: String?, name: String?) -> String? {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        guard let raw = rawID, let id = Int(raw) else { return nil }
        if let size = FilmSize.seedCatalog.first(where: { $0.id == id }) {
            return size.isUnknown ? nil : size.name
        }
        return FilmSize.labelOnlyNames[id] ?? "Size \(id)"
    }

    /// The Size row over the selection's resolved labels.
    static func filmSizeText(_ shared: SharedValue<String?>) -> String {
        if shared.isMultiple { return "Multiple" }
        return shared.value.flatMap({ $0 }) ?? "Not recorded"
    }

    /// One frame: its day and time. Several on one day: the day. Across days: the span.
    /// A frame with no recorded scan is left out rather than read as a difference.
    static func scannedText(_ dates: [Date], count: Int, calendar: Calendar = .current) -> String {
        guard let first = dates.min(), let last = dates.max() else { return "Not recorded" }
        if count == 1 { return first.formatted(date: .abbreviated, time: .shortened) }
        if calendar.isDate(first, inSameDayAs: last) { return first.formatted(date: .abbreviated, time: .omitted) }
        return "\(first.formatted(date: .abbreviated, time: .omitted)) to \(last.formatted(date: .abbreviated, time: .omitted))"
    }
}

extension AppModel {
    /// The Metadata rows' writes. Never through the defaults funnel: a name is not a
    /// decision about the positive, and a name that is already on a frame is a no-op the
    /// funnel would otherwise read as the Positive button.
    func setCamera(_ name: String?, on ids: [Frame.ID]) {
        applyToFrames(ids, { SidecarEdits.setCamera($0, name) }, actionName: "Camera", seedsDefaults: false)
        remember(name, in: .camera)
    }

    func setFilm(_ name: String?, on ids: [Frame.ID]) {
        applyToFrames(ids, { SidecarEdits.setFilm($0, name) }, actionName: "Film", seedsDefaults: false)
        remember(name, in: .film)
    }

    /// The day shot, "YYYY-MM-DD". A day that is not a real one is refused with a sentence
    /// and nothing is written; nil clears it.
    func setTakenOn(_ day: String?, on ids: [Frame.ID]) {
        if let day, CaptureInfo.validDay(day) == nil {
            lastError = "\(day) is not a date. Type it as YYYY-MM-DD, or pick it from the calendar."
            return
        }
        applyToFrames(ids, { SidecarEdits.setTakenOn($0, day) }, actionName: "Date Taken", seedsDefaults: false)
        remember(day, in: .taken)
    }

    enum NameField { case camera, film, taken }

    /// Every saved name goes to the front of its field's history. Clearing a name is not a
    /// name, so it leaves the history alone.
    private func remember(_ name: String?, in field: NameField) {
        guard let name else { return }
        switch field {
        case .camera: prefs.cameraHistory = NameHistory.fold(name, into: prefs.cameraHistory ?? [])
        case .film: prefs.filmHistory = NameHistory.fold(name, into: prefs.filmHistory ?? [])
        case .taken: prefs.takenHistory = NameHistory.fold(name, into: prefs.takenHistory ?? [])
        }
        prefs.save()
    }

    /// The x beside an entry: out of the list, and nothing else. No frame keeps or loses a
    /// name because of it.
    func forgetName(_ name: String, in field: NameField) {
        switch field {
        case .camera: prefs.cameraHistory = NameHistory.remove(name, from: prefs.cameraHistory ?? [])
        case .film: prefs.filmHistory = NameHistory.remove(name, from: prefs.filmHistory ?? [])
        case .taken: prefs.takenHistory = NameHistory.remove(name, from: prefs.takenHistory ?? [])
        }
        prefs.save()
    }

    func setCameraOnSelection(_ name: String?) { setCamera(name, on: selectedFrames.map(\.id)) }
    func setFilmOnSelection(_ name: String?) { setFilm(name, on: selectedFrames.map(\.id)) }
}

/// Film Tether's history rule, so a list reads the same in both apps: case-insensitive
/// dedup, most recent first, capped.
enum NameHistory {
    static let cap = 50

    static func fold(_ name: String, into list: [String]) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return list }
        var out = list.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        out.insert(trimmed, at: 0)
        return Array(out.prefix(cap))
    }

    static func remove(_ name: String, from list: [String]) -> [String] {
        list.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
    }
}

/// One editable name. Return saves it to every frame that was selected when the typing
/// began and hands the keyboard back to the roll. Clicking away saves too. Escape is the one
/// way out that abandons the typing.
///
/// A click on another frame changes the selection BEFORE the field lets go, so a save on
/// focus loss aimed at the live selection would write the name onto frames nobody was
/// typing about. So the field takes
/// its targets, and the value they shared, at the moment it gains focus, and every save
/// goes to those frames whatever is selected by the time it lands.
struct MetadataField: View {
    let label: String
    let shared: SharedValue<String?>
    let identifier: String
    let history: [String]
    let onRemove: (String) -> Void
    let selection: () -> [Frame.ID]
    /// Placeholder when no frame carries a value; Multiple wins when they disagree.
    var prompt: String? = nil
    /// A calendar button beside the history chevron, for a field that holds a day.
    var calendar = false
    let onCommit: (String?, [Frame.ID]) -> Void
    let onRelease: () -> Void

    @State private var text = ""
    /// True once the person has typed in this editing session. A save of an untouched
    /// field writes nothing, which is what keeps Return on a Multiple row from clearing
    /// the name on every selected frame.
    @State private var dirty = false
    /// The frames and the shown value as they were when the field gained focus.
    @State private var session: Session?
    @FocusState private var focused: Bool
    @State private var showsHistory = false
    @State private var showsCalendar = false
    @State private var picked = Date()

    struct Session {
        let targets: [Frame.ID]
        let isMultiple: Bool
        let shown: String
    }

    /// What the field shows when nobody is typing.
    private var shown: String { shared.value.flatMap { $0 } ?? "" }

    var body: some View {
        // The buttons sit BESIDE the field, not over it: a grouped form right-aligns a
        // field's text, so an overlay draws the calendar on top of the last characters.
        HStack(spacing: 6) {
            field
            if calendar { calendarButton }
            historyButton
        }
    }

    private var field: some View {
        TextField(label, text: $text, prompt: shared.isMultiple ? Text("Multiple") : prompt.map { Text($0) })
            .focused($focused)
            .accessibilityIdentifier(identifier)
            .onAppear { text = shown }
            .onChange(of: shown) { _, value in if !focused { text = value; dirty = false } }
            .onChange(of: text) { _, value in if focused && value != (session?.shown ?? shown) { dirty = true } }
            .onChange(of: focused) { _, isFocused in
                if isFocused {
                    session = Session(targets: selection(), isMultiple: shared.isMultiple, shown: shown)
                } else {
                    save()
                    text = shown
                }
            }
            // The inspector can take the field away mid-typing (the selection emptied), and
            // a field that is gone never reports losing focus.
            .onDisappear { save() }
            .onSubmit { save(); release() }
            .onExitCommand { dirty = false; release() }
    }

    /// A month to click a day in. Picking one saves it to the selection like a history
    /// pick, and the calendar opens on the day already shown.
    private var calendarButton: some View {
        Button {
            picked = Self.date(fromDay: shown) ?? Date()
            showsCalendar.toggle()
        } label: {
            Image(systemName: "calendar").font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Pick a day")
        .accessibilityLabel("\(label) calendar")
        .accessibilityIdentifier("\(identifier).calendar")
        .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
            DatePicker("", selection: $picked, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(10)
                .onChange(of: picked) { _, day in
                    showsCalendar = false
                    dirty = false
                    session = nil
                    onCommit(Self.day(from: day), selection())
                    release()
                }
        }
    }

    static func day(from date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(fromDay day: String, calendar: Calendar = .current) -> Date? {
        guard let valid = CaptureInfo.validDay(day) else { return nil }
        let p = valid.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }

    private var historyButton: some View {
                Button { showsHistory.toggle() } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(history.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.borderless)
                .disabled(history.isEmpty)
                .help("Earlier entries")
                .accessibilityLabel("\(label) history")
                .accessibilityIdentifier("\(identifier).history")
                .popover(isPresented: $showsHistory, arrowEdge: .bottom) { historyList }
    }

    /// Picking an entry saves it to the frames selected now, exactly as typing it and
    /// pressing Return would. The x takes an entry out of the list and touches no frame.
    private var historyList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(history, id: \.self) { entry in
                HStack(spacing: 8) {
                    Button {
                        showsHistory = false
                        // Whatever was half-typed is dropped first, or the focus loss that
                        // follows would save it over the pick.
                        dirty = false
                        session = nil
                        onCommit(entry, selection())
                        release()
                    } label: {
                        Text(entry)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { onRemove(entry) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from history")
                    .accessibilityLabel("Remove \(entry)")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                if entry != history.last { Divider() }
            }
        }
        .frame(width: 240)
        .padding(.vertical, 4)
    }

    /// Writes what was typed to the frames captured at focus, once.
    private func save() {
        defer { dirty = false; session = nil }
        guard let session else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = Self.committedName(trimmed, dirty: dirty, isMultiple: session.isMultiple, shown: session.shown) {
            onCommit(name.isEmpty ? nil : name, session.targets)
        }
    }

    private func release() {
        text = shown
        NSApp.keyWindow?.makeFirstResponder(nil)
        onRelease()
    }

    /// What a save writes, or nil for "write nothing". Pure so the rule is testable
    /// without a window. An empty string means "clear the name", which is only honored
    /// where every selected frame showed one shared name: on a Multiple row an empty field
    /// is indistinguishable from not having typed at all.
    static func committedName(_ trimmed: String, dirty: Bool, isMultiple: Bool, shown: String) -> String? {
        guard dirty else { return nil }
        if trimmed.isEmpty && isMultiple { return nil }
        if !isMultiple && trimmed == shown { return nil }
        return trimmed
    }
}

/// A row title with its own info icon, for a field whose meaning is not obvious from the
/// name, drawn through `InfoGlyph` like every plain info icon in the inspector.
struct RowLabel: View {
    let title: String
    let info: String
    let identifier: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            InfoGlyph(text: info, identifier: identifier)
        }
    }
}

/// A value the app shows and nobody edits: plain secondary text, selectable for copying.
struct ReadOnlyValue: View {
    let text: String
    let identifier: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityIdentifier(identifier)
    }
}
