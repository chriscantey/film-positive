import Foundation

/// 16-bit binary PPM (P6, maxval 65535, big-endian samples), so a raw decode can be written
/// out and inspected outside the app, and a test or a tool can load one back.
public enum PPM {
    public enum PPMError: Error, CustomStringConvertible {
        case badHeader(String)
        case truncated(expected: Int, got: Int)
        public var description: String {
            switch self {
            case .badHeader(let s): return "bad PPM header: \(s)"
            case .truncated(let e, let g): return "PPM truncated: expected \(e) bytes, got \(g)"
            }
        }
    }

    public static func read(_ url: URL) throws -> DecodedFrame {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> DecodedFrame {
        // Header: "P6" ws width ws height ws maxval single-ws. Comments (#) are not produced
        // by dcraw_emu, so they are rejected rather than skipped.
        var idx = 0
        func token() throws -> String {
            while idx < data.count, isSpace(data[idx]) { idx += 1 }
            let start = idx
            while idx < data.count, !isSpace(data[idx]) { idx += 1 }
            guard idx > start else { throw PPMError.badHeader("missing token") }
            return String(decoding: data[start..<idx], as: UTF8.self)
        }
        let magic = try token()
        guard magic == "P6" else { throw PPMError.badHeader("magic \(magic)") }
        guard let w = Int(try token()), let h = Int(try token()), let maxv = Int(try token()), maxv == 65535 else {
            throw PPMError.badHeader("dimensions or maxval")
        }
        idx += 1 // the single whitespace after maxval
        let n = w * h * 3
        guard data.count - idx >= n * 2 else { throw PPMError.truncated(expected: n * 2, got: data.count - idx) }
        // 54 million samples at 18 MP, so the loop writes through a buffer pointer rather
        // than subscripting the array. Same bytes, same order, no bounds check per sample:
        // a debug build of the subscripting version spent most of a whole-frame run here.
        let px = [UInt16](unsafeUninitializedCapacity: n) { buffer, initialized in
            data.withUnsafeBytes { raw in
                let src = raw.baseAddress!.advanced(by: idx).assumingMemoryBound(to: UInt8.self)
                for i in 0..<n { buffer[i] = UInt16(src[2 * i]) << 8 | UInt16(src[2 * i + 1]) }
            }
            initialized = n
        }
        return DecodedFrame(width: w, height: h, pixels: px)
    }

    public static func write(_ f: DecodedFrame, to url: URL) throws {
        var d = Data("P6\n\(f.width) \(f.height)\n65535\n".utf8)
        d.reserveCapacity(d.count + f.pixels.count * 2)
        for v in f.pixels { d.append(UInt8(v >> 8)); d.append(UInt8(v & 0xFF)) }
        try d.write(to: url)
    }

    @inline(__always) static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }
}
