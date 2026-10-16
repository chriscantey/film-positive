import Foundation
import FilmSidecar
import FilmPositiveCore

/// The one place that answers "what develop settings does this frame render through right
/// now", for a frame that has a develop layer and for one that does not.
///
/// The defaults live here, in memory, so browsing a folder and reading them writes no
/// sidecar files.
///
/// The reason this is a struct rather than a function on the model: its
/// input is SNAPSHOTTED when a folder is opened. A preference change mid-session must not
/// be able to make a frame commit different settings from the ones the user was looking at
/// when they reached for the control. The snapshot is refreshed by `AppModel` at folder
/// open and when the profile library itself is rebuilt, never per read.
///
/// One function serves BOTH readers, which is the property that makes the funnel honest:
/// `RenderCoordinator.request(for:)` renders through it, and `AppModel.apply` commits
/// exactly it. Two implementations would drift on the first change and the file would then
/// disagree with the picture.
struct DevelopDefaults {
    /// The library the defaults resolve a capture's film name through. Nil only before the
    /// first library load, where there is no honest answer and a frame stays undeveloped.
    var profiles: ProfileLibrary?
    init(profiles: ProfileLibrary? = nil) {
        self.profiles = profiles
    }

    /// The develop layer a sidecar renders and commits through: its own when it has one,
    /// the defaults otherwise. Nil only when no library is loaded.
    func develop(for sidecar: Sidecar) -> DevelopSettings? {
        if let own = sidecar.develop { return own }
        return profiles?.initialDevelop(capture: sidecar.capture)
    }

    /// The defaults alone, ignoring anything the sidecar already carries. What the Positive
    /// button commits, and what a test compares a committed frame against.
    func initial(for sidecar: Sidecar) -> DevelopSettings? {
        profiles?.initialDevelop(capture: sidecar.capture)
    }
}
