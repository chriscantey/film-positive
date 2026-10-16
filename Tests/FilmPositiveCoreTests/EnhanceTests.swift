import XCTest
import FilmSidecar
@testable import FilmPositiveCore

/// Every slider checked for DIRECTION on a synthetic patch frame chosen so the expected
/// effect is unambiguous, because an inverted warmth sign shows only on a measured grey.
/// Plus the shipped looks, the look file round trip, and the state model's reset rules.
final class EnhanceTests: XCTestCase {
    static let patches: [(name: String, rgb: (Int, Int, Int))] = [
        ("black", (8, 8, 8)), ("shadow", (48, 48, 48)), ("midgrey", (128, 128, 128)), ("highlight", (208, 208, 208)),
        ("white", (247, 247, 247)), ("muted", (150, 120, 110)),
        // saturated but with headroom, so a saturation push cannot clip and cap the ratio
        ("saturated", (180, 90, 90)),
    ]
    static let patchW = 40, patchH = 40
    static var W: Int { patchW * patches.count }
    static var H: Int { patchH }

    static let base: DecodedFrame = {
        var px = [UInt16](repeating: 0, count: W * H * 3)
        for (i, p) in patches.enumerated() {
            for y in 0..<H { for x in (i * patchW)..<((i + 1) * patchW) {
                let o = (y * W + x) * 3
                px[o] = UInt16(p.rgb.0 * 257); px[o + 1] = UInt16(p.rgb.1 * 257); px[o + 2] = UInt16(p.rgb.2 * 257)
            } }
        }
        return DecodedFrame(width: W, height: H, pixels: px)
    }()

    let stage = CoreImageEnhance()

    /// Patch centers, in 8-bit units.
    func read(_ f: DecodedFrame) -> [(Int, Int, Int)] {
        Self.patches.indices.map { i in
            let x = i * Self.patchW + Self.patchW / 2, y = f.height / 2
            let o = (y * f.width + x) * 3
            return (Int(f.pixels[o]) / 257, Int(f.pixels[o + 1]) / 257, Int(f.pixels[o + 2]) / 257)
        }
    }
    func patch(_ n: String, _ v: [(Int, Int, Int)]) -> (Int, Int, Int) { v[Self.patches.firstIndex { $0.name == n }!] }
    func luma(_ c: (Int, Int, Int)) -> Double { 0.299 * Double(c.0) + 0.587 * Double(c.1) + 0.114 * Double(c.2) }
    func chroma(_ c: (Int, Int, Int)) -> Int { max(c.0, max(c.1, c.2)) - min(c.0, min(c.1, c.2)) }
    func look(_ f: (inout EnhanceSettings) -> Void) throws -> [(Int, Int, Int)] {
        var p = EnhanceSettings.identity; f(&p)
        return read(try stage.apply(Self.base, settings: p))
    }
    var baseVals: [(Int, Int, Int)] { read(Self.base) }

    func testIdentityIsATrueNoOp() throws {
        let out = try stage.apply(Self.base, settings: .identity)
        XCTAssertEqual(out.pixels, Self.base.pixels)
    }

    func testEverySliderDirection() throws {
        let b = baseVals
        let warm = try look { $0.warmth = 1.0 }
        let baseRB = patch("midgrey", b).0 - patch("midgrey", b).2
        XCTAssertGreaterThan(patch("midgrey", warm).0 - patch("midgrey", warm).2, baseRB + 5, "warmth + is warmer")
        let cool = try look { $0.warmth = -1.0 }
        XCTAssertLessThan(patch("midgrey", cool).0 - patch("midgrey", cool).2, baseRB - 5, "warmth - is cooler")

        let sat = try look { $0.saturation = 0.6 }
        XCTAssertGreaterThan(chroma(patch("muted", sat)), chroma(patch("muted", b)), "saturation + raises chroma")
        let desat = try look { $0.saturation = -1.0 }
        XCTAssertLessThanOrEqual(chroma(patch("saturated", desat)), 2, "saturation -1 is greyscale")

        // vibrance favors muted color, measured as a RATIO; saturation is the control
        let vib = try look { $0.vibrance = 0.8 }
        let rMuted = Double(chroma(patch("muted", vib))) / Double(chroma(patch("muted", b)))
        let rSat = Double(chroma(patch("saturated", vib))) / Double(chroma(patch("saturated", b)))
        XCTAssertGreaterThan(rMuted, rSat, "vibrance favours muted over saturated")
        let satCtl = try look { $0.saturation = 0.8 }
        let cMuted = Double(chroma(patch("muted", satCtl))) / Double(chroma(patch("muted", b)))
        let cSat = Double(chroma(patch("saturated", satCtl))) / Double(chroma(patch("saturated", b)))
        XCTAssertLessThan(abs(cMuted - cSat), abs(rMuted - rSat), "saturation discriminates less than vibrance")

        let shad = try look { $0.shadows = 0.8 }
        XCTAssertGreaterThan(luma(patch("shadow", shad)), luma(patch("shadow", b)) + 2, "shadows + lifts the shadow patch")
        XCTAssertLessThan(abs(luma(patch("white", shad)) - luma(patch("white", b))), 12, "shadows + leaves white alone")

        let high = try look { $0.highlights = -0.9 }
        XCTAssertLessThan(luma(patch("highlight", high)), luma(patch("highlight", b)) - 2, "highlights - pulls the highlight patch down")

        let expUp = try look { $0.exposure = 0.5 }
        XCTAssertGreaterThan(luma(patch("midgrey", expUp)), luma(patch("midgrey", b)) + 5, "exposure + brightens")

        let con = try look { $0.contrast = 0.8 }
        XCTAssertLessThan(luma(patch("shadow", con)), luma(patch("shadow", b)), "contrast + lowers shadows")
        XCTAssertGreaterThan(luma(patch("highlight", con)), luma(patch("highlight", b)), "contrast + raises highlights")

        let bp = try look { $0.blackPoint = 0.8 }
        XCTAssertLessThanOrEqual(luma(patch("black", bp)), luma(patch("black", b)), "black point + crushes blacks")
        let bpN = try look { $0.blackPoint = -0.8 }
        XCTAssertGreaterThan(luma(patch("black", bpN)), luma(patch("black", b)) + 2, "black point - lifts blacks")

        let rad = try look { $0.radiance = 1.0 }
        XCTAssertGreaterThan(luma(patch("shadow", rad)), luma(patch("shadow", b)) + 2, "radiance opens shadows")
        // The white patch, not the 208 highlight patch: the guided filter tone map restores
        // slope about a pivot, so it raises the upper midtones and pulls in only the top of
        // the range.
        XCTAssertLessThan(luma(patch("white", rad)), luma(patch("white", b)) - 1, "radiance pulls the whites in")

        let tint = try look { $0.tint = 1.0 }
        XCTAssertGreaterThan(abs(patch("midgrey", tint).1 - patch("midgrey", b).1), 2, "tint moves the green/magenta axis")

        let vig = try stage.apply(Self.base, settings: { var p = EnhanceSettings.identity; p.vignette = -1.0; return p }())
        XCTAssertLessThanOrEqual(luma(read(vig)[0]), luma(patch("black", b)) + 2, "vignette - darkens corners")
    }

    func testBlurBackedFiltersKeepTheSize() throws {
        for (n, s) in [("definition", { var q = EnhanceSettings.identity; q.definition = 1.0; return q }()),
                       ("sharpness", { var q = EnhanceSettings.identity; q.sharpness = 1.0; return q }()),
                       ("noiseReduction", { var q = EnhanceSettings.identity; q.noiseReduction = 1.0; return q }()),
                       ("radiance", { var q = EnhanceSettings.identity; q.radiance = 1.0; return q }())] {
            let out = try stage.apply(Self.base, settings: s)
            XCTAssertEqual(out.width, Self.W, n); XCTAssertEqual(out.height, Self.H, n)
        }
    }

    func testShippedLooksRenderAndOnlyTheBlackAndWhiteOnesAreMonochrome() throws {
        XCTAssertEqual(ShippedLooks.all.map(\.name), ["Pop", "Sunroom", "Matinee", "Arcade", "Canvas", "Morning", "Overcast", "Chalk", "Ink", "Cloud"])
        let b = baseVals
        for lk in ShippedLooks.all {
            let v = read(try stage.apply(Self.base, settings: lk.settings))
            let moved = zip(v, b).contains { abs(luma($0) - luma($1)) > 1 || chroma($0) != chroma($1) }
            XCTAssertTrue(moved, "\(lk.name) changes the frame")
            let mono = chroma(patch("saturated", v)) <= 2
            // Asserted against the declared set rather than against one id, so adding a
            // third black and white look is a one line change here and not a puzzle.
            XCTAssertEqual(mono, ShippedLooks.blackAndWhiteLookIDs.contains(lk.id), "\(lk.name) monochrome=\(mono)")
            if ShippedLooks.lightLookIDs.contains(lk.id) {
                for (k, val) in zip(EnhanceSettings.sliderKeys, lk.settings.values) { XCTAssertLessThanOrEqual(abs(val), 0.15, "\(lk.name) \(k)") }
            }
        }
    }

    func testLookFileRoundTrip() throws {
        let data = try LookFile.encode(ShippedLooks.all)
        let back = try LookFile.decode(data)
        XCTAssertEqual(back, ShippedLooks.all)
        XCTAssertFalse(String(decoding: try LookFile.encode([Look(id: "x", name: "x", blurb: "", settings: .identity)]), as: UTF8.self).contains("radiance"), "identity encodes empty")
        var newer = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        newer["version"] = 99
        XCTAssertThrowsError(try LookFile.decode(try JSONSerialization.data(withJSONObject: newer)))
    }

    // The reset rules
    func testResetsAreIdempotentAndScoped() throws {
        let src = SidecarSource(name: "IMG_0001.CR2", size: 1, mtime: Date(), fingerprint: "sha256:00")
        var s = Sidecar(source: src)
        s = SidecarEdits.setDevelop(s, DevelopSettings(stock: "kodak-gold-200", base: BaseSettings(mode: .anchor)))
        s = SidecarEdits.applyLook(s, ShippedLooks.look("pop")!)
        XCTAssertEqual(s.look, "pop"); XCTAssertNotNil(s.enhance)
        let once = SidecarEdits.resetEnhance(s), twice = SidecarEdits.resetEnhance(once)
        XCTAssertEqual(once, twice, "reset enhance twice equals once")
        XCTAssertNotNil(once.develop, "reset enhance keeps develop"); XCTAssertNil(once.enhance); XCTAssertNil(once.look)
        let dOnce = SidecarEdits.resetDevelop(s), dTwice = SidecarEdits.resetDevelop(dOnce)
        XCTAssertEqual(dOnce, dTwice, "reset develop twice equals once")
        XCTAssertNil(dOnce.develop)
        // The enhance layer and the look stay, dormant, for the next positive.
        XCTAssertEqual(dOnce.enhance, s.enhance, "reset develop holds the enhance layer")
        XCTAssertEqual(dOnce.look, "pop", "and the look name")
        let changed = SidecarEdits.setDevelop(s, DevelopSettings(stock: "generic", autoTone: false, base: BaseSettings(mode: .anchor)))
        XCTAssertEqual(changed.enhance, s.enhance, "changing develop keeps enhance")
        XCTAssertEqual(changed.look, "pop")
        var slid = ShippedLooks.look("pop")!.settings; slid.exposure = 0.1
        let edited = SidecarEdits.setEnhance(s, slid)
        XCTAssertNil(edited.look, "a slider edit drops the look name")
    }
}
