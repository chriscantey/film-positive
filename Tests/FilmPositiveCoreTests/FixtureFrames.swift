import XCTest
import FilmSidecar
@testable import FilmPositiveCore

/// The raw fixture frames on the test host, as INPUTS.
///
/// `$FP_FIXTURES` (default `fp-fixtures` in the home folder) holds six CR2 files off a copy rig, two
/// sessions of three. They are here so the suites that need a real 18 MP frame have
/// one: a photograph has grain, a rebate, clipped highlights and a color cast, and none
/// of those survive being replaced by a synthetic gradient.
///
/// What they are NOT is a reference. Nothing in this file reads a stored render, a fitted
/// coefficient or a captured log, and no test may assert that today's output equals a past
/// one. So a suite using these frames asserts a PROPERTY that two code paths must share
/// (the tables equal the reference kernel), or that one path must satisfy on any frame (a
/// crop at proxy scale names the same film as at full scale), never agreement with a
/// number somebody recorded.
///
/// Every accessor skips rather than fails when the directory is absent, so the whole suite
/// still runs on a machine that has no fixtures.
final class FixtureFrames {

    struct Frame {
        let name: String
        let cr2: URL
        /// The shipped stock this session was shot on. It picks the dye gammas the develop
        /// pass reads, so it is real input rather than decoration, and it is the one thing
        /// here that came off a piece of paper: the 2026-09-11 session is Gold 200, the
        /// 2026-09-10 session is a Vision3 cross-process that renders through the generic
        /// entry because no Vision3 sheet is digitized yet.
        let stock: String
    }

    static var directory: URL {
        if let p = ProcessInfo.processInfo.environment["FP_FIXTURES"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("fp-fixtures")
    }

    /// Every CR2 in the fixture directory, sorted, newest session last.
    static func all() throws -> [Frame] {
        let dir = directory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            throw XCTSkip("no fixtures at \(dir.path)")
        }
        let out = names.filter { $0.lowercased().hasSuffix(".cr2") }.sorted().map {
            Frame(name: $0, cr2: dir.appendingPathComponent($0),
                  stock: $0.hasPrefix("IMG_20260911") ? "kodak-gold-200" : "generic")
        }
        if out.isEmpty { throw XCTSkip("no CR2 files at \(dir.path)") }
        return out
    }

    /// One frame, for the suites that need a photograph rather than a population.
    static func first() throws -> Frame { try all()[0] }

    /// Decoded once per process. An 18 MP decode is about a second and 108 MB, and the
    /// suites below ask for the same frame repeatedly.
    private static var cache: [String: DecodedFrame] = [:]
    private static let cacheLock = NSLock()
    func decoded(_ f: Frame) throws -> DecodedFrame {
        Self.cacheLock.lock()
        if let d = Self.cache[f.name] { Self.cacheLock.unlock(); return d }
        Self.cacheLock.unlock()
        let d = try RawDecoder().decode(f.cr2)
        Self.cacheLock.lock(); Self.cache[f.name] = d; Self.cacheLock.unlock()
        return d
    }

    /// The develop input for a fixture: the shipped profile's dye gammas on a neutral 1:1
    /// base, which is what the app itself uses for a frame with no picked base and the film
    /// edge search off.
    func input(for f: Frame, mono: Bool = false, autoTone: Bool = false) throws -> DevelopInput {
        let resolved = try ProfileLibrary.bundled().resolveFilm(mono ? ProfileLibrary.monoStockID : f.stock)
        return DevelopInput(ratios: BaseResolver.neutral,
                            dyeGamma: mono ? .neutral : resolved.dyeGamma,
                            mono: mono, autoTone: autoTone)
    }

    /// A crop box well inside the frame, so a suite that needs one has a box that is the
    /// same shape on every fixture and never runs off an edge.
    func box(_ d: DecodedFrame) -> DevelopMath.CropBox {
        DevelopMath.CropBox(x0: d.width / 8, y0: d.height / 8,
                            x1: d.width - d.width / 8, y1: d.height - d.height / 8)
    }
}
