import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The render-time film edge base.
///
/// The unexposed film base is sitting in the frame's own sprocket margin,
/// `Calibrator.rebateEstimate` reads it, and the render uses it whenever nothing is picked
/// and Auto color is on. Without it the base is neutral and the frame renders with its
/// full mask.
///
/// These run on synthetic frames through an injected decoder rather than on raws, because
/// the cases that matter (an edge, no edge, a crop that hides the edge) have to be
/// constructed, not found. The estimator itself is graded in `CalibratorTests`, on a frame
/// whose border value the test chose; what is under test here is the PRECEDENCE and the
/// caching.
final class RebateBaseTests: XCTestCase {

    // MARK: synthetic frames

    /// The base pair the rebate frames carry, chosen to sit near a real C-41 mask so the
    /// numbers read like something rather than like 0.5 and 0.5.
    static let baseR = 12000, baseG = 25000, baseB = 18000
    static var wantRG: Double { Double(baseR) / Double(baseG) }   // 0.48
    static var wantBG: Double { Double(baseB) / Double(baseG) }   // 0.72

    static let side = 400

    /// A frame with a readable rebate: the outer 9 percent strips are unexposed base, with
    /// sprocket holes of bare backlight along both of them.
    ///
    /// The holes are not decoration, they are what makes the estimator work at all, twice
    /// over. `rebateEstimate` finds the largest green cluster BELOW 97 percent of the strip's
    /// brightest pixel, so a strip that is uniformly base has its own base above the cap and
    /// yields nothing. And a reading is refused unless both strips show holes at a 35 mm
    /// pitch (`Calibrator.stripsShowSprocketHoles`). They sit every 44 px, a ninth of the
    /// width, 14 px wide, as on a real 35 mm frame.
    static func frameWithRebate(r: Int = baseR, g: Int = baseG, b: Int = baseB) -> DecodedFrame {
        let (baseR, baseG, baseB) = (r, g, b)
        let w = side, h = side
        var px = [UInt16](repeating: 0, count: w * h * 3)
        let yTop = Int(Double(h) * Calibrator.rebateMargin)          // 36
        let yBot = Int((Double(h) * (1 - Calibrator.rebateMargin)).rounded(.up))  // 364
        for y in 0..<h {
            let inStrip = y < yTop || y >= yBot
            for x in 0..<w {
                let i = (y * w + x) * 3
                if inStrip {
                    let ys = y < yTop ? y : y - yBot
                    if x % 44 >= 6 && x % 44 < 20 && ys >= 6 && ys < 30 {
                        // bare backlight through the sprocket run, below the clip guard so
                        // it is the green window rather than the clip guard that drops it
                        px[i] = 60000; px[i + 1] = 60000; px[i + 2] = 60000
                    } else {
                        px[i] = UInt16(baseR); px[i + 1] = UInt16(baseG); px[i + 2] = UInt16(baseB)
                    }
                } else {
                    // picture: a ramp, so the interior cannot be mistaken for a flat base
                    let v = 8000 + (x * 40)
                    px[i] = UInt16(min(65535, v)); px[i + 1] = UInt16(min(65535, v + 900)); px[i + 2] = UInt16(min(65535, v + 300))
                }
            }
        }
        return DecodedFrame(width: w, height: h, pixels: px)
    }

    /// A frame with no rebate at all: the picture runs edge to edge, so the strips carry a
    /// ramp rather than a cluster. The ramp spreads the strip's pixels roughly one sampled
    /// column per histogram bin, and the estimator's five-bin window cannot reach
    /// `minRebatePixels`, so it refuses. That refusal is the behavior under test.
    static func frameWithoutRebate() -> DecodedFrame {
        let w = side, h = side
        var px = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                let g = 20000 + x * 100
                px[i] = UInt16(min(65535, g - 6000)); px[i + 1] = UInt16(min(65535, g)); px[i + 2] = UInt16(min(65535, g - 3000))
            }
        }
        return DecodedFrame(width: w, height: h, pixels: px)
    }

    // MARK: harness

    private func service(_ frame: DecodedFrame) throws -> CPURenderService {
        let profiles = try ProfileLibrary.bundled()
        return CPURenderService(profiles: profiles, enhance: IdentityEnhance(),
                                decode: { _, _ in frame })
    }

    private static let url = URL(fileURLWithPath: "/dev/null/synthetic.CR2")

    private func develop(stock: String = ProfileLibrary.genericStockID,
                         base: BaseSettings = BaseSettings(mode: .anchor)) -> DevelopSettings {
        DevelopSettings(stock: stock, autoTone: false, base: base)
    }

    private func render(_ svc: CPURenderService, _ develop: DevelopSettings,
                        geometry: GeometrySettings = GeometrySettings()) async throws -> FrameAnalysis {
        let result = try await svc.render(RenderRequest(imageURL: Self.url, develop: develop,
                                                        geometry: geometry, enhance: .identity, scale: .full))
        return try XCTUnwrap(result.analysis)
    }

    /// `analysis.base` is `[anchor * rg, anchor, anchor * bg]`, so the pair the kernel
    /// actually normalized with is read back off it rather than off the source enum.
    private func pair(_ a: FrameAnalysis) -> (rg: Double, bg: Double) {
        (a.base[0] / a.base[1], a.base[2] / a.base[1])
    }

    // MARK: (a) an edge is found and used

    func testAReadableEdgeSuppliesTheBase() async throws {
        let frame = Self.frameWithRebate()
        let estimate = try XCTUnwrap(Calibrator.rebateEstimate(frame), "the fixture must have a readable rebate")
        XCTAssertEqual(estimate[0], Double(Self.baseR), accuracy: 1)
        XCTAssertEqual(estimate[1], Double(Self.baseG), accuracy: 1)
        XCTAssertEqual(estimate[2], Double(Self.baseB), accuracy: 1)

        let svc = try service(frame)
        let an = try await render(svc, develop())

        switch an.baseSource {
        case .edge(let r):
            XCTAssertEqual(r.rg, Self.wantRG, accuracy: 1e-4)
            XCTAssertEqual(r.bg, Self.wantBG, accuracy: 1e-4)
        default:
            XCTFail("expected the edge source, got \(String(describing: an.baseSource))")
        }
        let got = pair(an)
        XCTAssertEqual(got.rg, Self.wantRG, accuracy: 1e-4, "the develop input must carry the measured pair")
        XCTAssertEqual(got.bg, Self.wantBG, accuracy: 1e-4)
        XCTAssertEqual(svc.rebateEstimateRuns, 1)
    }

    // MARK: (b) a crop that hides the edge does not hide it from the estimator

    func testACropThatExcludesTheEdgeStillGetsTheRebatePair() async throws {
        let svc = try service(Self.frameWithRebate())
        // Well inside the 9 percent margins, so not one rebate pixel survives the crop.
        let geometry = GeometrySettings(crop: CropRect(x: 0.2, y: 0.2, w: 0.6, h: 0.6))
        let an = try await render(svc, develop(), geometry: geometry)

        guard case .edge = an.baseSource else {
            return XCTFail("expected the edge source, got \(String(describing: an.baseSource))")
        }
        let got = pair(an)
        XCTAssertEqual(got.rg, Self.wantRG, accuracy: 1e-4, "measured on the uncropped decode")
        XCTAssertEqual(got.bg, Self.wantBG, accuracy: 1e-4)
    }

    // MARK: (c) no edge is a refusal, not a guess

    /// A frame with no edge is estimated off the picture, so "not found" needs
    /// a frame the estimate refuses too: lamp in view along the right edge, which puts the
    /// tail of every channel at the clip guard.
    func testNoEdgeAndNoEstimateIsNotFoundAndNeutral() async throws {
        var px = Self.frameWithoutRebate().pixels
        for y in 0..<Self.side { for x in (Self.side - 20)..<Self.side {
            let i = (y * Self.side + x) * 3
            px[i] = 65535; px[i + 1] = 65535; px[i + 2] = 65535
        } }
        let frame = DecodedFrame(width: Self.side, height: Self.side, pixels: px)
        XCTAssertNil(Calibrator.rebateEstimate(frame), "the fixture must have no readable rebate")
        XCTAssertNil(Calibrator.pictureEstimate(frame), "nor a picture estimate")

        let svc = try service(frame)
        let an = try await render(svc, develop())

        XCTAssertEqual(an.baseSource, .notFound)
        XCTAssertEqual(an.baseSource?.status, "Could not find the film border. Pick a spot on the film.")
        let got = pair(an)
        XCTAssertEqual(got.rg, 1, accuracy: 1e-9)
        XCTAssertEqual(got.bg, 1, accuracy: 1e-9)
        XCTAssertEqual(svc.rebateEstimateRuns, 1, "it looked once and found nothing")
    }

    // MARK: (d) a measurement the user made wins

    func testAPickedBaseBeatsTheEdge() async throws {
        let svc = try service(Self.frameWithRebate())
        let own = BaseRatios(rg: 0.3, bg: 0.9)
        let an = try await render(svc, develop(base: BaseSettings(mode: .measured, ratios: own)))

        XCTAssertEqual(an.baseSource, .picked)
        let got = pair(an)
        XCTAssertEqual(got.rg, own.rg, accuracy: 1e-9)
        XCTAssertEqual(got.bg, own.bg, accuracy: 1e-9)
        XCTAssertEqual(svc.rebateEstimateRuns, 0, "a sidecar pair must not pay for an estimate")
    }

    // MARK: (e) monochrome has no base pair to measure

    func testAMonoStockNeverRunsTheEstimator() async throws {
        let svc = try service(Self.frameWithRebate())
        let an = try await render(svc, develop(stock: ProfileLibrary.monoStockID))

        XCTAssertEqual(an.baseSource, .blackAndWhite, "black and white has no base pair, and the line says so")
        XCTAssertEqual(an.base[0], an.base[1], accuracy: 1e-9)
        XCTAssertEqual(an.base[2], an.base[1], accuracy: 1e-9)
        XCTAssertEqual(svc.rebateEstimateRuns, 0)
    }

    // MARK: (f) once per frame, not once per render

    func testTheEstimateRunsOncePerFrame() async throws {
        let svc = try service(Self.frameWithRebate())
        // Two DIFFERENT develop stages of the same frame: the same settings twice would be
        // answered by the developed cache and would prove nothing about the estimator.
        let first = try await render(svc, develop())
        let second = try await render(svc, develop(), geometry: GeometrySettings(rotate: 90))

        XCTAssertEqual(svc.rebateEstimateRuns, 1, "the memo lives on the decode cache entry")
        XCTAssertEqual(pair(first).rg, pair(second).rg, accuracy: 1e-9)
        XCTAssertEqual(pair(second).rg, Self.wantRG, accuracy: 1e-4)
    }

    // MARK: the pair does not change between the preview and the export

    /// The proxy and the full decode genuinely disagree about the film edge on a real scan
    /// (measured: R/G 0.4743 off the proxy, 0.4671 off the full decode
    /// of the same UltraMax frame), so a per-scale measurement would show one base on
    /// screen and bake another into the export.
    ///
    /// The fixture makes the disagreement enormous and unmistakable rather than 1.5
    /// percent: the two scales carry different base pairs, and a `.full` render must come
    /// out with the PROXY's pair. A test where both scales decode the same frame would
    /// pass whatever the code did.
    func testEveryScaleMeasuresTheSameEdge() async throws {
        let proxyFrame = Self.frameWithRebate()
        let fullFrame = Self.frameWithRebate(r: 20000, g: 25000, b: 10000)   // rg 0.8, bg 0.4
        let profiles = try ProfileLibrary.bundled()
        let svc = CPURenderService(profiles: profiles, enhance: IdentityEnhance(),
                                   decode: { _, half in half ? proxyFrame : fullFrame })

        for scale in [RenderScale.proxy, .full] {
            let result = try await svc.render(RenderRequest(imageURL: Self.url, develop: develop(),
                                                            geometry: GeometrySettings(), enhance: .identity, scale: scale))
            let an = try XCTUnwrap(result.analysis)
            XCTAssertEqual(pair(an).rg, Self.wantRG, accuracy: 1e-4, "\(scale) must use the proxy's edge")
            XCTAssertEqual(pair(an).bg, Self.wantBG, accuracy: 1e-4, "\(scale) must use the proxy's edge")
        }
        XCTAssertEqual(svc.rebateEstimateRuns, 1, "once per frame, not once per frame and scale")
    }

    // MARK: the resolver's own precedence, without a render

    /// The three rungs in order, plus black and white beside them, each case asserting
    /// which one answered and whether the edge reader was CALLED. The call count matters as
    /// much as the answer: an implementation that measured and then discarded would pass a
    /// value check and still cost a pass over every frame.
    func testTheThreeRungsInOrder() throws {
        let profiles = try ProfileLibrary.bundled()
        let edge: [Double] = [Double(Self.baseR), Double(Self.baseG), Double(Self.baseB)]
        let picked = BaseRatios(rg: 0.3, bg: 0.9)
        struct Case { let name: String; let stock: String; let on: Bool; let picked: BaseRatios?
                      let edge: [Double]?; let want: BaseSource; let measures: Bool }
        let cases = [
            Case(name: "rung 1: a picked base wins over a readable edge", stock: Self.namedStock,
                 on: true, picked: picked, edge: edge, want: .picked, measures: false),
            Case(name: "rung 1 also wins with the edge switch off", stock: Self.namedStock,
                 on: false, picked: picked, edge: edge, want: .picked, measures: false),
            Case(name: "rung 2: the film edge", stock: Self.namedStock,
                 on: true, picked: nil, edge: edge, want: .edge(BaseRatios(rg: Self.wantRG, bg: Self.wantBG)),
                 measures: true),
            Case(name: "rung 3: no edge found", stock: Self.namedStock,
                 on: true, picked: nil, edge: nil, want: .notFound, measures: true),
            Case(name: "rung 3: the edge switch off and nothing picked", stock: Self.namedStock,
                 on: false, picked: nil, edge: edge, want: .off, measures: false),
            Case(name: "black and white, before any rung", stock: ProfileLibrary.monoStockID,
                 on: true, picked: picked, edge: edge, want: .blackAndWhite, measures: false),
        ]
        for c in cases {
            var develop = develop(stock: c.stock, base: c.picked.map { BaseSettings(mode: .measured, ratios: $0) }
                                  ?? BaseSettings(mode: .anchor))
            develop.autoBalance = c.on
            var measured = false
            let r = BaseResolver.resolve(develop: develop, profiles: profiles,
                                         measureRebate: { measured = true; return c.edge })
            XCTAssertEqual(r.source, c.want, c.name)
            XCTAssertEqual(measured, c.measures, "\(c.name): edge reader called")
            switch c.want {
            case .picked: XCTAssertEqual(r.ratios, picked, c.name)
            case .edge(let p): XCTAssertEqual(r.ratios, p, c.name)
            default: XCTAssertEqual(r.ratios, BaseResolver.neutral, c.name)
            }
        }
    }

    /// `base.mode` IS read. A sidecar that says measured but carries no pair is not a
    /// picked base, so the edge is read. An anchor-mode sidecar that carries a pair keeps the
    /// pair for a later Picked and does not use it: `autoBalance` decides, edge when on and
    /// neutral when off. That is what lets the Base control go Picked, Auto, Picked without a
    /// second pick.
    func testTheBaseModeDecidesWhetherAStoredPairIsUsed() throws {
        let profiles = try ProfileLibrary.bundled()
        let edge: [Double] = [Double(Self.baseR), Double(Self.baseG), Double(Self.baseB)]
        let noPair = BaseResolver.resolve(develop: develop(stock: Self.namedStock, base: BaseSettings(mode: .measured)),
                                          profiles: profiles, measureRebate: { edge })
        XCTAssertEqual(noPair.source, .edge(BaseRatios(rg: Self.wantRG, bg: Self.wantBG)))

        let pair = BaseRatios(rg: 0.3, bg: 0.9)
        var kept = develop(stock: Self.namedStock, base: BaseSettings(mode: .anchor, ratios: pair))
        let auto = BaseResolver.resolve(develop: kept, profiles: profiles, measureRebate: { edge })
        XCTAssertEqual(auto.source, .edge(BaseRatios(rg: Self.wantRG, bg: Self.wantBG)),
                       "a kept pair under Auto is not used")
        kept.autoBalance = false
        var measured = false
        let none = BaseResolver.resolve(develop: kept, profiles: profiles,
                                        measureRebate: { measured = true; return edge })
        XCTAssertEqual(none.source, .off, "a kept pair under None is not used")
        XCTAssertEqual(none.ratios, BaseResolver.neutral)
        XCTAssertFalse(measured, "None reads no edge")

        kept.base.mode = .measured
        let picked = BaseResolver.resolve(develop: kept, profiles: profiles, measureRebate: { edge })
        XCTAssertEqual(picked.source, .picked)
        XCTAssertEqual(picked.ratios, pair)
    }

    /// The whole render with the edge switch off: nothing measured, neutral, and the line
    /// asks for a pick.
    func testTheEdgeSwitchOffSurvivesARenderOfAFrameWithAnEdge() async throws {
        let svc = try service(Self.frameWithRebate())
        var develop = develop(stock: Self.namedStock)
        develop.autoBalance = false
        let an = try await render(svc, develop)
        XCTAssertEqual(an.baseSource, .off)
        XCTAssertEqual(an.baseSource?.status, "No film color in use.")
        XCTAssertEqual(pair(an).rg, 1, accuracy: 1e-9)
        XCTAssertEqual(svc.rebateEstimateRuns, 0)
    }

    private static let namedStock = "kodak-gold-200"

    func testRatiosFromRebateRejectsWhatCannotDivide() {
        XCTAssertNil(BaseResolver.ratios(fromRebate: [1000, 0, 500]))
        XCTAssertNil(BaseResolver.ratios(fromRebate: [1000, 2000]))
        XCTAssertNil(BaseResolver.ratios(fromRebate: [.nan, 2000, 500]))
        let ok = try? XCTUnwrap(BaseResolver.ratios(fromRebate: [1200, 2500, 1800]))
        XCTAssertEqual(ok?.rg ?? 0, 0.48, accuracy: 1e-9)
    }

    /// Every source has its own plain words.
    func testEveryBaseSourceHasItsOwnWords() {
        let sources: [BaseSource] = [.picked, .edge(BaseRatios(rg: 0.5, bg: 0.8)), .estimated(BaseRatios(rg: 0.5, bg: 0.8)),
                                     .notFound, .off, .blackAndWhite]
        XCTAssertEqual(Set(sources.map(\.status)).count, sources.count)
        XCTAssertEqual(BaseSource.edge(BaseRatios(rg: 0.5, bg: 0.8)).status, "Color from the film border")
        XCTAssertEqual(BaseSource.picked.status, "Color from your pick")
        XCTAssertEqual(BaseSource.notFound.status, "Could not find the film border. Pick a spot on the film.")
        XCTAssertEqual(BaseSource.off.status, "No film color in use.")
        XCTAssertEqual(BaseSource.blackAndWhite.status, "Black and white film")
    }

    // MARK: a strip of picture is not a film edge

    /// The crop ladder's failure, synthesised: a frame cropped past its rebate, whose outer
    /// strips are a flat patch of thin picture. The strip rule reads it happily, because it
    /// looks exactly like base, and the reading is refused because the strips carry no
    /// sprocket holes. The render then says "not found" and develops 1:1.
    func testAStripOfPictureIsRefusedAndTheRenderSaysNotFound() async throws {
        let w = Self.side, h = Self.side
        var px = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                // A flat thin area along both edges, and a brighter patch of picture on the
                // left of each strip, so the strip rule has a cap above the cluster and reads.
                let bright = x < 60
                let v: (UInt16, UInt16, UInt16) = bright ? (50000, 60000, 52000) : (14000, 25000, 17000)
                px[i] = v.0; px[i + 1] = v.1; px[i + 2] = v.2
            }
        }
        let frame = DecodedFrame(width: w, height: h, pixels: px)
        let strip = Calibrator.stripReading(frame)
        XCTAssertNotNil(strip.estimate, "the fixture must fool the strip rule, or this tests nothing")

        let reading = Calibrator.rebateReading(frame)
        XCTAssertNil(reading.estimate)
        XCTAssertEqual(reading.path, .noSprocketHoles)
        XCTAssertNil(Calibrator.rebateEstimate(frame))

        // Refused as an edge, the frame falls to the picture estimate, whose
        // tail here is the bright patch. What matters is that the line no longer says edge.
        let svc = try service(frame)
        let an = try await render(svc, develop(stock: Self.namedStock))
        XCTAssertEqual(an.baseSource, .estimated(BaseRatios(rg: 50000.0 / 60000, bg: 52000.0 / 60000)))
        XCTAssertEqual(an.baseSource?.status, "Color estimated from the picture")
    }

    /// And the same frame WITH holes in its strips is read, so the refusal above is the
    /// holes and not something else about the fixture.
    func testTheSameStripWithSprocketHolesIsRead() throws {
        let frame = Self.frameWithRebate()
        XCTAssertTrue(Calibrator.stripsShowSprocketHoles(frame, baseGreen: Double(Self.baseG)))
        XCTAssertNotNil(Calibrator.rebateReading(frame).estimate)

        // Holes on one strip only are not enough: a real 35 mm edge has them on both.
        var px = frame.pixels
        let yBot = Int((Double(frame.height) * (1 - Calibrator.rebateMargin)).rounded(.up))
        for y in yBot..<frame.height {
            for x in 0..<frame.width {
                let i = (y * frame.width + x) * 3
                px[i] = UInt16(Self.baseR); px[i + 1] = UInt16(Self.baseG); px[i + 2] = UInt16(Self.baseB)
            }
        }
        let oneSided = DecodedFrame(width: frame.width, height: frame.height, pixels: px)
        XCTAssertFalse(Calibrator.stripsShowSprocketHoles(oneSided, baseGreen: Double(Self.baseG)))
    }

    // MARK: rung 3, the base estimated from the picture (move 7)

    /// The four rungs in order when the edge reader and the picture estimate both have
    /// answers to give, and which closures each case calls. The estimate is only ever asked
    /// after the edge refused, and the switch off asks neither.
    func testTheRungOrderWithThePictureEstimate() throws {
        let profiles = try ProfileLibrary.bundled()
        let edge: [Double] = [12000, 25000, 18000]       // 0.48, 0.72
        let picture: [Double] = [13000, 26000, 19500]    // 0.50, 0.75
        let picked = BaseRatios(rg: 0.3, bg: 0.9)
        struct Case { let name: String; let on: Bool; let picked: BaseRatios?; let edge: [Double]?
                      let picture: [Double]?; let want: BaseSource; let askedEdge: Bool; let askedPicture: Bool }
        let cases = [
            Case(name: "picked beats both", on: true, picked: picked, edge: edge, picture: picture,
                 want: .picked, askedEdge: false, askedPicture: false),
            Case(name: "the edge beats the estimate", on: true, picked: nil, edge: edge, picture: picture,
                 want: .edge(BaseRatios(rg: 0.48, bg: 0.72)), askedEdge: true, askedPicture: false),
            Case(name: "no edge, so the estimate", on: true, picked: nil, edge: nil, picture: picture,
                 want: .estimated(BaseRatios(rg: 0.5, bg: 0.75)), askedEdge: true, askedPicture: true),
            Case(name: "no edge and no estimate is not found", on: true, picked: nil, edge: nil, picture: nil,
                 want: .notFound, askedEdge: true, askedPicture: true),
            Case(name: "switch off asks neither", on: false, picked: nil, edge: edge, picture: picture,
                 want: .off, askedEdge: false, askedPicture: false),
        ]
        for c in cases {
            var develop = develop(stock: Self.namedStock, base: c.picked.map { BaseSettings(mode: .measured, ratios: $0) }
                                  ?? BaseSettings(mode: .anchor))
            develop.autoBalance = c.on
            var askedEdge = false, askedPicture = false
            let r = BaseResolver.resolve(develop: develop, profiles: profiles,
                                         measureRebate: { askedEdge = true; return c.edge },
                                         estimatePicture: { askedPicture = true; return c.picture })
            XCTAssertEqual(r.source, c.want, c.name)
            XCTAssertEqual(askedEdge, c.askedEdge, "\(c.name): edge reader asked")
            XCTAssertEqual(askedPicture, c.askedPicture, "\(c.name): picture estimate asked")
        }
        XCTAssertEqual(BaseSource.estimated(BaseRatios(rg: 0.5, bg: 0.75)).status, "Color estimated from the picture")
    }

    /// The estimate itself on a frame whose answer the test chose: 99.9 percent of the
    /// pixels are a dense picture and the thinnest 0.2 percent are a patch at a known base,
    /// so the 99.9th percentile of every channel lands on that patch exactly.
    func testThePictureEstimateReadsTheThinTailPerChannel() throws {
        let w = 500, h = 400
        var px = [UInt16](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            let thin = i < 400      // 0.2 percent of 200000
            px[i * 3] = thin ? 14000 : 3000; px[i * 3 + 1] = thin ? 28000 : 6000; px[i * 3 + 2] = thin ? 21000 : 4000
        }
        let f = DecodedFrame(width: w, height: h, pixels: px)
        XCTAssertEqual(try XCTUnwrap(Calibrator.pictureEstimate(f)), [14000, 28000, 21000])

        // A box that leaves the thin patch out estimates off what is left.
        let box = DevelopMath.CropBox(x0: 0, y0: 100, x1: w, y1: h)
        XCTAssertEqual(try XCTUnwrap(Calibrator.pictureEstimate(f, box: box)), [3000, 6000, 4000])

        // Lamp in view: the tail is at the clip guard, and that is not film.
        var lit = px
        for i in 0..<2000 { lit[i * 3] = 65535; lit[i * 3 + 1] = 65535; lit[i * 3 + 2] = 65535 }
        XCTAssertNil(Calibrator.pictureEstimate(DecodedFrame(width: w, height: h, pixels: lit)))
    }

    /// Through the render: a frame with no film edge is estimated off the picture and the
    /// line says so, and the crop decides what the picture is.
    func testARenderWithNoEdgeUsesThePictureEstimateOverTheCrop() async throws {
        let frame = Self.frameWithoutRebate()
        let svc = try service(frame)
        let an = try await render(svc, develop(stock: Self.namedStock))
        guard case .estimated(let p) = an.baseSource else {
            return XCTFail("expected the picture estimate, got \(String(describing: an.baseSource))")
        }
        XCTAssertEqual(an.baseSource?.status, "Color estimated from the picture")
        let whole = try XCTUnwrap(Calibrator.pictureEstimate(frame))
        XCTAssertEqual(p.rg, whole[0] / whole[1], accuracy: 1e-12)
        XCTAssertEqual(pair(an).rg, p.rg, accuracy: 1e-9, "the kernel used the estimate")

        // The ramp runs left to right, so a crop on the left half has a darker tail.
        let crop = CropRect(x: 0, y: 0, w: 0.5, h: 1)
        let cropped = try await render(svc, develop(stock: Self.namedStock), geometry: GeometrySettings(crop: crop))
        let want = try XCTUnwrap(Calibrator.pictureEstimate(frame, box: Geometry.box(crop, width: frame.width, height: frame.height)))
        guard case .estimated(let q) = cropped.baseSource else { return XCTFail("expected an estimate") }
        XCTAssertEqual(q.rg, want[0] / want[1], accuracy: 1e-12, "measured over the crop")
        XCTAssertNotEqual(q.rg, p.rg, "a different visible frame, a different estimate")
    }
}
