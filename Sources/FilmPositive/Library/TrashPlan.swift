import Foundation

/// Move to Trash. A frame goes to the Trash the way it goes to another folder: the
/// raw with its companions (`MovePlan.companions`, its `.xmp` and FilmLab's `.fprc`), so a
/// scan put back from the Trash comes back with its settings, and no settings file is left
/// behind naming a scan that is gone.
///
/// Split the way `MovePlan` is: `make` decides and refuses, `run` carries it out through an
/// injected trasher, so a test never touches the real Trash.
struct TrashPlan: Equatable {
    struct FrameTrash: Equatable {
        let frame: URL
        /// The raw first, then its companions.
        let files: [URL]
    }

    let frames: [FrameTrash]

    /// Same refusals as a move, for the same reasons: nothing selected, a file already gone,
    /// or a sidecar shared with a raw that is staying (trashing it would strip that frame).
    static func make(trashing raws: [URL], fileManager fm: FileManager = .default) throws -> TrashPlan {
        guard !raws.isEmpty else { throw MovePlan.Refusal.nothingToMove }
        let trashingPaths = Set(raws.map { $0.standardizedFileURL.path })
        var claimed = Set<String>()
        var frames: [FrameTrash] = []
        for raw in raws {
            guard fm.fileExists(atPath: raw.path) else { throw MovePlan.Refusal.missing(raw.lastPathComponent) }
            var files = [raw]
            for c in MovePlan.companions(of: raw, fileManager: fm) {
                if let other = try? MovePlan.siblingSharing(c, with: raw, fileManager: fm),
                   !trashingPaths.contains(other.standardizedFileURL.path) {
                    throw MovePlan.Refusal.sharedSidecar(moving: raw.lastPathComponent, staying: other.lastPathComponent)
                }
                // A sidecar shared by two raws that are BOTH going goes once.
                guard claimed.insert(c.standardizedFileURL.path).inserted else { continue }
                files.append(c)
            }
            frames.append(FrameTrash(frame: raw, files: files))
        }
        return TrashPlan(frames: frames)
    }

    struct Outcome {
        /// Per frame that went: every file, original to where the trasher put it.
        var trashed: [(frame: URL, files: [(from: URL, to: URL)])] = []
        var problems: [String] = []
    }

    /// Frame by frame. A frame that fails part way has its finished files put back, so each
    /// frame either goes whole or stays whole.
    func run(trash: (URL) throws -> URL, fileManager fm: FileManager = .default) -> Outcome {
        var outcome = Outcome()
        for frame in frames {
            var done: [(from: URL, to: URL)] = []
            var failure: String?
            for file in frame.files {
                do { done.append((file, try trash(file))) }
                catch { failure = "\(file.lastPathComponent): \(error.localizedDescription)"; break }
            }
            guard let failure else { outcome.trashed.append((frame.frame, done)); continue }
            var stranded: [String] = []
            for step in done.reversed() {
                do { try fm.moveItem(at: step.to, to: step.from) } catch { stranded.append(step.to.path) }
            }
            let tail = stranded.isEmpty ? "" : " Left in the Trash: \(stranded.joined(separator: ", "))."
            outcome.problems.append("Could not move \(failure) to the Trash.\(tail)")
        }
        return outcome
    }

    /// The real trasher. `trashItem` hands back where the file landed, which is what undo
    /// needs to bring it home.
    static func systemTrash(_ url: URL) throws -> URL {
        var landed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
        guard let landed = landed as URL? else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "the Trash did not say where it put the file"])
        }
        return landed
    }
}
