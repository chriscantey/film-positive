import SwiftUI
import FilmPositiveCore

/// Detect Crop over a selection, with the ratio chosen up front and Original as the default.
///
/// Named for what it does rather than for how it feels. Nothing in this app crops or
/// rotates on its own: this finds the film edge in the frames that are selected, when it is
/// asked.
///
/// The ratio is the whole reason the sheet exists. A detector measures four edges
/// independently, so one bad edge moves one side with nothing to object; the frame's own
/// ratio is a fact about the film that no single edge can outvote. Defaulting to Original
/// means the common case needs no decision, and the picker is there for a roll that was shot
/// on something else.
struct AutoCropSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var aspect: CropAspect = .original
    @State private var running = false

    private var targets: Int { model.selectedFrames.filter(\.isDeveloped).count }
    private var skipped: Int { model.selectedFrames.count - targets }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.dashed").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Detect Crop").font(.headline)
                    Text(countText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            Divider()
            Form {
                Section {
                    Picker(selection: $aspect) {
                        ForEach(CropAspect.allCases) { a in
                            Text(a.name).tag(a)
                        }
                    } label: {
                        Label("Ratio", systemImage: "aspectratio")
                    }
                } footer: {
                    Text("Original holds each crop to the frame's own shape. Freeform takes the detector's box exactly as it found it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if running, let p = model.autoCropProgress {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                        .frame(width: 140)
                    Text("Detecting \(min(p.done + 1, p.total)) of \(p.total)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                // Before the run this is Cancel. While it runs it is Stop, which ends the run
                // after the frame under way and keeps what already landed, and the sheet goes
                // when the run returns (the Task below). Escape reaches it either way through
                // `.cancelAction`.
                Button(running ? "Stop" : "Cancel", role: .cancel) {
                    if running { model.stopRun() } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(running && model.stopRequested)
                .accessibilityIdentifier(running ? "autocrop.stop" : "autocrop.cancel")
                Button("Detect Crop") {
                    running = true
                    Task {
                        await model.autoCropSelection(aspect: aspect)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(running || targets == 0)
            }
            .padding(16)
        }
        .frame(width: 420)
    }

    private var countText: String {
        guard targets > 0 else { return "No frame in the selection is developed yet" }
        let frames = targets == 1 ? "1 frame" : "\(targets) frames"
        // Naming what will be SKIPPED matters more than naming what will run: the detector
        // reads the developed frame, so a selection of forty with three not yet developed
        // would otherwise look like it silently missed three.
        guard skipped > 0 else { return frames }
        return "\(frames), skipping \(skipped) not yet developed"
    }
}
