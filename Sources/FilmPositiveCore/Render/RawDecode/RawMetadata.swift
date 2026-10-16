import Foundation
import CLibRaw

/// The few EXIF facts an export needs from the raw, read through LibRaw's identify pass
/// (open only, no unpack, so it is cheap). For a tethered scan the raw's make and model
/// name the scanner camera, not the camera that shot the film. The sidecar's capture
/// info is the one that names the film camera when Tether recorded it.
public struct RawMetadata: Equatable, Sendable {
    public var make: String
    public var model: String
    /// The raw's capture time, `nil` when the file carries none.
    public var timestamp: Date?
    public var isoSpeed: Double

    public init(make: String, model: String, timestamp: Date?, isoSpeed: Double) {
        self.make = make; self.model = model; self.timestamp = timestamp; self.isoSpeed = isoSpeed
    }

    public static func read(_ url: URL) throws -> RawMetadata {
        guard let raw = libraw_init(0) else { throw RawDecodeError.initFailed }
        defer { libraw_close(raw) }
        let code = libraw_open_file(raw, url.path)
        if code != LIBRAW_SUCCESS.rawValue {
            throw RawDecodeError.libraw(stage: "open", code: code, message: String(cString: libraw_strerror(code)))
        }
        let make = cString(of: &raw.pointee.idata.make)
        let model = cString(of: &raw.pointee.idata.model)
        let t = raw.pointee.other.timestamp
        let ts: Date? = t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil
        return RawMetadata(make: make, model: model, timestamp: ts, isoSpeed: Double(raw.pointee.other.iso_speed))
    }

    /// EXIF's `DateTimeOriginal` form, local wall clock, "yyyy:MM:dd HH:mm:ss". LibRaw
    /// converts the EXIF string with `mktime`, so the local zone round-trips it.
    public static func exifDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.string(from: date)
    }

    /// A LibRaw fixed char array (imported as a tuple) as a trimmed Swift string.
    static func cString<T>(of tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { buf in
            let bytes = buf.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
    }
}
