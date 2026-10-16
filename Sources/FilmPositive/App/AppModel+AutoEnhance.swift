import Foundation
import FilmSidecar
import FilmPositiveCore

/// The Enhance section's wand. The rule is `AutoEnhance`, and this is where the model
/// hands it each selected frame's developed, cropped proxy and writes what comes back.
extension AppModel {

    /// Reads every selected frame and writes each one's result the moment it lands, so
    /// a thumbnail changes as its spinner clears. The whole run is still ONE undo step
    /// (`runWand`). Each frame is read on its own, so a roll of different exposures gets
    /// different values.
    ///
    /// A wand run RESETS THE WHOLE ENHANCE LAYER to 0 and then writes its own values. The
    /// solve starts from identity (`current: .identity`) and the result is written over
    /// identity, so after a run the layer holds the wand's values and nothing else, and a
    /// hand Contrast or Radiance from an earlier pass does not ride along. One Undo takes
    /// the whole run back, hand values included.
    func autoEnhanceSelection() {
        let jobs = selectedFrames.compactMap(wandJob).map { id, request, mono in (id, (request, mono)) }
        guard !jobs.isEmpty, !enhanceRunning else { return }
        let service = renders.service
        enhanceRunning = jobs.count > 1
        Task { @MainActor [weak self] in
            await self?.runWand(jobs, actionName: "Auto Enhance") { request, mono in
                guard let developed = try? await service.render(request) else { return nil }
                let proposal = await Task.detached(priority: .userInitiated) {
                    (try? AutoEnhance.propose(for: developed.frame, current: .identity, mono: mono)) ?? .none
                }.value
                return { Self.autoEnhanceEdit($0, proposal) }
            }
        }
    }

    /// The Enhance wand's write for one frame: over identity, never over what the frame
    /// carried, with the Auto record beside the values so the Auto button lights.
    nonisolated static func autoEnhanceEdit(_ s: Sidecar, _ p: AutoEnhance.Proposal) -> Sidecar {
        SidecarEdits.applyAuto(s, p.applied(to: .identity))
    }

    /// The shape both wands run in. Frame by frame: mark it as being read, `read` it,
    /// and write what comes back at once, so its thumbnail, the inspector and its sidecar
    /// change as its spinner clears instead of all together at the end.
    ///
    /// Each write goes through `apply` (render invalidated, save scheduled, the defaults
    /// commit) with undo registration switched off around it. After the last frame ONE step
    /// is registered that takes every written frame back to the sidecar it had when the run
    /// began (`registerRunUndo`), so Command Z still undoes the whole run in one press.
    ///
    /// No undo group is held open across the `await`s. With `groupsByEvent` on, the run loop
    /// closes a group of its own between events, and a group spanning a suspension never
    /// balances again. The one group this opens is opened and closed inside a single call.
    ///
    /// A frame the user edits by hand while the run is still going is taken back to its
    /// PRE-RUN sidecar by that one Undo, the hand edit included, because the run's step sits
    /// above the hand edit on the stack and restores what the frame held when the run began.
    ///
    /// `read` returns the edit for that frame, or nil to leave it alone (a failed render, a
    /// frame with no color). It is a parameter so a test can stand in for the render and
    /// the solve and look at the model between frames.
    ///
    /// Stop (`stopRun`) is checked before each frame is read and again before its
    /// result is written, never in between, so the run ends with every frame either written
    /// whole or untouched. A frame whose read was under way at the press is not written, and
    /// the one step covers exactly the frames that landed before it, or is not registered at
    /// all when none did.
    func runWand<Job>(_ jobs: [(Frame.ID, Job)], actionName: String,
                      read: (Job) async -> ((Sidecar) -> Sidecar)?) async {
        let bulk = jobs.count > 1
        enhanceRunning = bulk
        defer { enhanceReading = nil; enhanceRunning = false; colorRunning = false; stopRequested = false }
        var preRun: [Frame.ID: Sidecar] = [:]
        for (id, _) in jobs { if let f = frame(id) { preRun[id] = f.sidecar } }
        var written: [(Frame.ID, Sidecar)] = []
        for (id, job) in jobs {
            if stopRequested { break }
            if bulk { enhanceReading = id }
            let result = await read(job)
            if stopRequested { break }
            guard let edit = result, let before = preRun[id] else { continue }
            writeWandFrame(edit, to: id, preRun: before, actionName: actionName, into: &written)
        }
        registerRunUndo(restoring: written, actionName: actionName)
    }

    /// `runWand` with every result already in hand, so there is nothing to await: the same
    /// per-frame writes and the same one undo step. `applyAutoEnhance` and `applyColorAuto`
    /// are this, and they are how the tests write a wand's result on frames that cannot render.
    private func writeRun<Result>(_ results: [(Frame.ID, Result)], actionName: String,
                                  _ edit: (Sidecar, Result) -> Sidecar) {
        var written: [(Frame.ID, Sidecar)] = []
        for (id, r) in results {
            guard let before = frame(id)?.sidecar else { continue }
            writeWandFrame({ edit($0, r) }, to: id, preRun: before, actionName: actionName, into: &written)
        }
        registerRunUndo(restoring: written, actionName: actionName)
    }

    /// One frame of a wand run: `edit` written through `apply` with undo registration off,
    /// and the frame's pre-run sidecar added to `written` when the write changed it, so the
    /// run's one step (`registerRunUndo`) can take it back. A frame the edit left as it was
    /// is not written and not listed.
    private func writeWandFrame(_ edit: (Sidecar) -> Sidecar, to id: Frame.ID, preRun: Sidecar,
                                actionName: String, into written: inout [(Frame.ID, Sidecar)]) {
        guard let current = frame(id)?.sidecar else { return }
        undoManager.disableUndoRegistration()
        apply(edit, to: id, actionName: actionName)
        undoManager.enableUndoRegistration()
        if frame(id)?.sidecar != current, !written.contains(where: { $0.0 == id }) {
            written.append((id, preRun))
        }
    }

    /// Whether the Enhance Auto reads lit: every selected frame's layer still holds
    /// what the wand wrote, which is its Auto record in `look` (`SidecarEdits.autoLookID`).
    /// Any slider edit, a Look, Reset and the Color Auto all clear the record, so this is a
    /// flag read and never a re-solve.
    var autoEnhanceLit: Bool {
        let frames = selectedFrames
        return !frames.isEmpty && frames.allSatisfy { $0.sidecar.look == SidecarEdits.autoLookID }
    }

    /// The Enhance Auto's click. Dim, it runs the wand (zero, then write). Lit, it
    /// takes the layer back to 0 and clears the record. One undo step either way.
    func autoEnhanceClicked() {
        guard !enhanceRunning else { return }
        if autoEnhanceLit {
            applyToSelection(SidecarEdits.clearAuto, actionName: "Clear Auto Enhance")
        } else {
            autoEnhanceSelection()
        }
    }

    /// Whether a Look chip reads lit: every selected frame carries that look, so its layer
    /// still equals the look's values (`setEnhance` drops the name on any slider edit).
    func lookLit(_ look: Look) -> Bool {
        let frames = selectedFrames
        return !frames.isEmpty && frames.allSatisfy { $0.sidecar.look == look.id }
    }

    /// A Look chip's click, the same states as Auto. Dim, the look applies itself.
    /// Lit, the layer returns to 0.
    func lookClicked(_ look: Look) {
        if lookLit(look) {
            applyToSelection(SidecarEdits.resetEnhance, actionName: "Clear \(look.name)")
        } else {
            applyToSelection({ SidecarEdits.applyLook($0, look) }, actionName: "Apply \(look.name)")
        }
    }

    /// What the wand reads for one frame: its proxy develop at identity enhance (the rule reads
    /// the frame as develop left it), and whether its effective stock is black and white,
    /// which keeps every color slider at 0.
    func wandJob(_ f: Frame) -> (Frame.ID, RenderRequest, Bool)? {
        guard let develop = renders.defaults.develop(for: f.sidecar) else { return nil }
        let request = RenderRequest(imageURL: f.url, develop: develop,
                                    geometry: f.sidecar.geometry ?? GeometrySettings(),
                                    enhance: .identity, scale: .proxy)
        return (f.id, request, isMonoStock(f))
    }

    /// Writes proposals already in hand as one Enhance wand run (`writeRun`): frame by frame,
    /// ONE undo step.
    func applyAutoEnhance(_ proposals: [(Frame.ID, AutoEnhance.Proposal)]) {
        writeRun(proposals, actionName: "Auto Enhance", Self.autoEnhanceEdit)
    }

    /// Whether the Color Auto reads lit: every selected frame's Warmth and Tint still
    /// equal the pair the Color Auto last wrote there (`Sidecar.colorAuto`). A Warmth or Tint
    /// edit, a Look, Reset, a paste and the Enhance Auto all clear the record, so this is a
    /// read and never a re-solve.
    var colorAutoLit: Bool {
        let frames = selectedFrames
        return !frames.isEmpty && frames.allSatisfy { f in
            f.sidecar.colorAuto?.isHeld(by: f.sidecar.enhance) ?? false
        }
    }

    /// The Color Auto's click. Dim, it runs the neutralizer and records the pair. Lit,
    /// it sets Warmth and Tint back to 0 and clears the record. One undo step either way.
    func colorAutoClicked() {
        guard !enhanceRunning else { return }
        if colorAutoLit {
            applyToSelection(SidecarEdits.clearColorAuto, actionName: "Clear Auto Color")
        } else {
            neutraliseCastSelection()
        }
    }

    /// Neutralize cast, the button beside the Color group: Warmth and Tint
    /// set so the frame's near-grey pixels sit near neutral, read without the frame's own Warmth
    /// and Tint, a neutral moved at most 10 C* and a scene sized cast left alone
    /// (`AutoEnhance.neutralisation`). Warmth and Tint only, no warm offset. Per selected frame,
    /// read from that frame, one undo step. A frame with no color is left alone. Each frame is
    /// written as its read ends, the same as the Enhance wand (`runWand`).
    func neutraliseCastSelection() {
        let jobs: [(Frame.ID, (RenderRequest, EnhanceSettings))] = selectedFrames.compactMap { f in
            guard let develop = renders.defaults.develop(for: f.sidecar) else { return nil }
            let request = RenderRequest(imageURL: f.url, develop: develop,
                                        geometry: f.sidecar.geometry ?? GeometrySettings(),
                                        enhance: .identity, scale: .proxy)
            return (f.id, (request, f.sidecar.enhance ?? .identity))
        }
        guard !jobs.isEmpty, !enhanceRunning else { return }
        let service = renders.service
        enhanceRunning = jobs.count > 1
        colorRunning = enhanceRunning
        Task { @MainActor [weak self] in
            await self?.runWand(jobs, actionName: "Neutralize Cast") { request, current in
                guard let developed = try? await service.render(request) else { return nil }
                let wt = await Task.detached(priority: .userInitiated) {
                    try? AutoEnhance.neutralising(developed.frame, current: current)
                }.value
                guard let wt = wt.flatMap({ $0 }) else { return nil }
                let pair = WarmthTint(warmth: wt.warmth, tint: wt.tint)
                return { SidecarEdits.applyColorAuto($0, pair) }
            }
        }
    }

    /// Writes pairs already in hand as one Color wand run, each with its record beside it so
    /// the Color Auto lights: frame by frame, ONE undo step (`writeRun`).
    func applyColorAuto(_ moves: [(Frame.ID, WarmthTint)]) {
        writeRun(moves, actionName: "Neutralize Cast", SidecarEdits.applyColorAuto)
    }
}
