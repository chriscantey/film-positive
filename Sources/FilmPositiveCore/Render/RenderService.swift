import Foundation
import CoreGraphics
import FilmSidecar

// The render contract the UI codes against. A request is the sidecar's value types plus a
// scale. A result is a display-referred RGB16 frame plus the analysis the inspector shows.
// One service implements it: the CPU service, the real engine on the accelerated develop
// path.

public enum RenderScale: Hashable, Sendable {
    /// LibRaw `half_size` decode, the grid and viewer proxy.
    case proxy
    /// The proxy's developed frame halved again (a quarter of the pixels, the same color
    /// path), for the interactive slider drag. The settled `.proxy` render follows when the
    /// drag ends.
    case preview
    case full
}

public struct RenderRequest: Equatable, Sendable {
    public var imageURL: URL
    public var develop: DevelopSettings
    public var geometry: GeometrySettings
    public var enhance: EnhanceSettings
    public var scale: RenderScale

    public init(imageURL: URL, develop: DevelopSettings, geometry: GeometrySettings = GeometrySettings(),
                enhance: EnhanceSettings = .identity, scale: RenderScale = .proxy) {
        self.imageURL = imageURL; self.develop = develop; self.geometry = geometry; self.enhance = enhance; self.scale = scale
    }
}

public struct RenderResult: Sendable {
    /// Display-referred 16-bit RGB after develop, geometry and enhance.
    public let frame: DecodedFrame
    /// The develop analysis (anchor, base, ranges, tone gamma). Optional because a stand-in
    /// service may have nothing to report.
    public let analysis: FrameAnalysis?
    /// Uptime nanoseconds when the service finished, on the thread that rendered, so a
    /// caller can measure its own hop back to the main actor.
    public let renderedAt: UInt64
    public init(frame: DecodedFrame, analysis: FrameAnalysis?) {
        self.frame = frame; self.analysis = analysis; self.renderedAt = DispatchTime.now().uptimeNanoseconds
    }
}

public enum RenderError: Error, CustomStringConvertible {
    /// The engine could not start at all, with the reason. Surfaced in the UI.
    case engineUnavailable(String)
    case badRotation(Int)

    public var description: String {
        switch self {
        case .engineUnavailable(let why): return why
        case .badRotation(let r): return "rotation must be 0, 90, 180 or 270, got \(r)"
        }
    }
}

public protocol RenderService: Sendable {
    func render(_ request: RenderRequest) async throws -> RenderResult

    /// What the film-edge estimator has ALREADY said about this file, without measuring
    /// anything. See `RebateStatus`.
    func rebateStatus(for url: URL) -> RebateStatus

    /// One square patch of this frame's PROXY decode, clip-guarded per-channel means, for
    /// the eyedropper. `point` is normalized in decode space and `radius` is a fraction of
    /// the frame width.
    ///
    /// It lives on the service rather than on the view for one reason: `DecodedFrame` is a
    /// whole proxy of raw pixels and it has no business crossing into the UI layer to be
    /// indexed there. The service already holds the decode the closeup is looking at, so
    /// this is a cache hit and the app never touches a pixel buffer.
    ///
    /// The PROXY, always, for the same reason `rebateEstimate` standardises on it: the two
    /// scales genuinely disagree by about 1.5 percent in red, so measuring on the decode at
    /// hand would put one base in the preview and another in the export.
    func samplePatch(url: URL, at point: CGPoint, radius: Double) async -> [Double]?
}

public extension RenderService {
    /// A service that does not memoise (every stand-in in the tests, and the headless
    /// paths) has nothing to report, and nothing to report is `.notComputed` rather than a
    /// refusal. The two are different answers and the inspector treats them differently.
    func rebateStatus(for url: URL) -> RebateStatus { .notComputed }
}

/// What the memoised film-edge estimate says about one file, read WITHOUT computing it.
///
/// The inspector's no-edge warning is driven from this and never from a completed
/// render, so drawing the inspector cannot start a decode. The three cases are genuinely
/// three: `.notComputed` means nobody has looked yet, `.refused` means the estimator looked
/// and found no clean edge, and only `.found` is an answer. Collapsing the first two would
/// make a folder that has not been scrolled look like a folder of frames with no film edge.
public enum RebateStatus: Equatable, Sendable {
    /// Not measured yet: no render of this frame has run, or the file could not be
    /// identified for the memo.
    case notComputed
    /// Measured, and the estimator refused. Fewer than its clean-pixel floor, or no
    /// cluster below the bare-light cap.
    case refused
    /// Measured, with the per-channel base means it found.
    case found([Double])

}

public extension RenderService {
    /// A stand-in service has no decode to sample, and nil is the honest answer: the
    /// eyedropper refuses the pick rather than writing a made-up base.
    func samplePatch(url: URL, at point: CGPoint, radius: Double) async -> [Double]? { nil }
}

// MARK: - CPU service

/// The engine: LibRaw decode (half_size for proxies), the CPU analysis, the develop
/// tables, geometry, then the enhance stage. Decodes are cached per URL and scale so a
/// slider change never decodes again.
public final class CPURenderService: RenderService, @unchecked Sendable {
    public let profiles: ProfileLibrary
    public var enhance: any EnhanceStage
    private let cache = DecodeCache(capacity: 6)
    /// The developed frame (after develop and geometry, before enhance) for the last few
    /// requests, so an enhance-only edit re-runs only the enhance chain. Slider-to-pixel
    /// measured 449 to 628 ms on x86 with develop re-run every time, and develop plus
    /// geometry was about 400 ms of that.
    /// Budgeted in BYTES, PER SCALE. A count is the wrong unit because a developed frame is
    /// 27 MB at proxy scale and under 7 MB at preview scale, so one number is either too
    /// small to hold a selection mid-drag or large enough to hold a gigabyte of proxies at
    /// rest.
    ///
    /// A capacity of 4 frames is too small: dragging a slider with more than four frames
    /// selected evicts and re-develops every one of them on every tick, so the work per tick
    /// grows with the selection instead of staying flat.
    ///
    /// The budget is split rather than one pot. A single 512 MB budget fixes the drag and
    /// made the full test suite take 2.9 hours instead of 11 minutes, with one timing
    /// assertion failing at 21.5 s against a 0.5 s bound. The same test passes on its own, so
    /// it was memory pressure rather than a logic fault: the heavy suites hold
    /// 54-million-sample buffers, and half a gigabyte of retained proxies on top of that
    /// pushed the machine into swap. Separate pots keep proxy pressure low while still giving
    /// a drag the previews it needs.
    private let developed = DevelopedCache(budgets: [.preview: 192 << 20, .proxy: 96 << 20, .full: 64 << 20])

    /// How the raw comes off disk. Injectable for one reason: a synthetic frame with a
    /// known rebate border is the only way to test the base resolution end to end without
    /// shipping a raw file per case. Production passes nothing and gets LibRaw.
    public typealias RawDecode = @Sendable (_ url: URL, _ halfSize: Bool) throws -> DecodedFrame

    private let decodeRaw: RawDecode
    private let runsLock = NSLock()
    private var rebateRuns = 0
    /// The rebate estimate, keyed by file identity plus mtime so it survives
    /// decode-cache eviction. Unbounded on purpose and cheap to be so: three doubles and a
    /// path per frame the session has looked at, which is kilobytes for a folder of
    /// hundreds, against a histogram over a full proxy decode per miss.
    private let rebateLock = NSLock()
    private var rebateMemo: [RebateKey: [Double]?] = [:]
    /// The picture estimate, keyed by file and crop, under the same lock.
    private var pictureMemo: [PictureKey: [Double]?] = [:]

    /// How many times the rebate estimator has actually run, as opposed to been asked for.
    /// The memo lives on the decode cache entry, so this is what proves a second render of
    /// the same frame costs nothing.
    public var rebateEstimateRuns: Int { runsLock.lock(); defer { runsLock.unlock() }; return rebateRuns }

    /// The memoised film-edge estimate for a file, computing NOTHING.
    ///
    /// The inspector's warning glyph is driven from data that already exists, so this only
    /// ever reads the side map `rebateEstimate(for:)` fills. A file the session
    /// has never rendered answers `.notComputed`, which is what makes "we have not looked"
    /// distinguishable from "we looked and there is no edge".
    ///
    /// Deliberately NOT keyed on the decode-cache entry's own memo: that one dies with the
    /// entry, so reading it would make the same frame answer differently either side of a
    /// scroll. The side map is keyed on file identity plus mtime and survives eviction.
    public func rebateStatus(for url: URL) -> RebateStatus {
        guard let key = Self.rebateKey(url) else { return .notComputed }
        rebateLock.lock()
        let hit = rebateMemo[key]
        rebateLock.unlock()
        guard let hit else { return .notComputed }
        guard let ratios = hit else { return .refused }
        return .found(ratios)
    }

    public init(profiles: ProfileLibrary, enhance: any EnhanceStage = CoreImageEnhance(),
                decode: RawDecode? = nil) {
        self.profiles = profiles; self.enhance = enhance
        self.decodeRaw = decode ?? { url, half in try RawDecoder(halfSize: half).decode(url) }
    }

    /// The develop input with no frame to measure, so no film edge reading is possible. This
    /// is the pure settings-to-input mapping. The render path uses the overload below.
    public func developInput(for develop: DevelopSettings) -> DevelopInput {
        developInput(for: develop, measureRebate: { nil })
    }

    /// The develop input for a frame whose base CAN be measured.
    ///
    /// The base is resolved here and nowhere else, through `BaseResolver`, which
    /// owns the precedence: a picked pair beats this frame's own film edge beats an
    /// estimate from the picture beats neutral. The closures are only called in the case
    /// that can use them, so a mono stock, a picked pair, or Auto color off never pays
    /// for them.
    ///
    /// `tone` chooses the operator: `.none` runs no tone step, `.flat` runs the anchored
    /// one, and `.print` runs the anchored placement plus the paper contrast stage. See
    /// `toneOperator(for:)` for the one case where the sidecar does not get the choice.
    public func developInput(for develop: DevelopSettings,
                             measureRebate: () -> [Double]?,
                             estimatePicture: () -> [Double]? = { nil }) -> DevelopInput {
        let r = profiles.resolveFilm(develop.stock)
        let base = BaseResolver.resolve(develop: develop, profiles: profiles,
                                        measureRebate: measureRebate,
                                        estimatePicture: estimatePicture)
        var input = DevelopInput(ratios: base.ratios, dyeGamma: r.dyeGamma, mono: r.profile.isMono,
                            autoTone: develop.appliesTone,
                            // The person's own grade, carried through unchanged. It is a
                            // DELTA on whatever `BaseResolver` just decided, so it composes
                            // with a later improvement to the edge reader rather than
                            // freezing today's answer.
                            colourAxes: develop.colourAxes,
                            autoToneOperator: toneOperator(for: develop.tone),
                            // The STOCK decides, not a control. A mono stock never balances:
                            // its three channels are one channel and there is nothing to
                            // balance against.
                            balanceChannels: r.profile.balancesChannels && !r.profile.isMono,
                            // And the stock's own PARAMETERS, from the profile file rather
                            // than from a constant here. A stock that declares the activity
                            // with no parameters gets the defaults, which is what a profile
                            // written before the parameters existed means.
                            balanceStrength: r.profile.channelBalanceSettings?.strength ?? 1,
                            baseSource: base.source)
        // `develop.highlightAxes` is NOT carried: a frame's sidecar never moves the physics
        // ceilings, so a file that carries the field renders exactly as one without it.
        // `DevelopInput.highlightAxes` stays identity here and is a kernel input for
        // profile-building tools alone.
        //
        // The Tone row's Adjust, carried through unchanged. nil is the preset.
        input.toneAdjust = develop.toneAdjust
        // The Tone row's Stretch: nil is 1, the frame's own ceiling. The kernel clamps it.
        // The reference is the stock's, through the same resolution the dye gammas take.
        input.stretch = develop.stretch ?? 1
        input.whiteDensity = profiles.whiteDensity(for: develop.stock)
        return input
    }

    /// Which Auto Tone operator this service runs. The app never changes it; it is a seam
    /// for a run that has to hold one operator across a whole set of frames. Not part of
    /// `DevelopedCache.Key`, because it is set once at construction rather than per request.
    public var autoToneOperator: AutoToneOperator = .anchored

    /// Which tone operator a frame's `ToneMode` selects.
    ///
    /// The sidecar owns the choice, with one exception: a service-wide override set to
    /// anything other than the default WINS over it. That seam exists because a run that
    /// has to hold one operator across a whole set of frames cannot have individual
    /// sidecars voting, and it is written as "not the default" rather than by naming an
    /// operator so that changing the enum is a one-line change here and not a compile
    /// error.
    public func toneOperator(for tone: ToneMode) -> AutoToneOperator {
        guard autoToneOperator == .anchored else { return autoToneOperator }
        return tone == .print ? .print : .anchored
    }

    public func decoded(_ url: URL, scale: RenderScale) throws -> DecodedFrame {
        try decodeEntry(url, scale: scale).frame
    }

    /// The eyedropper's sample. Not memoised: the user picks once and the answer depends on
    /// where they aimed, so there is nothing to cache on. The DECODE underneath is cached,
    /// which is the expensive half, and in the closeup it is already warm because the pane
    /// the user is clicking on was rendered from it.
    public func samplePatch(url: URL, at point: CGPoint, radius: Double) async -> [Double]? {
        guard let frame = try? decoded(url, scale: .proxy) else { return nil }
        return Calibrator.patchEstimate(frame, at: point, radius: radius)
    }

    private func decodeEntry(_ url: URL, scale: RenderScale) throws -> DecodeEntry {
        if let e = cache.get(url, scale) { return e }
        let e = DecodeEntry(frame: try decodeRaw(url, scale != .full))
        cache.put(url, scale, e)
        return e
    }

    private func countRebateRun() { runsLock.lock(); rebateRuns += 1; runsLock.unlock() }

    /// The film-edge estimate for a frame, ALWAYS taken on the PROXY decode whatever scale
    /// is being rendered.
    ///
    /// Measuring on the decode at hand is the obvious thing and it is wrong. The two scales
    /// disagree in fact: the edge reader on one UltraMax frame reads R/G 0.4743 off
    /// the proxy and 0.4671 off the full decode, 1.5 percent apart in red, because LibRaw's
    /// `half_size` averages the Bayer greens while the full decode demosaics them and the
    /// strips clip differently. Per-scale measurement would therefore put one base in the
    /// preview and another in the export.
    ///
    /// The proxy is the right one to standardise on: it is the decode the grid and the
    /// viewer have almost always already made, so this is usually free, and it costs one
    /// half decode in the one case that has not (a full export of a frame never viewed).
    /// The memo rides that proxy entry, so the estimate is once per FRAME rather than once
    /// per frame and scale, and it still dies with the decode cache.
    private func rebateEstimate(for url: URL) -> [Double]? {
        // A memo that lives ONLY on the decode cache entry dies the moment that entry is
        // evicted. Every visible cell renders, so scrolling a folder of 114 frames down and
        // back evicts the early decodes and would recompute every estimate on the way back
        // up.
        //
        // The estimate is a pure function of the file's bytes, so it survives eviction in a
        // side map keyed by file identity plus modification time. The mtime is what makes
        // that safe: a file edited in place gets a fresh key rather than a stale answer.
        let key = Self.rebateKey(url)
        if let key {
            rebateLock.lock()
            let hit = rebateMemo[key]
            rebateLock.unlock()
            if let hit { return hit }
        }

        // A raw that decodes at full and not at half is not a thing that happens, and
        // quietly measuring a different scale instead would reintroduce the exact
        // inconsistency this method exists to remove. No measurement is the honest answer.
        guard let entry = try? decodeEntry(url, scale: .proxy) else { return nil }
        let value = entry.rebateEstimate { frame in
            self.countRebateRun()
            return Calibrator.rebateEstimate(frame)
        }
        // A refusal is memoised too. `nil` here means the estimator looked and found no
        // clean edge, which is an answer, and recomputing it on every scroll pass is the
        // exact cost this map exists to remove.
        if let key {
            rebateLock.lock()
            rebateMemo[key] = .some(value)
            rebateLock.unlock()
        }
        return value
    }

    /// The picture estimate for a frame and crop, ALWAYS on the PROXY decode, for the same
    /// reason as the edge (`rebateEstimate(for:)`): one base in the preview and the export.
    ///
    /// Called only after the edge reader refused. Memoised by file identity plus crop, so a
    /// slider drag on a frame with no film edge pays for it once. A crop change is a new
    /// visible frame and a new estimate.
    private func pictureEstimate(for url: URL, crop: CropRect?) -> [Double]? {
        let key = Self.rebateKey(url).map { PictureKey(file: $0, crop: crop.map { [$0.x, $0.y, $0.w, $0.h] }) }
        if let key {
            rebateLock.lock()
            let hit = pictureMemo[key]
            rebateLock.unlock()
            if let hit { return hit }
        }
        guard let frame = try? decoded(url, scale: .proxy) else { return nil }
        let box = crop.map { Geometry.box($0, width: frame.width, height: frame.height) }
        let value = Calibrator.pictureEstimate(frame, box: box)
        if let key {
            rebateLock.lock()
            pictureMemo[key] = .some(value)
            rebateLock.unlock()
        }
        return value
    }

    struct PictureKey: Hashable {
        let file: RebateKey
        let crop: [Double]?
    }

    /// File identity plus modification time, or nil when the file cannot be stat'd, in
    /// which case nothing is memoised across decodes and the decode entry's own memo still
    /// covers the common case.
    private static func rebateKey(_ url: URL) -> RebateKey? {
        guard let v = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey, .contentModificationDateKey]),
              let date = v.contentModificationDate else { return nil }
        return RebateKey(path: url.standardizedFileURL.path, modified: date.timeIntervalSince1970)
    }

    struct RebateKey: Hashable {
        let path: String
        let modified: TimeInterval
    }

    public func render(_ request: RenderRequest) async throws -> RenderResult {
        guard [0, 90, 180, 270].contains(request.geometry.rotate) else { throw RenderError.badRotation(request.geometry.rotate) }
        let (developedFrame, analysis) = try developedStage(for: request)
        let out = try enhance.apply(developedFrame, settings: request.enhance)
        return RenderResult(frame: out, analysis: analysis)
    }

    /// The frame after develop and geometry, before enhance, from the cache when the
    /// develop and geometry settings match. A `.preview` is the `.proxy` result halved,
    /// cached under its own key, so the first drag tick after a develop change pays the
    /// halve once and every later tick pays only the enhance chain.
    private func developedStage(for request: RenderRequest) throws -> (DecodedFrame, FrameAnalysis) {
        let key = DevelopedCache.Key(url: request.imageURL, scale: request.scale, develop: request.develop, geometry: request.geometry)
        if let hit = developed.get(key) { return (hit.frame, hit.analysis) }
        let developedFrame: DecodedFrame
        let analysis: FrameAnalysis
        if request.scale == .preview {
            var proxyRequest = request
            proxyRequest.scale = .proxy
            let (proxyFrame, an) = try developedStage(for: proxyRequest)
            developedFrame = Geometry.halve(proxyFrame)
            analysis = an
        } else {
            let decoded = try decoded(request.imageURL, scale: request.scale)
            // The rebate lives OUTSIDE the crop, so the estimate is taken on a decoded
            // frame before any geometry. Measuring the cropped image would find the
            // picture's own darkest pixels and call them film base. Note this is the
            // opposite of the tone box just below, and deliberately so: the tone is a fact
            // about the PICTURE and the base is a fact about the FILM it sits on.
            let g = request.geometry
            // The picture estimate is the opposite: it reads the VISIBLE frame, the crop,
            // because it is an estimate off the picture and the picture is what is visible.
            let input = developInput(for: request.develop,
                                     measureRebate: { self.rebateEstimate(for: request.imageURL) },
                                     estimatePicture: { self.pictureEstimate(for: request.imageURL, crop: g.crop) })
            // Measure the tone over the picture rather than over the scan, when there is a
            // crop to say where the picture is. Only the anchored placement asks for
            // this, which Flat and Print both run: the no-tone render is the
            // roll-consistent reference and must not move.
            //
            // The box is the crop expressed on the decode. Under a straighten it is the
            // unrotated bounding region rather than the exact rotated rectangle, which is
            // close enough for a histogram and never includes the rebate.
            let toneBox = input.autoTone
                ? g.crop.map { Geometry.box($0, width: decoded.width, height: decoded.height) } : nil
            let (an, _) = DevelopMath.analyze(decoded, input: input, toneBox: toneBox)
            let tables = DevelopTables(analysis: an, mono: input.mono, axisOffsets: input.axisOffsets)
            // Develop the whole frame, then the geometry contract in order: straighten,
            // crop, rotate, flip. A zero angle takes the copy-only path, so the
            // unstraightened result is exactly the tables' output on the crop box.
            if FineRotation.isNegligible(g.straightenDegrees) {
                let box = g.crop.map { Geometry.box($0, width: decoded.width, height: decoded.height) }
                developedFrame = tables.apply(decoded, box: box, flip: g.flip, rotate: g.rotate)
            } else {
                developedFrame = Geometry.apply(tables.apply(decoded, flip: false, rotate: 0), g)
            }
            analysis = an
        }
        developed.put(key, frame: developedFrame, analysis: analysis)
        return (developedFrame, analysis)
    }
}

/// One decoded frame plus whatever is expensive to learn from it and cheap to keep.
///
/// Today that is the rebate estimate, which costs a pass over the frame's outer strips and
/// must not run per render tick. Hanging the memo on the cache ENTRY rather than on a
/// second table beside it is what makes the invalidation free: when the LRU drops the
/// decode, the estimate goes with it, and there is no way for the two to disagree.
///
/// A nil estimate (no readable edge) is memoised too. "We looked and found nothing" is an
/// answer, and re-deriving it every tick is the same cost as deriving it.
final class DecodeEntry: @unchecked Sendable {
    let frame: DecodedFrame
    private var computed = false
    private var estimate: [Double]?
    private let lock = NSLock()

    init(frame: DecodedFrame) { self.frame = frame }

    func rebateEstimate(_ compute: (DecodedFrame) -> [Double]?) -> [Double]? {
        lock.lock(); defer { lock.unlock() }
        if computed { return estimate }
        estimate = compute(frame)
        computed = true
        return estimate
    }
}

final class DecodeCache: @unchecked Sendable {
    struct Key: Hashable { let url: URL; let scale: RenderScale }
    private var order: [Key] = []
    private var store: [Key: DecodeEntry] = [:]
    private let lock = NSLock()
    let capacity: Int
    init(capacity: Int) { self.capacity = capacity }
    func get(_ url: URL, _ scale: RenderScale) -> DecodeEntry? {
        lock.lock(); defer { lock.unlock() }
        let k = Key(url: url, scale: scale)
        guard let e = store[k] else { return nil }
        order.removeAll { $0 == k }; order.append(k)
        return e
    }
    func put(_ url: URL, _ scale: RenderScale, _ e: DecodeEntry) {
        lock.lock(); defer { lock.unlock() }
        let k = Key(url: url, scale: scale)
        store[k] = e; order.removeAll { $0 == k }; order.append(k)
        while order.count > capacity { let old = order.removeFirst(); store[old] = nil }
    }
}

final class DevelopedCache: @unchecked Sendable {
    struct Key: Equatable { let url: URL; let scale: RenderScale; let develop: DevelopSettings; let geometry: GeometrySettings }
    struct Entry { let key: Key; let frame: DecodedFrame; let analysis: FrameAnalysis }
    private var entries: [Entry] = []
    private let lock = NSLock()
    /// LRU over a byte budget PER SCALE, so a drag full of small previews cannot evict the
    /// proxies on screen and a few large proxies cannot starve a drag. One entry per scale is
    /// always kept even when it alone exceeds its budget, because evicting the thing you just
    /// computed turns the cache into a guaranteed miss.
    let budgets: [RenderScale: Int]
    private var usedBytes: [RenderScale: Int] = [:]
    init(budgets: [RenderScale: Int]) { self.budgets = budgets }
    /// One pot for every scale, for tests that do not care about the split.
    convenience init(budgetBytes: Int) {
        self.init(budgets: [.preview: budgetBytes, .proxy: budgetBytes, .full: budgetBytes])
    }

    private static func bytes(_ f: DecodedFrame) -> Int { f.pixels.count * MemoryLayout<UInt16>.size }

    /// What the cache is holding, for the bench and the tests.
    var currentBytes: Int { lock.lock(); defer { lock.unlock() }; return usedBytes.values.reduce(0, +) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    func bytes(at scale: RenderScale) -> Int { lock.lock(); defer { lock.unlock() }; return usedBytes[scale] ?? 0 }
    func count(at scale: RenderScale) -> Int { lock.lock(); defer { lock.unlock() }; return entries.filter { $0.key.scale == scale }.count }
    func get(_ k: Key) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let i = entries.firstIndex(where: { $0.key == k }) else { return nil }
        let e = entries.remove(at: i); entries.append(e)
        return e
    }
    func put(_ k: Key, frame: DecodedFrame, analysis: FrameAnalysis) {
        lock.lock(); defer { lock.unlock() }
        for e in entries where e.key == k { usedBytes[e.key.scale, default: 0] -= Self.bytes(e.frame) }
        entries.removeAll { $0.key == k }
        entries.append(Entry(key: k, frame: frame, analysis: analysis))
        usedBytes[k.scale, default: 0] += Self.bytes(frame)

        let budget = budgets[k.scale] ?? 0
        // Evict only within the scale that just grew. Oldest first, and never the last one.
        while (usedBytes[k.scale] ?? 0) > budget,
              let i = entries.firstIndex(where: { $0.key.scale == k.scale }),
              entries.filter({ $0.key.scale == k.scale }).count > 1 {
            let old = entries.remove(at: i)
            usedBytes[old.key.scale, default: 0] -= Self.bytes(old.frame)
        }
    }
}

// MARK: - geometry helpers

public enum Geometry {
    /// A normalized crop (original orientation, y-down) as a pixel box on a frame of
    /// this size; the same rect maps onto the proxy and the full decode.
    public static func box(_ r: CropRect, width: Int, height: Int) -> DevelopMath.CropBox {
        let x0 = max(0, min(width, Int((r.x * Double(width)).rounded())))
        let y0 = max(0, min(height, Int((r.y * Double(height)).rounded())))
        let x1 = max(x0 + 1, min(width, Int(((r.x + r.w) * Double(width)).rounded())))
        let y1 = max(y0 + 1, min(height, Int(((r.y + r.h) * Double(height)).rounded())))
        return DevelopMath.CropBox(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    /// Flip then rotate clockwise, the develop order.
    public static func orient(_ f: DecodedFrame, flip: Bool, rotate: Int) -> DecodedFrame {
        if !flip && rotate == 0 { return f }
        let cw = f.width, ch = f.height
        let outW = (rotate == 90 || rotate == 270) ? ch : cw
        let outH = (rotate == 90 || rotate == 270) ? cw : ch
        var out = [UInt16](repeating: 0, count: cw * ch * 3)
        f.pixels.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { op in
                for y in 0..<ch {
                    for x in 0..<cw {
                        let s = (y * cw + x) * 3
                        let d = DevelopTables.dstIndex(x, y, cw: cw, ch: ch, flip: flip, rotate: rotate) * 3
                        op[d] = p[s]; op[d + 1] = p[s + 1]; op[d + 2] = p[s + 2]
                    }
                }
            }
        }
        return DecodedFrame(width: outW, height: outH, pixels: out)
    }

    /// 2x2 box average: the preview scale, which is the proxy halved again.
    public static func halve(_ f: DecodedFrame) -> DecodedFrame {
        let w = f.width / 2, h = f.height / 2
        var out = [UInt16](repeating: 0, count: w * h * 3)
        f.pixels.withUnsafeBufferPointer { p in
            for y in 0..<h {
                for x in 0..<w {
                    for c in 0..<3 {
                        let a = ((2 * y) * f.width + 2 * x) * 3 + c
                        let b = a + 3
                        let cc = a + f.width * 3
                        let d = cc + 3
                        var sum = Int(p[a]) + Int(p[b])
                        sum += Int(p[cc]) + Int(p[d])
                        out[(y * w + x) * 3 + c] = UInt16((sum + 2) / 4)
                    }
                }
            }
        }
        return DecodedFrame(width: w, height: h, pixels: out)
    }
}
