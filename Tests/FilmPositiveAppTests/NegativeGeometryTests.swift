import XCTest
import CoreGraphics
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// A render service that answers immediately with a picture whose shape follows the
/// request's geometry, so a developed frame's display image can be asserted by its
/// dimensions. The base frame is deliberately not square: a quarter turn has to be
/// visible in the size.
private final class ShapedRenderService: RenderService, @unchecked Sendable {
    func render(_ request: RenderRequest) async throws -> RenderResult {
        let w = 8, h = 4
        var pixels = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let p = (y * w + x) * 3
                pixels[p] = UInt16(1000 * x)
                pixels[p + 1] = UInt16(500 * y)
                pixels[p + 2] = 100
            }
        }
        let base = DecodedFrame(width: w, height: h, pixels: pixels)
        return RenderResult(frame: Geometry.apply(base, request.geometry), analysis: nil)
    }
}

/// Geometry on a frame that has NOT been made positive: a flip or a rotate on an
/// undeveloped frame has to show in the grid and the viewer.
///
/// `RenderCoordinator.request(for:)` returns nil without a develop section, so an
/// undeveloped frame never reaches the render service and both views fall back to
/// `NegativeThumbnailCache.thumbnail(for:)`. Keyed on the URL alone, that cache would
/// decode a picture that has never seen the frame's geometry, and the edit in the sidecar
/// would have no path to any pixel on screen.
///
/// What is pinned here: the geometry pass over a reduced thumbnail, the cache answering
/// per geometry rather than per URL, the sidecar carrying the edit on an undeveloped
/// frame, and the developed path still going through the coordinator unchanged.
final class NegativeGeometryTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-negative-geometry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: helpers

    /// A bitmap with a different value in every pixel, so a mirror or a turn cannot be
    /// mistaken for a no-op by a byte comparison.
    private func ramp(width: Int, height: Int) -> ThumbnailBitmap {
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let p = (y * width + x) * 3
                rgb[p] = UInt8((x * 7 + y * 3) % 256)
                rgb[p + 1] = UInt8((x * 11 + y * 5) % 256)
                rgb[p + 2] = UInt8((x + y) % 256)
            }
        }
        return ThumbnailBitmap(width: width, height: height, rgb: rgb)
    }

    private func pixel(_ b: ThumbnailBitmap, _ x: Int, _ y: Int) -> [UInt8] {
        let p = (y * b.width + x) * 3
        return [b.rgb[p], b.rgb[p + 1], b.rgb[p + 2]]
    }

    /// The bytes behind a CGImage, for "did the picture actually change".
    private func bytes(_ image: CGImage) throws -> Data {
        let provider = try XCTUnwrap(image.dataProvider)
        return try XCTUnwrap(provider.data) as Data
    }

    private func fixtureRaw() throws -> URL {
        guard let root = ProcessInfo.processInfo.environment["FP_FIXTURES"], !root.isEmpty else {
            throw XCTSkip("FP_FIXTURES not set")
        }
        let dir = URL(fileURLWithPath: root)
        let urls = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.lowercased().hasSuffix(".cr2") }
            .sorted()
        guard let first = urls.first else { throw XCTSkip("no CR2 in FP_FIXTURES") }
        return dir.appendingPathComponent(first)
    }

    @MainActor
    private func modelWithOneFrame(service: any RenderService) throws -> (AppModel, Frame.ID) {
        let dir = scratch.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 64).write(to: dir.appendingPathComponent("IMG_0001.CR2"))
        let model = AppModel(service: service)
        model.undoManager.groupsByEvent = false
        XCTAssertNotNil(model.addFolder(dir), "addFolder failed: \(model.lastError ?? "no error reported")")
        let id = try XCTUnwrap(model.selectedFolder?.frames.first?.id)
        return (model, id)
    }

    @MainActor
    private func edit(_ model: AppModel, _ id: Frame.ID, name: String,
                      _ change: (inout GeometrySettings) -> Void) {
        model.undoManager.beginUndoGrouping()
        model.apply({ sidecar in
            var g = sidecar.geometry ?? GeometrySettings()
            change(&g)
            return SidecarEdits.setGeometry(sidecar, g)
        }, to: id, actionName: name)
        model.undoManager.endUndoGrouping()
    }

    // MARK: the geometry pass over a thumbnail

    func testFlipMirrorsTheThumbnailColumns() {
        let base = ramp(width: 6, height: 4)
        let flipped = NegativeThumbnail.geometry(base, GeometrySettings(flip: true))

        XCTAssertEqual(flipped.width, base.width)
        XCTAssertEqual(flipped.height, base.height)
        XCTAssertNotEqual(flipped.rgb, base.rgb, "a mirror has to move pixels")
        for y in 0..<base.height {
            for x in 0..<base.width {
                XCTAssertEqual(pixel(flipped, x, y), pixel(base, base.width - 1 - x, y),
                               "column \(x) row \(y) is not the mirror of the source")
            }
        }
    }

    func testRotateNinetySwapsTheThumbnailDimensions() {
        let base = ramp(width: 6, height: 4)
        let turned = NegativeThumbnail.geometry(base, GeometrySettings(rotate: 90))

        XCTAssertEqual(turned.width, base.height)
        XCTAssertEqual(turned.height, base.width)
        XCTAssertEqual(turned.rgb.count, base.rgb.count)
        XCTAssertNotEqual(turned.rgb, base.rgb)
    }

    func testCropTakesTheNamedBoxAndIdentityIsUntouched() {
        let base = ramp(width: 8, height: 8)
        let cropped = NegativeThumbnail.geometry(
            base, GeometrySettings(crop: CropRect(x: 0.25, y: 0.5, w: 0.5, h: 0.5)))
        XCTAssertEqual(cropped.width, 4)
        XCTAssertEqual(cropped.height, 4)
        XCTAssertEqual(pixel(cropped, 0, 0), pixel(base, 2, 4), "the crop box is the sidecar's rect")

        let identity = NegativeThumbnail.geometry(base, GeometrySettings())
        XCTAssertEqual(identity.rgb, base.rgb, "an identity geometry must not touch the picture")
    }

    func testStraightenResamplesWithoutChangingTheThumbnailSize() {
        let base = ramp(width: 16, height: 12)
        let straightened = NegativeThumbnail.geometry(base, GeometrySettings(straightenDegrees: 4))
        XCTAssertEqual(straightened.width, base.width)
        XCTAssertEqual(straightened.height, base.height)
        XCTAssertNotEqual(straightened.rgb, base.rgb, "a real angle has to change the picture")
    }

    // MARK: the cache

    /// As the views meet it: the same undeveloped file asked for under two
    /// geometries must answer with two different pictures.
    @MainActor
    func testCacheAnswersPerGeometryForAnUndevelopedFrame() async throws {
        let url = try fixtureRaw()
        let cache = NegativeThumbnailCache()
        XCTAssertNil(cache.thumbnail(for: url))
        for _ in 0..<400 where cache.counts.cached == 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let plain = try XCTUnwrap(cache.thumbnail(for: url),
                                  "decode failed: \(cache.failure(for: url) ?? "none reported")")
        let plainBytes = try bytes(plain)

        let mirrored = try XCTUnwrap(cache.thumbnail(for: url, geometry: GeometrySettings(flip: true)))
        XCTAssertEqual(mirrored.width, plain.width)
        XCTAssertEqual(mirrored.height, plain.height)
        XCTAssertNotEqual(try bytes(mirrored), plainBytes,
                          "a flip on an undeveloped frame must change the picture the grid draws")

        let turned = try XCTUnwrap(cache.thumbnail(for: url, geometry: GeometrySettings(rotate: 90, flip: true)))
        XCTAssertEqual(turned.width, plain.height, "a quarter turn swaps the picture's sides")
        XCTAssertEqual(turned.height, plain.width)

        let again = try XCTUnwrap(cache.thumbnail(for: url))
        XCTAssertEqual(try bytes(again), plainBytes, "going back to no geometry returns the original")
        XCTAssertEqual(cache.counts.cached, 1, "every geometry comes off ONE decode")
    }

    // MARK: the sidecar and the two render paths

    @MainActor
    func testUndevelopedFrameCarriesTheGeometryAndStillHasNoRenderRequest() throws {
        let (model, id) = try modelWithOneFrame(service: ShapedRenderService())
        edit(model, id, name: "Mirror") { $0.flip.toggle() }
        edit(model, id, name: "Rotate Right") { $0.rotate = 90 }

        let frame = try XCTUnwrap(model.frame(id))
        // Rotating a frame nobody has processed says nothing about its film or its tone, so
        // the geometry is written and the develop layer is not, and the frame is still a
        // negative with no render request.
        XCTAssertFalse(frame.isDeveloped, "a geometry-only edit does not process a frame")
        XCTAssertNil(frame.sidecar.develop)
        XCTAssertEqual(frame.sidecar.geometry?.flip, true)
        XCTAssertEqual(frame.sidecar.geometry?.rotate, 90)
        XCTAssertNil(model.renders.request(for: frame),
                     "still a negative, so there is nothing to render")
    }

    /// A frame NOBODY has touched carries no develop layer on disk, renders nothing, and
    /// still shows the values a press of Positive would write in the inspector's rows.
    @MainActor
    func testAPristineFrameRendersNothingAndStillHasNoDevelopLayer() throws {
        let (model, id) = try modelWithOneFrame(service: ShapedRenderService())
        let frame = try XCTUnwrap(model.frame(id))
        XCTAssertFalse(frame.isDeveloped, "nothing has been edited, so nothing is written")
        XCTAssertNil(frame.sidecar.develop)
        // No automatic render. The defaults machinery still answers for the inspector's
        // rows.
        XCTAssertNil(model.renders.request(for: frame),
                     "an untouched frame renders nothing until Positive is pressed")
        XCTAssertEqual(model.effectiveDevelop(for: frame), model.renders.defaults.initial(for: frame.sidecar),
                       "but the rows still read exactly the value a press would commit")
    }

    /// The positive path is untouched: a developed frame's geometry still goes through the
    /// coordinator and the picture it draws follows it.
    @MainActor
    func testDevelopedFrameStillShowsGeometryThroughTheCoordinator() async throws {
        let (model, id) = try modelWithOneFrame(service: ShapedRenderService())
        model.undoManager.beginUndoGrouping()
        model.apply({ s in
            SidecarEdits.setDevelop(s, DevelopSettings(
                stock: "kodak-gold-200",
                autoTone: false,
                base: BaseSettings(mode: .anchor, anchor: 4000, ratios: BaseRatios(rg: 0.22648, bg: 1.32673))))
        }, to: id, actionName: "Develop")
        model.undoManager.endUndoGrouping()

        var frame = try XCTUnwrap(model.frame(id))
        XCTAssertTrue(frame.isDeveloped)
        for _ in 0..<200 where model.renders.displayImage(for: frame) == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let before = try XCTUnwrap(model.renders.displayImage(for: frame))
        XCTAssertEqual(before.image.width, 8)
        XCTAssertEqual(before.image.height, 4)

        edit(model, id, name: "Rotate Right") { $0.rotate = 90 }
        frame = try XCTUnwrap(model.frame(id))
        XCTAssertEqual(model.renders.request(for: frame)?.geometry.rotate, 90)
        for _ in 0..<200 where model.renders.displayImage(for: frame)?.isStale != false {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let after = try XCTUnwrap(model.renders.displayImage(for: frame))
        XCTAssertEqual(after.image.width, 4, "the turned positive is the turned shape")
        XCTAssertEqual(after.image.height, 8)
    }
}
