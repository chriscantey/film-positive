import XCTest
import FilmSidecar
@testable import FilmPositiveCore

/// The develop cache is budgeted in BYTES, not in frames.
///
/// A cache that holds four entries makes a slider drag with more than four frames selected
/// evict and re-develop every one of them on every tick, so the cost per tick grows with the
/// selection. A count cannot be set correctly because a developed frame is 27 MB at proxy
/// scale and under 7 MB at preview scale, a four-fold difference, and a drag is all previews
/// while rest is all proxies.
final class DevelopedCacheTests: XCTestCase {

    private func frame(pixels: Int) -> DecodedFrame {
        // width * height * 3 == pixels * 3
        DecodedFrame(width: pixels, height: 1, pixels: [UInt16](repeating: 0, count: pixels * 3))
    }

    private func key(_ n: Int, scale: RenderScale = .proxy) -> DevelopedCache.Key {
        DevelopedCache.Key(url: URL(fileURLWithPath: "/tmp/IMG_\(n).CR2"),
                           scale: scale,
                           develop: DevelopSettings(stock: "generic", base: BaseSettings(mode: .anchor)),
                           geometry: GeometrySettings())
    }

    private var analysis: FrameAnalysis {
        FrameAnalysis(anchor: 4_000, base: [1, 1, 1], percentile: [], physics: [],
                      coarse: [], sampleCount: 0, tone: nil)
    }

    func testEvictionIsByBytesAndOldestFirst() {
        // Each frame is 600 bytes (100 pixels * 3 channels * 2 bytes). Budget holds three.
        let cache = DevelopedCache(budgetBytes: 1_900)
        for i in 1...3 { cache.put(key(i), frame: frame(pixels: 100), analysis: analysis) }
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache.currentBytes, 1_800)

        cache.put(key(4), frame: frame(pixels: 100), analysis: analysis)
        XCTAssertEqual(cache.count, 3, "the budget is what bounds it")
        XCTAssertNil(cache.get(key(1)), "the oldest went")
        XCTAssertNotNil(cache.get(key(4)))
        XCTAssertNotNil(cache.get(key(3)))
    }

    func testAReadMakesAnEntryTheNewest() {
        let cache = DevelopedCache(budgetBytes: 1_900)
        for i in 1...3 { cache.put(key(i), frame: frame(pixels: 100), analysis: analysis) }
        _ = cache.get(key(1))                       // touch the oldest
        cache.put(key(4), frame: frame(pixels: 100), analysis: analysis)
        XCTAssertNotNil(cache.get(key(1)), "touched, so it is no longer the eviction candidate")
        XCTAssertNil(cache.get(key(2)), "the new oldest went instead")
    }

    func testSmallFramesFitInTheSameBudgetThatHoldsFewLargeOnes() {
        // The whole point: the same budget holds four times as many preview frames as proxy
        // frames, which is why a group drag now fits and a count could never express it.
        let budget = 24_000
        let proxies = DevelopedCache(budgetBytes: budget)
        for i in 1...20 { proxies.put(key(i), frame: frame(pixels: 1_000), analysis: analysis) }   // 6000 bytes each
        XCTAssertEqual(proxies.count, 4)

        let previews = DevelopedCache(budgetBytes: budget)
        for i in 1...20 { previews.put(key(i, scale: .preview), frame: frame(pixels: 250), analysis: analysis) }  // 1500 each
        XCTAssertEqual(previews.count, 16)
    }

    func testOneOversizedEntryIsKeptRatherThanEvictingItself() {
        // Evicting the thing you just computed makes the cache a guaranteed miss, which is
        // worse than being over budget for one frame.
        let cache = DevelopedCache(budgetBytes: 100)
        cache.put(key(1), frame: frame(pixels: 1_000), analysis: analysis)
        XCTAssertEqual(cache.count, 1)
        XCTAssertNotNil(cache.get(key(1)))
        XCTAssertGreaterThan(cache.currentBytes, 100, "kept even though it alone exceeds the budget")

        // And it is released as soon as anything else arrives.
        cache.put(key(2), frame: frame(pixels: 1), analysis: analysis)
        XCTAssertEqual(cache.count, 1)
        XCTAssertNil(cache.get(key(1)))
    }

    /// The split is the point: a drag full of small previews must not evict the proxies on
    /// screen, and a few large proxies must not starve a drag. One shared budget does both,
    /// and it can push the whole suite into swap.
    func testEachScaleEvictsOnlyWithinItself() {
        let cache = DevelopedCache(budgets: [.preview: 4_000, .proxy: 1_300, .full: 1_000])
        // Two proxies fill the proxy pot (600 bytes each, budget 1300).
        cache.put(key(1, scale: .proxy), frame: frame(pixels: 100), analysis: analysis)
        cache.put(key(2, scale: .proxy), frame: frame(pixels: 100), analysis: analysis)
        // Six previews would blow a shared pot and evict both proxies.
        for i in 10..<16 { cache.put(key(i, scale: .preview), frame: frame(pixels: 100), analysis: analysis) }

        XCTAssertNotNil(cache.get(key(1, scale: .proxy)), "a drag must not cost the proxies on screen")
        XCTAssertNotNil(cache.get(key(2, scale: .proxy)))
        XCTAssertEqual(cache.count(at: .preview), 6, "and the previews all fit in their own pot")

        // A third proxy evicts a proxy, not a preview.
        cache.put(key(3, scale: .proxy), frame: frame(pixels: 100), analysis: analysis)
        XCTAssertEqual(cache.count(at: .proxy), 2)
        XCTAssertEqual(cache.count(at: .preview), 6, "untouched by pressure in another scale")
        XCTAssertNil(cache.get(key(1, scale: .proxy)), "oldest proxy went")
    }

    func testRewritingAKeyDoesNotLeakItsBytes() {
        let cache = DevelopedCache(budgetBytes: 1_000_000)
        cache.put(key(1), frame: frame(pixels: 100), analysis: analysis)
        cache.put(key(1), frame: frame(pixels: 100), analysis: analysis)
        cache.put(key(1), frame: frame(pixels: 100), analysis: analysis)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.currentBytes, 600, "one entry's worth, not three")
    }
}
