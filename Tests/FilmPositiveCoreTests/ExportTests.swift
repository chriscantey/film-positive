import XCTest
import Foundation
import FilmSidecar
@testable import FilmPositiveCore

/// The export path.
///
/// Neutral export is the develop layer's render written through ImageIO. What it has to
/// guarantee is that nothing is lost on the way out: a 16-bit file must read back as exactly
/// the buffer that was handed to the writer, which is a round trip through our own code
/// and needs no reference render to state.
final class ExportTests: XCTestCase {
    let fixtures = FixtureFrames()
    let exporter = Exporter()
    static let tmp: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("fp-export-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    /// The fixtures, developed with Auto Tone on, which is the state an export is normally
    /// taken from.
    func levelFrames() throws -> [FixtureFrames.Frame] { try FixtureFrames.all() }

    /// One frame from each of the two sessions.
    ///
    /// Every claim in this file is about a CODEC or about a memory ceiling, and neither
    /// varies with what the picture is of, so a population buys nothing here and costs a
    /// full 18 MP develop plus a write and a read per frame. Two, rather than one, because
    /// the two sessions are different stocks and different exposures, so a content-dependent
    /// surprise would still have somewhere to show up.
    func twoFrames() throws -> [FixtureFrames.Frame] {
        let all = try levelFrames()
        return all.count > 1 ? [all.first!, all.last!] : all
    }

    private static var developedCache: [String: DecodedFrame] = [:]
    func developed(_ f: FixtureFrames.Frame) throws -> DecodedFrame {
        if let d = Self.developedCache[f.name] { return d }
        let inp = try fixtures.input(for: f, autoTone: true)
        let decoded = try fixtures.decoded(f)
        let (an, dens) = DevelopMath.analyze(decoded, input: inp)
        let out = DevelopMath.render(dens, analysis: an, box: fixtures.box(decoded), flip: true, rotate: 0)
        Self.developedCache[f.name] = out
        return out
    }

    func metadata(for f: FixtureFrames.Frame, capture: CaptureInfo? = nil, mode: ExportMode = .neutral) throws -> ExportMetadata {
        let raw = try RawMetadata.read(f.cr2)
        let develop = DevelopSettings(stock: f.stock, autoTone: true,
                                      base: BaseSettings(mode: .anchor))
        return ExportMetadata.from(raw: raw, capture: capture, develop: develop, mode: mode, lookName: nil, appVersion: "0.1.0-test")
    }

    func out(_ name: String, _ format: ExportFormat) -> URL {
        Self.tmp.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
    }

    /// One batch target over a fixture frame, with the develop settings `metadata(for:)`
    /// describes, so what the loop writes and what that helper reads agree.
    func exportTarget(_ f: FixtureFrames.Frame, url: URL, stem: String) -> ExportTarget {
        ExportTarget(url: url, stem: stem,
                     develop: DevelopSettings(stock: f.stock, autoTone: true,
                                              base: BaseSettings(mode: .anchor)),
                     geometry: GeometrySettings(), enhance: .identity, lookID: nil, capture: nil)
    }

    /// A render service that hands back whatever frame the test names for a URL.
    ///
    /// It holds no frame of its own: the closure builds one per call and the result is the
    /// only reference, so a frame the loop drops is gone. A caching stand-in would keep
    /// every frame alive and quietly turn the memory assertion into a measurement of this
    /// class instead of the loop.
    final class SyntheticRenderService: RenderService, @unchecked Sendable {
        private let make: (URL) throws -> DecodedFrame
        init(_ make: @escaping (URL) throws -> DecodedFrame) { self.make = make }
        func render(_ request: RenderRequest) async throws -> RenderResult {
            RenderResult(frame: try make(request.imageURL), analysis: nil)
        }
    }

    /// What the progress callback saw. A reference type because the callback is `@Sendable`
    /// and cannot mutate a captured local.
    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var indices: [Int] = []
        private(set) var written: [URL] = []
        private(set) var failures: [String] = []
        func add(_ i: Int, _ outcome: Result<URL, Error>) {
            lock.lock(); defer { lock.unlock() }
            indices.append(i)
            switch outcome {
            case .success(let u): written.append(u)
            case .failure(let e): failures.append("\(i): \(e)")
            }
        }
    }

    /// A Neutral export in either lossless format reads back as EXACTLY
    /// the developed buffer, sample for sample, on every fixture.
    ///
    /// This is the claim that matters about an archival master and it is checkable without
    /// a reference: the writer, the container and Apple's reader either preserve 16 bits or
    /// they do not. Stated as equality rather than a tolerance, because a lossless path
    /// that is off by one somewhere is not lossless.
    func testLosslessExportReadsBackExactlyWhatWasWritten() throws {
        var checked = 0
        for f in try twoFrames() {
            let rendered = try exporter.render(developed: try developed(f), mode: .neutral, look: .identity)
            for format in [ExportFormat.png16, .tiff16] {
                let url = out("neutral-\(f.name)", format)
                try exporter.write(rendered, to: url, format: format, colorSpace: .sRGB, metadata: try metadata(for: f))
                let back = try ExportReadback.read(url)
                XCTAssertEqual(back.bitsPerComponent, 16, "\(format) depth")
                let diff = FrameDiff.compare(back.frame, rendered)
                XCTAssertTrue(diff.sameShape, "\(f.name) \(format): shape")
                XCTAssertEqual(diff.maxAbs, 0, "\(f.name) \(format): \(diff)")
                XCTAssertEqual(diff.differing, 0, "\(f.name) \(format): \(diff)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "no export was read back, so this proves nothing")
    }

    // Four formats, each reads back at its depth and size, and lossy ones stay close
    func testFormatsReadBackAtExpectedDepth() throws {
        let f = try levelFrames()[0]
        let rendered = try developed(f)
        for format in ExportFormat.allCases {
            let url = out("fmt-\(f.name)", format)
            try exporter.write(rendered, to: url, format: format, colorSpace: .sRGB, metadata: try metadata(for: f))
            let back = try ExportReadback.read(url)
            XCTAssertEqual(back.bitsPerComponent, format.bitsPerComponent, "\(format) depth")
            XCTAssertEqual(back.width, rendered.width, "\(format) width")
            XCTAssertEqual(back.height, rendered.height, "\(format) height")
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if format.isLossy {
                // Lossy sanity in 8-bit units against the 16-bit render. Film grain is
                // high-frequency content, so JPEG at 0.92 lands near 2.4/255 mean on an
                // 18 MP frame (measured). The 10-bit formats read back through a 16-bit
                // draw, so they are compared at full scale. Bounded at 4/255.
                let shift = format.bitsPerComponent == 8 ? 8 : 0
                var sum = 0.0
                for i in 0..<rendered.pixels.count {
                    let a = Double(back.pixelsRGB[i]) / (shift == 8 ? 1 : 257.0)
                    let b = Double(rendered.pixels[i] >> shift) / (shift == 8 ? 1 : 257.0)
                    sum += abs(a - b)
                }
                let mean = sum / Double(rendered.pixels.count)
                XCTAssertLessThan(mean, 4.0, "\(format) mean |d| in 8-bit units")
                print("\(format) mean |d| \(String(format: "%.2f", mean))/255, \(bytes / 1000) kB")
            } else {
                print("\(format) \(bytes / 1000) kB")
            }
        }
    }

    // ICC embedded, sRGB or Display P3 by name, and P3 is a real conversion
    func testICCProfileAndColorSpaceSelectable() throws {
        let f = try levelFrames()[0]
        let rendered = try developed(f)
        var pixels: [ExportColorSpace: [UInt16]] = [:]
        for space in ExportColorSpace.allCases {
            for format in ExportFormat.allCases {
                let url = out("icc-\(space.rawValue)", format)
                try exporter.write(rendered, to: url, format: format, colorSpace: space, metadata: try metadata(for: f))
                let back = try ExportReadback.read(url)
                XCTAssertEqual(back.profileName, space.profileName, "\(format) \(space) profile name")
                if format == .tiff16 { pixels[space] = back.pixelsRGB }
            }
        }
        let a = try XCTUnwrap(pixels[.sRGB]), b = try XCTUnwrap(pixels[.displayP3])
        XCTAssertNotEqual(a[0..<3000], b[0..<3000], "P3 export must be converted, not retagged")
        // a converted saturated red loses chroma in P3 coordinates: red channel drops, green rises
        var redDrop = 0, n = 0
        var i = 0
        while i < a.count && n < 200_000 {
            if a[i] > 40000 && a[i + 1] < 20000 { n += 1; if b[i] < a[i] && b[i + 1] > a[i + 1] { redDrop += 1 } }
            i += 3
        }
        if n > 100 { XCTAssertGreaterThan(Double(redDrop) / Double(n), 0.9, "P3 conversion direction on saturated reds") }
    }

    // A pushed low-key frame still holds real 16-bit content
    func testSixteenBitExportHoldsMoreThan256Levels() throws {
        let f = try levelFrames()[0]
        let r = try developed(f)
        // push it low-key: a fifth of the range, the case where an 8-bit render would band
        let dark = DecodedFrame(width: r.width, height: r.height, pixels: r.pixels.map { UInt16(Double($0) * 0.2) })
        let url = out("lowkey-\(f.name)", .tiff16)
        try exporter.write(dark, to: url, format: .tiff16, colorSpace: .sRGB, metadata: try metadata(for: f))
        let levels = try ExportReadback.read(url).distinctLevels
        for (c, n) in levels.enumerated() { XCTAssertGreaterThan(n, 256, "channel \(c) distinct levels \(n)") }
        // and the 8-bit control cannot exceed 256, proving the probe discriminates
        let jpg = out("lowkey-\(f.name)", .jpeg)
        try exporter.write(dark, to: jpg, format: .jpeg, colorSpace: .sRGB, metadata: try metadata(for: f))
        let jpegLevels = try ExportReadback.read(jpg).distinctLevels
        for n in jpegLevels { XCTAssertLessThanOrEqual(n, 256) }
        // The 10-bit formats on the same dark frame: a fifth of 1024 is about 205 levels,
        // roughly four times what 8-bit holds there (measured: HEIC 216 to 223,
        // AVIF 215 to 222, JPEG about 50), never more than 1024.
        for format in [ExportFormat.heic, .avif] {
            let u = out("lowkey-\(f.name)", format)
            try exporter.write(dark, to: u, format: format, colorSpace: .sRGB, metadata: try metadata(for: f))
            let lv = try ExportReadback.read(u).distinctLevels
            for (c, n) in lv.enumerated() {
                XCTAssertGreaterThan(n, 2 * jpegLevels[c], "\(format) levels \(lv) vs jpeg \(jpegLevels)")
                XCTAssertLessThanOrEqual(n, 1024, "\(format) levels \(lv)")
            }
            print("\(format) low-key levels \(lv), jpeg \(jpegLevels)")
        }
    }

    // Capture date from the raw. Make and model from the sidecar's camera when Tether
    // recorded one, from the raw otherwise
    func testDateAndCameraProvenance() throws {
        let f = try levelFrames()[0]
        let rendered = try developed(f)
        let raw = try RawMetadata.read(f.cr2)
        let ts = try XCTUnwrap(raw.timestamp, "fixture raw carries a timestamp")
        XCTAssertFalse(raw.make.isEmpty); XCTAssertFalse(raw.model.isEmpty)
        for format in ExportFormat.allCases {
            let url = out("prov-raw", format)
            try exporter.write(rendered, to: url, format: format, colorSpace: .sRGB, metadata: try metadata(for: f))
            let back = try ExportReadback.read(url)
            XCTAssertEqual(back.dateTimeOriginal, RawMetadata.exifDateTime(ts), "\(format) DateTimeOriginal")
            XCTAssertEqual(back.make, raw.make, "\(format) make from raw")
            XCTAssertEqual(back.model, raw.model, "\(format) model from raw")
        }
        let capture = CaptureInfo(camera: "Leica M6", cameraMake: "Leica", film: "Kodak Gold 200", filmMaker: "Kodak")
        let url = out("prov-sidecar", .tiff16)
        try exporter.write(rendered, to: url, format: .tiff16, colorSpace: .sRGB, metadata: try metadata(for: f, capture: capture))
        let back = try ExportReadback.read(url)
        XCTAssertEqual(back.make, "Leica"); XCTAssertEqual(back.model, "Leica M6")
        XCTAssertEqual(back.dateTimeOriginal, RawMetadata.exifDateTime(ts))
    }

    // AnalogExif and FilmPositive fields in the XMP packet, parsed by xmllint
    func testXMPPacketParsesWithXmllint() throws {
        let f = try levelFrames()[0]
        let rendered = try developed(f)
        let capture = CaptureInfo(camera: "Leica M6", cameraMake: "Leica", film: "Kodak Gold 200", filmMaker: "Kodak")
        for format in ExportFormat.allCases {
            let url = out("xmp", format)
            try exporter.write(rendered, to: url, format: format, colorSpace: .sRGB, metadata: try metadata(for: f, capture: capture))
            let back = try ExportReadback.read(url)
            let packet = try XCTUnwrap(back.xmpPacket, "\(format) has an XMP packet")
            let xml = Self.tmp.appendingPathComponent("packet-\(format.rawValue).xml")
            try packet.write(to: xml)
            func xpath(_ name: String) throws -> String {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
                p.arguments = ["--xpath", "string(//*[local-name()='\(name)'] | //@*[local-name()='\(name)'])", xml.path]
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
                try p.run(); p.waitUntilExit()
                return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            XCTAssertEqual(try xpath("Film"), "Kodak Gold 200", "\(format) AnalogExif:Film")
            XCTAssertEqual(try xpath("FilmMaker"), "Kodak", "\(format) AnalogExif:FilmMaker")
            XCTAssertEqual(try xpath("Stock"), f.stock, "\(format) FilmPositive:Stock")
            XCTAssertEqual(try xpath("Render"), "auto-tone", "\(format) FilmPositive:Render")
            XCTAssertEqual(try xpath("Look"), "neutral", "\(format) FilmPositive:Look")
            XCTAssertEqual(try xpath("AppVersion"), "0.1.0-test", "\(format) FilmPositive:AppVersion")
            let text = String(decoding: packet, as: UTF8.self)
            XCTAssertTrue(text.contains(ExportMetadata.analogExifNamespace), "\(format) declares the AnalogExif namespace")
            XCTAssertTrue(text.contains(ExportMetadata.filmPositiveNamespace), "\(format) declares the FilmPositive namespace")
        }
    }

    // One pipeline. Neutral ignores whatever look is passed. With Look runs the same
    // pipeline with the look, and the identity look under With Look equals Neutral.
    func testOnePipelineNeutralIgnoresLook() throws {
        let f = try levelFrames()[0]
        let r = try developed(f)
        var look = EnhanceSettings.identity
        look.exposure = 0.5
        let neutral = try exporter.render(developed: r, mode: .neutral, look: look)
        XCTAssertEqual(neutral.pixels, r.pixels)
        let withLook = try exporter.render(developed: r, mode: .withLook, look: look)
        let moved = FrameDiff.compare(withLook, r)
        XCTAssertGreaterThan(Double(moved.differing) / Double(max(moved.total, 1)), 0.5, "the look moves the frame: \(moved)")
        XCTAssertEqual(try exporter.render(developed: r, mode: .withLook, look: .identity).pixels, r.pixels)
        // the placeholder stage still refuses rather than silently exporting Neutral
        XCTAssertThrowsError(try Exporter(enhance: IdentityEnhance()).render(developed: r, mode: .withLook, look: look))
    }

    // No export preference lives in the sidecar type
    func testSidecarCarriesNoExportField() {
        var labels: [String] = []
        func walk(_ any: Any, depth: Int) {
            guard depth < 4 else { return }
            for c in Mirror(reflecting: any).children {
                if let l = c.label { labels.append(l) }
                walk(c.value, depth: depth + 1)
            }
        }
        walk(Sidecar(source: SidecarSource(name: "x", size: 1, mtime: Date(), fingerprint: "sha256:00"),
                     develop: DevelopSettings(stock: "s", base: BaseSettings(mode: .anchor))), depth: 0)
        for l in labels {
            let low = l.lowercased()
            XCTAssertFalse(low.contains("export") || low.contains("format") || low.contains("colorspace") || low.contains("colourspace"), "sidecar field \(l)")
        }
    }

    // An Export over two fixture frames plus a synthetic 25 MP frame, one in flight,
    // resident memory under 1.5 GB.
    //
    // This measures `BatchExport.run`, which is the loop the Export sheet actually drives,
    // so the guarantee is asserted on the shipped path.
    //
    // The frames come from a stand-in render service rather than a develop closure, because
    // that is where the shipped loop gets them. The service builds each frame on the call
    // and keeps no reference, so "one in flight" is still a claim about the loop and not
    // about the fixture.
    func testExportAllOneFrameInFlightUnderMemoryCeiling() async throws {
        let frames = try twoFrames()
        let folder = Self.tmp.appendingPathComponent("batch")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var targets: [ExportTarget] = []
        for f in frames { targets.append(exportTarget(f, url: f.cr2, stem: "all-\(f.name)")) }
        // 25 MP synthetic: 6000 x 4200, tiled from the first developed frame. Its URL names
        // no file on disk, which is the real path's own behavior for a raw it cannot read:
        // `RawMetadata.read` fails and `try?` turns that into no camera metadata, not a
        // failed export.
        //
        // SIX of them, the same frame under six names, and that count is what makes this
        // test a detector rather than a number. A 25 MP frame is 151 MB, so a loop that
        // held its frames would carry about 900 MB of them past the ceiling, while a loop
        // that drops each one costs the same as exporting a single frame however many
        // follow. The assertion is therefore "flat in N", expressed through a ceiling that
        // only a flat loop can stay under, rather than a threshold tuned until the bad case
        // happened to fail. Measured on x86: 954 MB clean, and an injected
        // retain reaches the ceiling. Three frames did NOT catch that injection (1106 MB,
        // still passing), which is what this population exists to fix.
        let f0 = frames[0]
        let synthetic = folder.appendingPathComponent("synthetic-25mp.cr2")
        for i in 0..<6 { targets.append(exportTarget(f0, url: synthetic, stem: "all-25mp-\(i)")) }

        let service = SyntheticRenderService { [self] url in
            guard url == synthetic else {
                return try developed(frames.first { $0.cr2 == url } ?? f0)
            }
            let r = try developed(f0)
            let w = 6000, h = 4200
            var px = [UInt16](repeating: 0, count: w * h * 3)
            for y in 0..<h {
                let sy = y % r.height
                for x in 0..<w {
                    let sx = x % r.width
                    let s = (sy * r.width + sx) * 3, d = (y * w + x) * 3
                    px[d] = r.pixels[s]; px[d + 1] = r.pixels[s + 1]; px[d + 2] = r.pixels[s + 2]
                }
            }
            return DecodedFrame(width: w, height: h, pixels: px)
        }

        let collected = Collected()
        // Sample the CURRENT resident size while the export runs: the process-lifetime
        // maximum would count every earlier test's buffers (it read 1729 MB after the
        // format tests, with this test alone at 1447 MB).
        let baseline = Self.residentBytes()
        let sampler = ResidentSampler()
        sampler.start()
        await BatchExport.run(targets, with: service, exporter: exporter, to: folder,
                              mode: .neutral, format: .tiff16, colorSpace: .sRGB, appVersion: "0.1.0-test",
                              progress: { i, outcome in collected.add(i, outcome) })
        let peak = sampler.stop()
        XCTAssertEqual(collected.indices, Array(0..<targets.count), "one progress call per target, in order")
        XCTAssertEqual(collected.failures, [], "every frame exported")
        XCTAssertEqual(collected.written.count, targets.count)
        for u in collected.written { XCTAssertTrue(FileManager.default.fileExists(atPath: u.path), u.lastPathComponent) }
        let working = peak > baseline ? peak - baseline : 0
        XCTAssertLessThan(working, 1_500_000_000, "export working set \(working / 1_000_000) MB over a \(baseline / 1_000_000) MB baseline")
        print("export-all: baseline \(baseline / 1_000_000) MB, peak during export \(peak / 1_000_000) MB, working set \(working / 1_000_000) MB over \(targets.count) frames")
    }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    /// Polls the resident size on a background thread every 10 ms and keeps the maximum.
    final class ResidentSampler: @unchecked Sendable {
        private var running = false
        private var peak: UInt64 = 0
        private let lock = NSLock()
        func start() {
            running = true
            Thread.detachNewThread { [self] in
                while true {
                    lock.lock(); let go = running; lock.unlock()
                    if !go { break }
                    let r = ExportTests.residentBytes()
                    lock.lock(); if r > peak { peak = r }; lock.unlock()
                    usleep(10_000)
                }
            }
        }
        func stop() -> UInt64 {
            lock.lock(); running = false; let p = peak; lock.unlock()
            return max(p, ExportTests.residentBytes())
        }
    }

    // Timing, recorded. The under-3-s claim is for Apple Silicon and is not asserted on x86.
    func testFullResolutionExportTiming() throws {
        let f = try levelFrames()[0]
        let r = try developed(f)
        let t0 = Date()
        try exporter.write(r, to: out("timing", .tiff16), format: .tiff16, colorSpace: .sRGB, metadata: try metadata(for: f))
        let dt = Date().timeIntervalSince(t0)
        print("full-res tiff16 write \(r.width)x\(r.height): \(String(format: "%.2f", dt)) s")
        XCTAssertLessThan(dt, 30)
    }
}
