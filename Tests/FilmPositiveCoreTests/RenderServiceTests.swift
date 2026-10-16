import XCTest
import FilmSidecar
@testable import FilmPositiveCore

/// The RenderService contract on the real engine. Scales, caching, the stock
/// resolution rules and the refusals, all stated as properties of the service itself.
final class RenderServiceTests: XCTestCase {
    let fixtures = FixtureFrames()

    func request(_ f: FixtureFrames.Frame, scale: RenderScale, autoTone: Bool = true) -> RenderRequest {
        let develop = DevelopSettings(stock: f.stock,
                                      autoTone: autoTone, base: BaseSettings(mode: .anchor))
        return RenderRequest(imageURL: f.cr2, develop: develop, geometry: GeometrySettings(rotate: 0, flip: true), scale: scale)
    }

    func testCPUServiceProxyIsHalfSizeAndCached() async throws {
        let svc = CPURenderService(profiles: try ProfileLibrary.bundled())
        let f = try FixtureFrames.first()
        let t0 = Date()
        let a = try await svc.render(request(f, scale: .proxy))
        let t1 = Date()
        let b = try await svc.render(request(f, scale: .proxy))
        let t2 = Date()
        XCTAssertEqual(a.frame.pixels, b.frame.pixels)
        let full = try fixtures.decoded(f)
        XCTAssertEqual(a.frame.width, full.width / 2, accuracy: 1)
        print(String(format: "proxy render: first %.2f s (decode), second %.3f s (cached)", t1.timeIntervalSince(t0), t2.timeIntervalSince(t1)))
        XCTAssertLessThan(t2.timeIntervalSince(t1), t1.timeIntervalSince(t0))
    }

    // The drag preview is the proxy's developed frame halved, through the same chain
    func testPreviewScaleIsTheHalvedProxy() async throws {
        let svc = CPURenderService(profiles: try ProfileLibrary.bundled(), enhance: IdentityEnhance())
        let f = try FixtureFrames.first()
        let proxy = try await svc.render(request(f, scale: .proxy))
        let preview = try await svc.render(request(f, scale: .preview))
        XCTAssertEqual(preview.frame.width, proxy.frame.width / 2)
        XCTAssertEqual(preview.frame.height, proxy.frame.height / 2)
        XCTAssertEqual(preview.frame.pixels, Geometry.halve(proxy.frame).pixels)
        XCTAssertNotNil(preview.analysis)
        // an enhance edit on the preview re-uses the cached halved frame: same pixels, no decode
        let t0 = Date()
        let again = try await svc.render(request(f, scale: .preview))
        XCTAssertEqual(again.frame.pixels, preview.frame.pixels)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)
    }

    // A Tether sidecar carries a film name and no develop block. The first develop resolves
    // the stock through the aliases, generic only when nothing matches
    func testStockResolvesFromTetherFilmName() throws {
        let lib = try ProfileLibrary.bundled()
        XCTAssertEqual(lib.stockID(forFilmName: "Kodak Gold 200", maker: "Kodak"), "kodak-gold-200")
        XCTAssertEqual(lib.stockID(forFilmName: "Gold 200", maker: "Kodak"), "kodak-gold-200")
        XCTAssertEqual(lib.stockID(forFilmName: "Kodak UltraMax 400"), "kodak-ultramax-400")
        // Fujifilm 400 is not an UltraMax rebadge. Fujifilm publishes its own bulletin for
        // it (AF3-0262E) and the mask differs from both Superia and UltraMax, so it is its
        // own stock.
        XCTAssertEqual(lib.stockID(forFilmName: "Fujifilm 400", maker: "Fujifilm"), "fujifilm-400")
        XCTAssertEqual(lib.stockID(forFilmName: "Ilford HP5 Plus", maker: "Ilford"), "bw-generic")
        XCTAssertNil(lib.stockID(forFilmName: "Mystery Roll 9000"))
        XCTAssertNil(lib.stockID(forFilmName: nil))
        // A real Tether fixture: Portra 400 has a profile digitized from Kodak's
        // own sheet, so the sidecar records the id that has a file rather than the Eastman
        // name that only resolves through a second hop
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("film-sidecar/Tests/Fixtures/tether-040-crop.xmp")
        guard let data = try? Data(contentsOf: fixture) else { throw XCTSkip("no Tether fixture at \(fixture.path)") }
        let packet = try XMPSidecarCodec.parse(data)
        let sc = try XMPSidecarCodec.decode(packet.fields, liveSource: SidecarSource(name: "IMG_0001.CR2", size: 1, mtime: Date(), fingerprint: "sha256:00"), strict: false)
        XCTAssertNil(sc.develop)
        XCTAssertEqual(sc.capture?.film, "Kodak Portra 400")
        let dev = lib.initialDevelop(capture: sc.capture)
        XCTAssertEqual(dev.stock, "generic", "a film name must not pick the stock on open")
        let named = try XCTUnwrap(lib.stockID(forFilmName: sc.capture?.film,
                                              maker: sc.capture?.filmMaker))
        XCTAssertEqual(named, "kodak-portra-400")
        XCTAssertFalse(lib.resolveFilm(named).fellBackToGeneric)
        XCTAssertEqual(lib.resolveFilm(named).profile.name, "Kodak Portra 400")
        // and the Eastman name still reaches the same profile, from either direction
        XCTAssertEqual(lib.resolveFilm("ektacolor-pro-400").profile.id, "kodak-portra-400")
        XCTAssertEqual(lib.initialDevelop(capture: nil).stock, "generic")
        XCTAssertEqual(lib.initialDevelop(capture: CaptureInfo(film: "Mystery Roll 9000")).stock, "generic")
        XCTAssertFalse(lib.resolveFilm("generic").profile.isMono)
    }

    func testStraightenAppliesAndBadRotationIsRefused() async throws {
        let svc = CPURenderService(profiles: try ProfileLibrary.bundled())
        let f = try FixtureFrames.first()
        var req = request(f, scale: .proxy)
        let plain = try await svc.render(req)
        req.geometry.straightenDegrees = 0.5
        let turned = try await svc.render(req)
        XCTAssertEqual(turned.frame.width, plain.frame.width); XCTAssertEqual(turned.frame.height, plain.frame.height)
        // the top-left corner is blown rebate (65535 everywhere) so a slice there cannot
        // tell the two apart; count differing samples over the whole frame instead
        let moved = FrameDiff.compare(turned.frame, plain.frame)
        XCTAssertGreaterThan(Double(moved.differing) / Double(max(moved.total, 1)), 0.5, "half a degree moves most pixels: \(moved)")
        req.geometry.straightenDegrees = 0; req.geometry.rotate = 45
        do { _ = try await svc.render(req); XCTFail() } catch RenderError.badRotation { } catch { XCTFail("\(error)") }
    }
}
