import Foundation
import CLibRaw

/// A decoded frame: 16-bit linear camera-space RGB, interleaved, host byte order.
/// No white balance, no color matrix, no gamma, no auto-bright: the exact buffer
/// `dcraw_emu -4 -o 0 -r 1 1 1 1 -W -g 1 1` produces.
public struct DecodedFrame: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt16]   // width * height * 3

    public init(width: Int, height: Int, pixels: [UInt16]) {
        precondition(pixels.count == width * height * 3)
        self.width = width; self.height = height; self.pixels = pixels
    }
}

public enum RawDecodeError: Error, CustomStringConvertible {
    case initFailed
    case libraw(stage: String, code: Int32, message: String)
    case unexpectedImage(String)

    public var description: String {
        switch self {
        case .initFailed: return "LibRaw could not initialize"
        case .libraw(let s, let c, let m): return "LibRaw \(s) failed (\(c)): \(m)"
        case .unexpectedImage(let m): return "LibRaw returned an unexpected image: \(m)"
        }
    }
}

public struct RawDecoder: Sendable {
    /// `half_size` decode: every 2x2 block becomes one pixel, no interpolation, the same
    /// color path. This is the proxy decoder.
    public var halfSize: Bool

    public init(halfSize: Bool = false) { self.halfSize = halfSize }

    public static var librawVersion: String { String(cString: libraw_version()) }

    public func decode(_ url: URL) throws -> DecodedFrame {
        guard let raw = libraw_init(0) else { throw RawDecodeError.initFailed }
        defer { libraw_close(raw) }

        // The deterministic decode, matching the `dcraw_emu` flags above exactly.
        raw.pointee.params.output_bps = 16          // -4
        raw.pointee.params.output_color = 0         // -o 0: raw camera space
        raw.pointee.params.user_mul = (1, 1, 1, 1)  // -r 1 1 1 1: unity white balance
        raw.pointee.params.use_camera_wb = 0
        raw.pointee.params.use_auto_wb = 0
        raw.pointee.params.no_auto_bright = 1       // -W
        raw.pointee.params.gamm.0 = 1               // -g 1 1
        raw.pointee.params.gamm.1 = 1
        raw.pointee.params.highlight = 0
        raw.pointee.params.half_size = halfSize ? 1 : 0

        func check(_ stage: String, _ code: Int32) throws {
            if code != LIBRAW_SUCCESS.rawValue {
                throw RawDecodeError.libraw(stage: stage, code: code, message: String(cString: libraw_strerror(code)))
            }
        }
        try check("open", libraw_open_file(raw, url.path))
        try check("unpack", libraw_unpack(raw))
        try check("process", libraw_dcraw_process(raw))

        var err: Int32 = 0
        guard let img = libraw_dcraw_make_mem_image(raw, &err) else {
            throw RawDecodeError.libraw(stage: "make_mem_image", code: err, message: String(cString: libraw_strerror(err)))
        }
        defer { libraw_dcraw_clear_mem(img) }

        let p = img.pointee
        guard p.type == LIBRAW_IMAGE_BITMAP else { throw RawDecodeError.unexpectedImage("type \(p.type.rawValue)") }
        guard p.bits == 16, p.colors == 3 else { throw RawDecodeError.unexpectedImage("bits \(p.bits) colors \(p.colors)") }
        let w = Int(p.width), h = Int(p.height), n = w * h * 3
        guard Int(p.data_size) == n * 2 else { throw RawDecodeError.unexpectedImage("data_size \(p.data_size) for \(w)x\(h)") }

        var out = [UInt16](repeating: 0, count: n)
        withUnsafePointer(to: &img.pointee.data) { base in
            let src = UnsafeRawPointer(base)
            out.withUnsafeMutableBytes { dst in dst.copyMemory(from: UnsafeRawBufferPointer(start: src, count: n * 2)) }
        }
        return DecodedFrame(width: w, height: h, pixels: out)
    }
}

// MARK: - frame comparison

public struct FrameDiff: Sendable, CustomStringConvertible {
    public let sameShape: Bool
    public let maxAbs: Int
    public let differing: Int
    public let total: Int
    public let meanAbs: Double

    public var description: String {
        sameShape
            ? "max |d| \(maxAbs), differing \(differing)/\(total) (\(String(format: "%.4f", 100 * Double(differing) / Double(max(total, 1))))%), mean |d| \(String(format: "%.5f", meanAbs))"
            : "shape mismatch"
    }

    public static func compare(_ a: DecodedFrame, _ b: DecodedFrame) -> FrameDiff {
        guard a.width == b.width, a.height == b.height else {
            return FrameDiff(sameShape: false, maxAbs: 0, differing: 0, total: 0, meanAbs: 0)
        }
        var maxAbs = 0, differing = 0
        var sum: UInt64 = 0
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                for i in 0..<pa.count {
                    let d = abs(Int(pa[i]) - Int(pb[i]))
                    if d != 0 { differing += 1; sum += UInt64(d); if d > maxAbs { maxAbs = d } }
                }
            }
        }
        return FrameDiff(sameShape: true, maxAbs: maxAbs, differing: differing, total: a.pixels.count,
                         meanAbs: Double(sum) / Double(max(a.pixels.count, 1)))
    }
}
