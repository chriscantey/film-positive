import Foundation
import SwiftUI
import Observation
import FilmSidecar
import FilmPositiveCore

/// The looks row's own state: one `LookStore` plus the transient message the row prints
/// under itself after a save, an import or a reset.
///
/// One instance for the process. The store is a single file in Application Support, so two
/// instances would be two views of the same file with no way to agree after a write. The row
/// can still be handed its own instance for a preview or a test.
///
/// Every method returns an error string rather than throwing or holding its own alert, so the
/// row can hand it to `AppModel.lastError` and the window shows the complete text.
@MainActor
@Observable
final class LooksModel {
    static let shared = LooksModel()

    private(set) var store: LookStore
    /// Shown under the row, plain and short: what the last action did.
    var status: String?
    /// Anything wrong with the files at launch, reported once by the row.
    private(set) var startupProblems: [LookStore.Problem]
    private var reportedStartup = false

    init(directory: URL? = nil) {
        var problems: [LookStore.Problem] = []
        var dir: URL
        if let directory {
            dir = directory
        } else {
            do {
                dir = try LookStore.defaultDirectory()
            } catch {
                // Falling back silently would be the worst outcome: Save Look would appear to
                // work and the preset would be gone at the next launch with nothing said.
                dir = FileManager.default.temporaryDirectory.appendingPathComponent("FilmPositiveLooks", isDirectory: true)
                problems.append(LookStore.Problem(
                    file: dir, movedTo: nil,
                    message: "Application Support is not available (\(error)), so saved looks will "
                           + "not survive a relaunch. They are going to \(dir.path) for now."))
            }
        }
        var opened = LookStore(directory: dir)
        problems.append(contentsOf: opened.load())
        store = opened
        startupProblems = problems
    }

    func takeStartupProblem() -> String? {
        guard !reportedStartup, !startupProblems.isEmpty else { return nil }
        reportedStartup = true
        return startupProblems.map(\.message).joined(separator: "\n")
    }

    var looks: [Look] { store.looks }
    var hiddenCount: Int { store.hiddenLooks.count }

    // MARK: actions, each returning an error string or nil

    func saveLook(named name: String, settings: EnhanceSettings) -> String? {
        do {
            let look = try store.saveLook(named: name, settings: settings)
            status = "Saved \(look.name)."
            return nil
        } catch {
            return "Could not save the look: \(error)"
        }
    }

    func delete(_ id: String) -> String? {
        do {
            switch try store.delete(id) {
            case .hidden(let look): status = "Removed \(look.name). Reset Presets brings it back."
            case .removed(let look): status = "Deleted \(look.name)."
            }
            return nil
        } catch {
            return "Could not delete the look: \(error)"
        }
    }

    func restoreAll() -> String? {
        do {
            let restored = try store.restoreAll()
            status = restored.isEmpty ? "Nothing was hidden." : "Restored \(list(restored))."
            return nil
        } catch {
            return "Could not restore the shipped presets: \(error)"
        }
    }

    func exportData() -> (Data?, String?) {
        do { return (try store.exportData(), nil) } catch { return (nil, "Could not write the look file: \(error)") }
    }

    func exported(count: Int) { status = "Exported \(count) \(count == 1 ? "look" : "looks")." }

    /// Reads a `.fplooks` file and lists what came in.
    func importLooks(from url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let result = try store.importLooks(from: data)
            if result.isEmptyChange {
                status = "\(url.lastPathComponent): every preset in it was already here."
            } else {
                var parts = ["Imported \(list(result.listed))"]
                if !result.unchanged.isEmpty { parts.append("\(result.unchanged.count) already here") }
                status = parts.joined(separator: ", ") + "."
            }
            return nil
        } catch {
            return "Could not read \(url.lastPathComponent): \(error)"
        }
    }

    private func list(_ looks: [Look]) -> String {
        looks.map(\.name).joined(separator: ", ")
    }
}
