import Foundation
import CLibJXL

/// JPEG XL export, in-process through libjxl.
///
/// Three presets: Fine at distance 0.1, Small at distance 1.0, and Lossless (modular). Input
/// is our 16-bit RGB frame. The color space is stated as a JPEG XL color encoding (sRGB, or
/// Display P3 as P3 primaries with the sRGB curve and D65), which every decoder maps without
/// a CMS. The XMP packet rides in an `xml ` box in the container, where ImageIO and exiftool
/// read it.
public enum JXLPreset: String, CaseIterable, Sendable {
    /// Distance 0.1: visually indistinguishable, still lossy, so it is not called Archive.
    case fine
    /// Distance 1.0, the sharing size.
    case small
    /// Modular lossless, nothing discarded; the size difference is the user's decision.
    case lossless
    public var distance: Float { switch self { case .fine: return 0.1; case .small: return 1.0; case .lossless: return 0 } }
    /// Effort 4. Effort 7 buys about 2 percent for 3x the time.
    public var effort: Int64 { 4 }
}

public enum JXLError: Error, CustomStringConvertible {
    case encoder(String)
    public var description: String { switch self { case .encoder(let m): return "JPEG XL encoder: \(m)" } }
}

public enum JXLEncoder {
    public static var libraryVersion: String {
        let v = JxlEncoderVersion()
        return "\(v / 1_000_000).\(v / 1000 % 1000).\(v % 1000)"
    }

    /// Encode a 16-bit RGB frame. `p3` selects Display P3 primaries; otherwise sRGB.
    public static func encode(_ frame: DecodedFrame, preset: JXLPreset, p3: Bool, xmp: Data?, exif: Data? = nil) throws -> Data {
        guard let enc = JxlEncoderCreate(nil) else { throw JXLError.encoder("create") }
        defer { JxlEncoderDestroy(enc) }
        let threads = JxlThreadParallelRunnerDefaultNumWorkerThreads()
        guard let runner = JxlThreadParallelRunnerCreate(nil, threads) else { throw JXLError.encoder("runner") }
        defer { JxlThreadParallelRunnerDestroy(runner) }
        func check(_ status: JxlEncoderStatus, _ what: String) throws {
            if status != JXL_ENC_SUCCESS { throw JXLError.encoder("\(what) failed (\(JxlEncoderGetError(enc).rawValue))") }
        }
        try check(JxlEncoderSetParallelRunner(enc, JxlThreadParallelRunner, runner), "parallel runner")
        try check(JxlEncoderUseContainer(enc, JXL_TRUE), "container")
        if xmp != nil || exif != nil { try check(JxlEncoderUseBoxes(enc), "boxes") }

        var info = JxlBasicInfo()
        JxlEncoderInitBasicInfo(&info)
        info.xsize = UInt32(frame.width)
        info.ysize = UInt32(frame.height)
        info.bits_per_sample = 16
        info.exponent_bits_per_sample = 0
        info.num_color_channels = 3
        info.num_extra_channels = 0
        info.alpha_bits = 0
        // VarDCT stores XYB and the decoder converts to the stated encoding, the same path
        // cjxl takes by default; the encoding below is what the file is tagged with.
        info.uses_original_profile = preset == .lossless ? JXL_TRUE : JXL_FALSE
        try check(JxlEncoderSetBasicInfo(enc, &info), "basic info")

        var color = JxlColorEncoding()
        JxlColorEncodingSetToSRGB(&color, JXL_FALSE)
        if p3 {
            color.primaries = JXL_PRIMARIES_P3
            color.white_point = JXL_WHITE_POINT_D65
            color.transfer_function = JXL_TRANSFER_FUNCTION_SRGB
        }
        try check(JxlEncoderSetColorEncoding(enc, &color), "color encoding")

        func addBox(_ type: String, _ data: Data, _ what: String) throws {
            // The box type is a C char[4]. Passing `&tuple.0` would hand libjxl a pointer to a
            // temporary holding one byte (the file then carried "E" plus garbage), so the
            // four bytes go through a real buffer.
            var t = Array(type.utf8.prefix(4)).map { CChar(bitPattern: $0) }
            precondition(t.count == 4)
            try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                try t.withUnsafeMutableBufferPointer { tb in
                    try check(JxlEncoderAddBox(enc, tb.baseAddress!, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), buf.count, JXL_FALSE), what)
                }
            }
        }
        if let exif {
            // "Exif" box: a 4-byte big-endian offset to the TIFF header, then the TIFF
            // (the HEIF layout, which is what ImageIO expects from a JPEG XL container)
            var payload = Data([0, 0, 0, 0]); payload.append(exif)
            try addBox("Exif", payload, "exif box")
        }
        if let xmp {
            // "xml " box, uncompressed so any reader finds it without Brotli
            try addBox("xml ", xmp, "xmp box")
        }
        if xmp != nil || exif != nil { JxlEncoderCloseBoxes(enc) }

        guard let settings = JxlEncoderFrameSettingsCreate(enc, nil) else { throw JXLError.encoder("frame settings") }
        if preset == .lossless {
            try check(JxlEncoderSetFrameLossless(settings, JXL_TRUE), "lossless")
        } else {
            try check(JxlEncoderSetFrameDistance(settings, preset.distance), "distance")
        }
        try check(JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, preset.effort), "effort")

        var format = JxlPixelFormat(num_channels: 3, data_type: JXL_TYPE_UINT16, endianness: JXL_NATIVE_ENDIAN, align: 0)
        try frame.pixels.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            try check(JxlEncoderAddImageFrame(settings, &format, buf.baseAddress!, buf.count), "add frame")
        }
        JxlEncoderCloseInput(enc)

        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            var status: JxlEncoderStatus = JXL_ENC_ERROR
            var used = 0
            chunk.withUnsafeMutableBufferPointer { cb in
                var next: UnsafeMutablePointer<UInt8>? = cb.baseAddress
                var avail = cb.count
                status = JxlEncoderProcessOutput(enc, &next, &avail)
                used = cb.count - avail
            }
            out.append(contentsOf: chunk[0..<used])
            if status == JXL_ENC_SUCCESS { break }
            if status != JXL_ENC_NEED_MORE_OUTPUT { throw JXLError.encoder("process output (\(JxlEncoderGetError(enc).rawValue))") }
        }
        return out
    }
}
