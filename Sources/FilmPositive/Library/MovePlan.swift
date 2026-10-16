import Foundation
import FilmSidecar

/// Move to Folder: the selected frames go to a folder the user picks or creates.
///
/// Two halves, split so the half that decides can be tested on a temp directory with no
/// window: `make` reads the disk and decides everything, `run` only carries it out.
///
/// **What travels with a scan.** The app writes exactly one file beside a raw, its
/// sidecar `<stem>.xmp` (`SidecarStore.sidecarURL`). Export writes into a folder the user
/// picks, never beside the scan, and the store's `.tmp-` files live for the length of one
/// write. So a frame is its raw plus that sidecar when the sidecar exists. The sidecar's
/// `source` block keys on name, size, mtime and fingerprint, none of which a move changes,
/// so the settings come across intact.
///
/// One file we do not write travels too: FilmLab Desktop's `<stem>.fprc` project file.
/// A roll edited there carries one beside every scan, and moving the scan without it would
/// strand that app's edits in a folder the scan has left. Nothing else with the same stem
/// moves (a camera JPEG shot beside the raw is a picture of its own).
///
/// **All or nothing before the first file moves.** Any name already taken at the
/// destination refuses the whole batch, because a half-moved selection is a worse thing to
/// hand back than a sentence saying why nothing happened.
struct MovePlan: Equatable {
    /// One file from here to there.
    struct Step: Equatable {
        let from: URL
        let to: URL
    }

    /// One frame: its raw first, then its companions.
    struct FrameMove: Equatable {
        let frame: URL
        let steps: [Step]
        var destinationFrame: URL { steps[0].to }
    }

    enum Refusal: Error, Equatable {
        case nothingToMove
        case notAFolder(String)
        /// Every frame is already in the destination.
        case sameFolder
        /// Names the destination already holds, raw or sidecar.
        case taken([String])
        case missing(String)
        /// Two raws share one sidecar (`IMG_1.CR2` and `IMG_1.DNG` both read `IMG_1.xmp`)
        /// and only one of them is moving. Moving the sidecar strips the other of its
        /// settings, leaving it strips the moved one; neither is ours to choose.
        case sharedSidecar(moving: String, staying: String)

        var sentence: String {
            switch self {
            case .nothingToMove: return "Nothing is selected to move."
            case .notAFolder(let name): return "\(name) is not a folder."
            case .sameFolder: return "Those frames are already in that folder."
            case .taken(let names):
                let shown = names.prefix(3).joined(separator: ", ")
                let more = names.count > 3 ? " and \(names.count - 3) more" : ""
                return "Nothing was moved. That folder already has \(shown)\(more)."
            case .missing(let name): return "Nothing was moved. \(name) is no longer on disk."
            case .sharedSidecar(let moving, let staying):
                return "Nothing was moved. \(moving) shares its settings file with \(staying), which is not being moved. Move them together."
            }
        }
    }

    let source: [URL]
    let destination: URL
    let frames: [FrameMove]
    /// False when the destination is on another volume, where a rename cannot work and a
    /// file is copied and then removed.
    let sameVolume: Bool

    /// The companions of one raw that exist on disk now.
    static func companions(of raw: URL, fileManager fm: FileManager = .default) -> [URL] {
        let candidates = [SidecarStore.sidecarURL(for: raw),
                          raw.deletingPathExtension().appendingPathExtension("fprc")]
        return candidates.filter { fm.fileExists(atPath: $0.path) }
    }

    /// Decides the whole move, or refuses it with the reason. Touches nothing.
    ///
    /// `sameVolume` is injectable so the cross-volume path can be exercised on one disk.
    static func make(moving raws: [URL], to destination: URL,
                     fileManager fm: FileManager = .default,
                     sameVolume: ((URL, URL) -> Bool)? = nil) throws -> MovePlan {
        guard !raws.isEmpty else { throw Refusal.nothingToMove }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue else {
            throw Refusal.notAFolder(destination.lastPathComponent)
        }
        let dest = destination.standardizedFileURL
        let moving = raws.filter { $0.deletingLastPathComponent().standardizedFileURL.path != dest.path }
        guard !moving.isEmpty else { throw Refusal.sameFolder }

        // Occupancy is judged case-insensitively: the volume very likely is, and a name
        // that differs only in case would overwrite on it.
        let present = Set(((try? fm.contentsOfDirectory(atPath: dest.path)) ?? []).map { $0.lowercased() })
        let movingPaths = Set(moving.map { $0.standardizedFileURL.path })
        var taken: [String] = []
        var claimed = Set<String>()
        var frames: [FrameMove] = []
        for raw in moving {
            guard fm.fileExists(atPath: raw.path) else { throw Refusal.missing(raw.lastPathComponent) }
            let companions = companions(of: raw, fileManager: fm)
            for c in companions {
                if let other = try? siblingSharing(c, with: raw, fileManager: fm),
                   !movingPaths.contains(other.standardizedFileURL.path) {
                    throw Refusal.sharedSidecar(moving: raw.lastPathComponent, staying: other.lastPathComponent)
                }
            }
            var steps: [Step] = []
            for file in [raw] + companions {
                let name = file.lastPathComponent
                // A sidecar shared by two raws that are BOTH moving travels once.
                guard !claimed.contains(name.lowercased()) || file == raw else { continue }
                if present.contains(name.lowercased()) || claimed.contains(name.lowercased()) { taken.append(name) }
                claimed.insert(name.lowercased())
                steps.append(Step(from: file, to: dest.appendingPathComponent(name)))
            }
            frames.append(FrameMove(frame: raw, steps: steps))
        }
        guard taken.isEmpty else { throw Refusal.taken(taken) }
        let from = moving[0].deletingLastPathComponent()
        let same = sameVolume?(from, dest) ?? Self.onSameVolume(from, dest)
        return MovePlan(source: moving, destination: dest, frames: frames, sameVolume: same)
    }

    /// Another raw in the same folder that reads the same sidecar, if there is one.
    static func siblingSharing(_ sidecar: URL, with raw: URL, fileManager fm: FileManager) throws -> URL? {
        let dir = raw.deletingLastPathComponent()
        let stem = raw.deletingPathExtension().lastPathComponent.lowercased()
        return try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first { url in
                url.lastPathComponent != raw.lastPathComponent
                    && url.deletingPathExtension().lastPathComponent.lowercased() == stem
                    && FolderSession.rawExtensions.contains(url.pathExtension.lowercased())
            }
    }

    static func onSameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let va = try? a.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let vb = try? b.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject else { return true }
        return va.isEqual(vb)
    }

    /// The move that puts everything back, for undo. The same checks run again when it is
    /// planned, because the user may have put a file of that name back in the meantime.
    var reverseRaws: [URL] { frames.map(\.destinationFrame) }
    var sourceFolder: URL { source[0].deletingLastPathComponent() }

    // MARK: carrying it out

    struct Outcome: Equatable {
        /// Frames whose raw now lives at the destination, keyed old to new.
        var moved: [(from: URL, to: URL)] = []
        /// One sentence per frame that did not move, or moved with a loose end.
        var problems: [String] = []

        static func == (a: Outcome, b: Outcome) -> Bool {
            a.moved.map(\.from) == b.moved.map(\.from) && a.moved.map(\.to) == b.moved.map(\.to) && a.problems == b.problems
        }
    }

    /// Moves frame by frame. A frame that fails part way is put back as it was, so each
    /// frame either arrives whole or stays whole; a failure is reported per file and never
    /// loses one.
    func run(fileManager fm: FileManager = .default) -> Outcome {
        var outcome = Outcome()
        for frame in frames {
            var done: [Step] = []
            var failure: String?
            for step in frame.steps {
                do { try Self.move(step, sameVolume: sameVolume, fileManager: fm); done.append(step) }
                catch { failure = "\(step.from.lastPathComponent): \(error.localizedDescription)"; break }
            }
            guard let failure else {
                outcome.moved.append((frame.frame, frame.destinationFrame))
                continue
            }
            // Undo this frame's finished steps in reverse, so the raw and its sidecar end
            // up together on one side.
            var stranded: [String] = []
            for step in done.reversed() {
                do { try Self.move(Step(from: step.to, to: step.from), sameVolume: sameVolume, fileManager: fm) }
                catch { stranded.append(step.to.path) }
            }
            let tail = stranded.isEmpty ? "" : " Left at \(stranded.joined(separator: ", "))."
            outcome.problems.append("Could not move \(failure).\(tail)")
        }
        return outcome
    }

    /// A rename on one volume. Across volumes, a copy and then a removal, and a copy that
    /// fails leaves nothing half-written at the destination.
    static func move(_ step: Step, sameVolume: Bool, fileManager fm: FileManager) throws {
        if sameVolume { try fm.moveItem(at: step.from, to: step.to); return }
        do { try fm.copyItem(at: step.from, to: step.to) }
        catch { try? fm.removeItem(at: step.to); throw error }
        do { try fm.removeItem(at: step.from) }
        catch {
            // Both copies exist and are complete. Take the new one back out so the frame
            // stays where the app thinks it is, and report.
            try? fm.removeItem(at: step.to)
            throw error
        }
    }
}
