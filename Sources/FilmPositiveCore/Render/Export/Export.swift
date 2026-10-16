import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FilmSidecar

// Export: two modes, one pipeline.
//
// Neutral is the develop layer only, the finished display-referred render. With Look is
// develop plus the enhance layer. The engine has ONE pipeline: `Exporter.render` always
// runs develop then enhance, and Neutral runs it with the identity look, so the two
// modes cannot drift. Formats are TIFF 16, PNG 16, HEIC 10-bit, AVIF 10-bit and JPEG,
// the ICC profile is always embedded, the output space is sRGB or Display P3. JPEG XL is
// not writable through ImageIO on macOS 26 (no destination for public.jpeg-xl), so it is
// written through libjxl.
// Mode, format and color space are preferences, never sidecar fields.

public enum ExportMode: String, CaseIterable, Sendable {
    case neutral, withLook
}

/// The container the user picks in the Format row. One row per family, and a family with
/// more than one option gets a second Quality row under it.
///
/// The family owns the container facts, the type and the extension, because those are
/// the same whatever quality is chosen inside it. `ExportFormat` stays the concrete
/// "what to write" value: it is what the exporter, `BatchExport`, the tests and the stored
/// preference all speak.
public enum ExportFamily: String, CaseIterable, Sendable {
    case tiff16, png16, heic, avif, jpeg, jxl

    public var utType: UTType {
        switch self {
        case .tiff16: return .tiff
        case .png16: return .png
        case .heic: return .heic
        case .avif: return UTType("public.avif") ?? .heic
        case .jpeg: return .jpeg
        case .jxl: return UTType("public.jpeg-xl") ?? .data
        }
    }
    public var fileExtension: String {
        switch self {
        case .tiff16: return "tif"
        case .png16: return "png"
        case .heic: return "heic"
        case .avif: return "avif"
        case .jpeg: return "jpg"
        case .jxl: return "jxl"
        }
    }
    /// The Quality row's options, smallest file first. A family with one option shows no
    /// Quality row at all.
    public var options: [ExportFormat] {
        switch self {
        case .tiff16: return [.tiff16]
        case .png16: return [.png16]
        case .heic: return [.heic8, .heic]
        case .avif: return [.avif]
        case .jpeg: return [.jpegMedium, .jpeg, .jpegMaximum]
        case .jxl: return [.jxlSmall, .jxlFine, .jxlLossless]
        }
    }
    /// What picking this family selects. Every one of these is what the app wrote before
    /// the Quality row existed, so changing the Format row alone changes no output.
    public var `default`: ExportFormat {
        switch self {
        case .tiff16: return .tiff16
        case .png16: return .png16
        case .heic: return .heic
        case .avif: return .avif
        case .jpeg: return .jpeg
        case .jxl: return .jxlFine
        }
    }
}

/// What is actually written. The first eight case names are the ones the app has been
/// storing in `Preferences.exportFormat` since export shipped, so they must never be
/// renamed or reordered away from their raw values: an existing preference is read back
/// by `ExportFormat(rawValue:)` and a rename would silently reset a user's pick. The
/// three after them are appended for the same reason.
///
/// `jpegMedium` and `jpegMaximum` are the JPEG Quality row either side of `jpeg`, which
/// stays at 0.92 so the default output is byte-identical to what shipped. `heic8` is
/// HEIC with the depth forced to 8, the smaller file that opens in more apps.
public enum ExportFormat: String, CaseIterable, Sendable {
    case tiff16, png16, heic, avif, jpeg, jxlFine, jxlSmall, jxlLossless
    case jpegMedium, jpegMaximum, heic8

    /// The Format row this case lives under. Every case belongs to exactly one family and
    /// appears in exactly one family's `options`.
    public var family: ExportFamily {
        switch self {
        case .tiff16: return .tiff16
        case .png16: return .png16
        case .heic, .heic8: return .heic
        case .avif: return .avif
        case .jpeg, .jpegMedium, .jpegMaximum: return .jpeg
        case .jxlFine, .jxlSmall, .jxlLossless: return .jxl
        }
    }

    public var utType: UTType { family.utType }
    public var fileExtension: String { family.fileExtension }

    /// The three JPEG XL cases go through libjxl, everything else through ImageIO.
    public var jxlPreset: JXLPreset? {
        switch self { case .jxlFine: return .fine; case .jxlSmall: return .small; case .jxlLossless: return .lossless; default: return nil }
    }
    /// Bits per component the written file must read back with. HEIC and AVIF are
    /// written 10-bit (ImageIO does that on its own from a 16-bit source; forcing depth 8
    /// is what an 8-bit HEIC costs), four times JPEG's levels at a fraction of TIFF's size.
    /// Anything that reads 8 here is written with the depth stated, which is what makes
    /// `heic8` an 8-bit HEIC rather than the 10-bit one.
    public var bitsPerComponent: Int {
        switch self {
        case .tiff16, .png16, .jxlFine, .jxlSmall, .jxlLossless: return 16
        case .heic, .avif: return 10
        case .jpeg, .jpegMedium, .jpegMaximum, .heic8: return 8
        }
    }
    public var isLossy: Bool { self != .tiff16 && self != .png16 && self != .jxlLossless }

    /// The lossy compression quality this case names, when it names one. Nil means the
    /// exporter's own `lossyQuality` applies, which is how HEIC, AVIF and the 8-bit HEIC
    /// keep the single 0.92 they have always been written at.
    public var lossyQuality: Double? {
        switch self {
        case .jpegMedium: return 0.75
        case .jpeg: return 0.92
        case .jpegMaximum: return 1.0
        default: return nil
        }
    }
}

public enum ExportColorSpace: String, CaseIterable, Sendable {
    case sRGB, displayP3

    public var cgColorSpace: CGColorSpace {
        switch self {
        case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)!
        }
    }
    /// The ICC profile description ImageIO reports for a file tagged with this space.
    public var profileName: String {
        switch self {
        case .sRGB: return "sRGB IEC61966-2.1"
        case .displayP3: return "Display P3"
        }
    }
}

/// What goes into the file besides pixels. Provenance from the raw and the sidecar,
/// film fields in the open AnalogExif namespace, ours in the FilmPositive namespace.
public struct ExportMetadata: Equatable, Sendable {
    public var dateTimeOriginal: Date?
    public var make: String?
    public var model: String?
    public var film: String?
    public var filmMaker: String?
    public var stock: String
    /// "auto-tone" for the anchored tone, "flat" for none, "print" when the lab-print
    /// operator exists. The first two names predate ToneMode and stay as they are: they
    /// are in every file exported so far and renaming them would make old exports and new
    /// ones incomparable for no gain.
    public var render: String
    public var look: String         // "neutral" for the Neutral mode
    public var appVersion: String

    public init(dateTimeOriginal: Date? = nil, make: String? = nil, model: String? = nil,
                film: String? = nil, filmMaker: String? = nil,
                stock: String, render: String, look: String, appVersion: String) {
        self.dateTimeOriginal = dateTimeOriginal; self.make = make; self.model = model
        self.film = film; self.filmMaker = filmMaker
        self.stock = stock; self.render = render; self.look = look; self.appVersion = appVersion
    }

    /// The photo's date when the frame carries the day it was SHOT (`fp:TakenOn`):
    /// that day, at the time of day the negative was scanned, so the frames of one roll
    /// keep their order when a photo app sorts by date. Noon when no scan time was
    /// recorded. Nil without a day, and the raw's own timestamp (the scan) stands.
    public static func takenDate(_ capture: CaptureInfo?, calendar: Calendar = .current) -> Date? {
        guard let day = capture?.takenOn.flatMap(CaptureInfo.validDay) else { return nil }
        let p = day.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents(year: p[0], month: p[1], day: p[2], hour: 12, minute: 0, second: 0)
        if let scanned = capture?.capturedAt {
            let t = calendar.dateComponents([.hour, .minute, .second], from: scanned)
            c.hour = t.hour; c.minute = t.minute; c.second = t.second
        }
        return calendar.date(from: c)
    }

    /// The capture date comes from the raw, unless the sidecar carries the day the frame
    /// was shot (above). Make and model come from the sidecar's capture info when Tether
    /// recorded a camera, and from the raw otherwise (a tethered raw's EXIF names the
    /// scanner).
    public static func from(raw: RawMetadata?, capture: CaptureInfo?, develop: DevelopSettings,
                            mode: ExportMode, lookName: String?, appVersion: String) -> ExportMetadata {
        let sidecarCamera = capture?.camera.flatMap { $0.isEmpty ? nil : $0 }
        let make = sidecarCamera != nil ? (capture?.cameraMake ?? "") : (raw?.make ?? "")
        let model = sidecarCamera ?? (raw?.model ?? "")
        return ExportMetadata(
            dateTimeOriginal: takenDate(capture) ?? raw?.timestamp,
            make: make.isEmpty ? nil : make,
            model: model.isEmpty ? nil : model,
            film: capture?.film, filmMaker: capture?.filmMaker,
            stock: develop.stock,
            render: Self.renderName(develop.tone),
            look: mode == .neutral ? "neutral" : (lookName ?? "custom"),
            appVersion: appVersion)
    }

    static func renderName(_ tone: ToneMode) -> String {
        switch tone {
        case .flat: return "auto-tone"
        case .none: return "flat"
        case .print: return "print"
        }
    }

    public static let analogExifNamespace = "http://analogexif.sourceforge.net/ns"
    public static let analogExifPrefix = "AnalogExif"
    public static let filmPositiveNamespace = "https://github.com/chriscantey/film-positive/ns/1.0/"
    public static let filmPositivePrefix = "FilmPositive"
}

public enum ExportError: Error, CustomStringConvertible {
    case enhanceNotAvailable
    case cgImage
    case destination(String)
    case finalize(String)
    case readback(String)

    public var description: String {
        switch self {
        case .enhanceNotAvailable: return "this export path has no enhance stage, so only unenhanced frames can be exported"
        case .cgImage: return "could not wrap the frame as a CGImage"
        case .destination(let m): return "could not open the export destination: \(m)"
        case .finalize(let m): return "could not write the export: \(m)"
        case .readback(let m): return "could not read the export back: \(m)"
        }
    }
}

/// The enhance layer as the export sees it. `CoreImageEnhance` is the real one;
/// `IdentityEnhance` stays for tests, and refuses a non-identity look rather than silently
/// exporting Neutral.
public protocol EnhanceStage: Sendable {
    func apply(_ frame: DecodedFrame, settings: EnhanceSettings) throws -> DecodedFrame
}

public struct IdentityEnhance: EnhanceStage {
    public init() {}
    public func apply(_ frame: DecodedFrame, settings: EnhanceSettings) throws -> DecodedFrame {
        guard settings.isIdentity else { throw ExportError.enhanceNotAvailable }
        return frame
    }
}

public struct Exporter: Sendable {
    public var enhance: any EnhanceStage
    public var lossyQuality: Double

    public init(enhance: any EnhanceStage = CoreImageEnhance(), lossyQuality: Double = 0.92) {
        self.enhance = enhance; self.lossyQuality = lossyQuality
    }

    /// The one pipeline. `developed` is the develop layer's output (the level or flat
    /// render); `look` is the enhance layer to bake, `.identity` for Neutral.
    public func render(developed: DecodedFrame, mode: ExportMode, look: EnhanceSettings) throws -> DecodedFrame {
        let settings = mode == .neutral ? EnhanceSettings.identity : look
        return try enhance.apply(developed, settings: settings)
    }

    /// Write a rendered frame. The buffer is display-referred sRGB by construction, so an
    /// sRGB export tags it as is and nothing is converted. Display P3 converts
    /// through CoreGraphics at 16 bits.
    @discardableResult
    public func write(_ frame: DecodedFrame, to url: URL, format: ExportFormat,
                      colorSpace: ExportColorSpace, metadata: ExportMetadata) throws -> URL {
        if let preset = format.jxlPreset {
            // libjxl path: the buffer is display-referred sRGB; a P3 export converts at 16
            // bits through CoreGraphics first, then the file is tagged P3.
            var pixels = frame
            if colorSpace != .sRGB {
                let converted = try Self.convert(try Self.cgImage(frame, tagged: ExportColorSpace.sRGB.cgColorSpace),
                                                 width: frame.width, height: frame.height, to: colorSpace.cgColorSpace)
                pixels = DecodedFrame(width: frame.width, height: frame.height, pixels: try ExportReadback.drawn16(converted))
            }
            let xmp = CGImageMetadataCreateXMPData(Self.xmpMetadata(metadata), nil) as Data?
            let data = try JXLEncoder.encode(pixels, preset: preset, p3: colorSpace == .displayP3, xmp: xmp,
                                             exif: Self.exifBlob(metadata, width: frame.width, height: frame.height))
            try data.write(to: url, options: [.atomic])
            return url
        }
        var image = try Self.cgImage(frame, tagged: ExportColorSpace.sRGB.cgColorSpace)
        if colorSpace != .sRGB {
            image = try Self.convert(image, width: frame.width, height: frame.height, to: colorSpace.cgColorSpace)
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw ExportError.destination(url.path)
        }
        var options: [CFString: Any] = [kCGImageDestinationEmbedThumbnail: false]
        // Depth is stated only for the 8-bit cases: HEIC and AVIF pick 10-bit from the
        // 16-bit source when left alone, and the 16-bit formats keep the source depth.
        // Stating it is also the whole of what makes `heic8` an 8-bit HEIC.
        if format.bitsPerComponent == 8 { options[kCGImagePropertyDepth] = 8 }
        // A case that names its own quality wins; the rest take the exporter's, which is
        // the single 0.92 every lossy format was written at before the Quality row.
        if format.isLossy { options[kCGImageDestinationLossyCompressionQuality] = format.lossyQuality ?? lossyQuality }
        var exif: [CFString: Any] = [:]
        var tiff: [CFString: Any] = [:]
        if let d = metadata.dateTimeOriginal {
            exif[kCGImagePropertyExifDateTimeOriginal] = RawMetadata.exifDateTime(d)
            tiff[kCGImagePropertyTIFFDateTime] = RawMetadata.exifDateTime(d)
        }
        if let m = metadata.make { tiff[kCGImagePropertyTIFFMake] = m }
        if let m = metadata.model { tiff[kCGImagePropertyTIFFModel] = m }
        tiff[kCGImagePropertyTIFFSoftware] = "Film Positive \(metadata.appVersion)"
        if !exif.isEmpty { options[kCGImagePropertyExifDictionary] = exif }
        if !tiff.isEmpty { options[kCGImagePropertyTIFFDictionary] = tiff }

        let xmp = Self.xmpMetadata(metadata)
        CGImageDestinationAddImageAndMetadata(dest, image, xmp, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.finalize(url.path) }
        return url
    }

    // MARK: pixels

    /// A 16-bit RGB CGImage over a copy of the frame, host byte order, no alpha.
    public static func cgImage(_ frame: DecodedFrame, tagged space: CGColorSpace) throws -> CGImage {
        let data = frame.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 16, bitsPerPixel: 48,
                                bytesPerRow: frame.width * 6, space: space,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw ExportError.cgImage }
        return img
    }

    /// Color-convert at 16 bits per channel through a bitmap context in the target space.
    static func convert(_ image: CGImage, width: Int, height: Int, to space: CGColorSpace) throws -> CGImage {
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
                                  space: space, bitmapInfo: info.rawValue) else { throw ExportError.cgImage }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let out = ctx.makeImage() else { throw ExportError.cgImage }
        return out
    }

    // MARK: metadata

    /// The EXIF and TIFF tags as a TIFF blob for a JPEG XL Exif box, hand-written: a
    /// little-endian header, IFD0 (Make, Model, Orientation 1, Software, DateTime, the
    /// Exif pointer) and the Exif IFD (ExifVersion, DateTimeOriginal, PixelXDimension,
    /// PixelYDimension). Deterministic and carrying the real pixel dimensions. A
    /// one-pixel TIFF from ImageIO would carry 1x1 dimension tags that contradict the
    /// codestream.
    static func exifBlob(_ m: ExportMetadata, width: Int, height: Int) -> Data? {
        struct Entry { let tag: UInt16; let type: UInt16; let count: UInt32; let value: Data }
        func ascii(_ tag: UInt16, _ text: String) -> Entry { let d = Data(text.utf8) + Data([0]); return Entry(tag: tag, type: 2, count: UInt32(d.count), value: d) }
        func short(_ tag: UInt16, _ v: UInt16) -> Entry { return Entry(tag: tag, type: 3, count: 1, value: withUnsafeBytes(of: v.littleEndian) { Data($0) }) }
        func long(_ tag: UInt16, _ v: UInt32) -> Entry { return Entry(tag: tag, type: 4, count: 1, value: withUnsafeBytes(of: v.littleEndian) { Data($0) }) }
        func undefined(_ tag: UInt16, _ bytes: [UInt8]) -> Entry { return Entry(tag: tag, type: 7, count: UInt32(bytes.count), value: Data(bytes)) }
        let date = m.dateTimeOriginal.map { RawMetadata.exifDateTime($0) }
        var ifd0: [Entry] = []
        if let v = m.make { ifd0.append(ascii(271, v)) }
        if let v = m.model { ifd0.append(ascii(272, v)) }
        ifd0.append(short(274, 1))
        ifd0.append(ascii(305, "Film Positive \(m.appVersion)"))
        if let date { ifd0.append(ascii(306, date)) }
        var exif: [Entry] = [undefined(36864, [0x30, 0x32, 0x33, 0x32])]
        if let date { exif.append(ascii(36867, date)) }
        exif.append(long(40962, UInt32(width)))
        exif.append(long(40963, UInt32(height)))
        guard ifd0.count > 1 || date != nil else { return nil }
        // layout: header 8, IFD0 at 8, its values, then the Exif IFD and its values
        func ifdSize(_ e: [Entry]) -> Int { 2 + 12 * e.count + 4 }
        func valuesSize(_ e: [Entry]) -> Int { e.reduce(0) { $0 + ($1.value.count > 4 ? ($1.value.count + 1) & ~1 : 0) } }
        let ifd0Offset = 8
        let exifOffset = ifd0Offset + ifdSize(ifd0) + 4 * 3 + valuesSize(ifd0)   // room for the pointer entry
        ifd0.append(long(34665, UInt32(exifOffset)))
        ifd0.sort { $0.tag < $1.tag }
        exif.sort { $0.tag < $1.tag }
        var out = Data([0x49, 0x49, 0x2A, 0x00]) + withUnsafeBytes(of: UInt32(ifd0Offset).littleEndian) { Data($0) }
        func write(_ entries: [Entry], at offset: Int, next: UInt32) {
            var valueCursor = offset + ifdSize(entries)
            var values = Data()
            out += withUnsafeBytes(of: UInt16(entries.count).littleEndian) { Data($0) }
            for e in entries {
                out += withUnsafeBytes(of: e.tag.littleEndian) { Data($0) }
                out += withUnsafeBytes(of: e.type.littleEndian) { Data($0) }
                out += withUnsafeBytes(of: e.count.littleEndian) { Data($0) }
                if e.value.count <= 4 {
                    var v = e.value; while v.count < 4 { v.append(0) }; out += v
                } else {
                    out += withUnsafeBytes(of: UInt32(valueCursor).littleEndian) { Data($0) }
                    var v = e.value; if v.count % 2 == 1 { v.append(0) }
                    values += v; valueCursor += v.count
                }
            }
            out += withUnsafeBytes(of: next.littleEndian) { Data($0) }
            out += values
        }
        write(ifd0, at: ifd0Offset, next: 0)
        precondition(out.count == exifOffset, "IFD0 layout \(out.count) vs \(exifOffset)")
        write(exif, at: exifOffset, next: 0)
        return out
    }

    static func xmpMetadata(_ m: ExportMetadata) -> CGMutableImageMetadata {
        let meta = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(meta, ExportMetadata.analogExifNamespace as CFString,
                                                  ExportMetadata.analogExifPrefix as CFString, nil)
        CGImageMetadataRegisterNamespaceForPrefix(meta, ExportMetadata.filmPositiveNamespace as CFString,
                                                  ExportMetadata.filmPositivePrefix as CFString, nil)
        func set(_ path: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            CGImageMetadataSetValueWithPath(meta, nil, path as CFString, value as CFString)
        }
        set("AnalogExif:Film", m.film)
        set("AnalogExif:FilmMaker", m.filmMaker)
        set("FilmPositive:Stock", m.stock)
        set("FilmPositive:Render", m.render)
        set("FilmPositive:Look", m.look)
        set("FilmPositive:AppVersion", m.appVersion)
        if let d = m.dateTimeOriginal { set("exif:DateTimeOriginal", RawMetadata.exifDateTime(d)) }
        set("tiff:Make", m.make)
        set("tiff:Model", m.model)
        return meta
    }
}

// MARK: - read-back (for the tests)

/// What an exported file says about itself, read through ImageIO. Pixels come back as
/// interleaved RGB at the file's own depth (16-bit values for 16-bit files, 8-bit values
/// widened to UInt16 for 8-bit files), alpha dropped.
public struct ExportReadback: Sendable {
    public let width: Int
    public let height: Int
    public let bitsPerComponent: Int
    public let profileName: String?
    public let dateTimeOriginal: String?
    public let make: String?
    public let model: String?
    public let xmpPacket: Data?
    public let pixelsRGB: [UInt16]

    public var frame: DecodedFrame { DecodedFrame(width: width, height: height, pixels: pixelsRGB) }

    public static func read(_ url: URL) throws -> ExportReadback {
        var rb = try readImageIO(url)
        if url.pathExtension.lowercased() == "jxl", let boxes = JXLContainer.metadata(of: url) {
            // ImageIO decodes JPEG XL pixels and color but ignores the container's Exif
            // and xml boxes (macOS 26.6), so those come from the container itself.
            rb = ExportReadback(width: rb.width, height: rb.height, bitsPerComponent: rb.bitsPerComponent, profileName: rb.profileName,
                                dateTimeOriginal: boxes.dateTimeOriginal ?? rb.dateTimeOriginal, make: boxes.make ?? rb.make,
                                model: boxes.model ?? rb.model, xmpPacket: boxes.xmp ?? rb.xmpPacket, pixelsRGB: rb.pixelsRGB)
        }
        return rb
    }

    static func readImageIO(_ url: URL) throws -> ExportReadback {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ExportError.readback("no source at \(url.path)") }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            throw ExportError.readback("no properties")
        }
        let depth = props[kCGImagePropertyDepth] as? Int ?? 0
        let profile = props[kCGImagePropertyProfileName] as? String
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        var xmp: Data? = nil
        if let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil), let d = CGImageMetadataCreateXMPData(meta, nil) {
            xmp = d as Data
        }
        guard let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ExportError.readback("no image")
        }
        let w = img.width, h = img.height
        let bpc = img.bitsPerComponent, bpp = img.bitsPerPixel
        let fileDepth = depth == 0 ? bpc : depth
        if bpc != 8 && bpc != 16 {
            // 10-bit HEIC and AVIF: the provider bytes are packed, so draw into a 16-bit
            // context in the file's own color space (no conversion) and read that.
            return ExportReadback(width: w, height: h, bitsPerComponent: fileDepth, profileName: profile,
                                  dateTimeOriginal: exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
                                  make: tiff?[kCGImagePropertyTIFFMake] as? String,
                                  model: tiff?[kCGImagePropertyTIFFModel] as? String,
                                  xmpPacket: xmp, pixelsRGB: try drawn16(img))
        }
        let comps = bpp / bpc
        guard let data = img.dataProvider?.data as Data? else { throw ExportError.readback("no pixel data") }
        let rowBytes = img.bytesPerRow
        let alphaFirst: Bool = {
            switch img.alphaInfo {
            case .premultipliedFirst, .first, .noneSkipFirst: return true
            default: return false
            }
        }()
        let hasAlpha = comps == 4 || comps == 2
        let bigEndian = bpc == 16 && !img.bitmapInfo.contains(.byteOrder16Little)
        var out = [UInt16](repeating: 0, count: w * h * 3)
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var o = 0
            for y in 0..<h {
                var p = y * rowBytes
                for _ in 0..<w {
                    var c = [UInt16](repeating: 0, count: comps)
                    for k in 0..<comps {
                        if bpc == 16 {
                            let b0 = UInt16(buf[p]), b1 = UInt16(buf[p + 1])
                            c[k] = bigEndian ? (b0 << 8 | b1) : (b1 << 8 | b0)
                            p += 2
                        } else {
                            c[k] = UInt16(buf[p]); p += 1
                        }
                    }
                    let base = (hasAlpha && alphaFirst) ? 1 : 0
                    if comps >= 3 {
                        out[o] = c[base]; out[o + 1] = c[base + 1]; out[o + 2] = c[base + 2]
                    } else {
                        out[o] = c[base]; out[o + 1] = c[base]; out[o + 2] = c[base]
                    }
                    o += 3
                }
            }
        }
        return ExportReadback(width: w, height: h, bitsPerComponent: fileDepth, profileName: profile,
                              dateTimeOriginal: exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
                              make: tiff?[kCGImagePropertyTIFFMake] as? String,
                              model: tiff?[kCGImagePropertyTIFFModel] as? String,
                              xmpPacket: xmp, pixelsRGB: out)
    }

    static func drawn16(_ img: CGImage) throws -> [UInt16] {
        let w = img.width, h = img.height
        let space = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                                  space: space, bitmapInfo: info.rawValue), let base = ctx.data else {
            throw ExportError.readback("no 16-bit context")
        }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = base.assumingMemoryBound(to: UInt16.self)
        var out = [UInt16](repeating: 0, count: w * h * 3)
        var o = 0
        for i in 0..<(w * h) { out[o] = p[i * 4]; out[o + 1] = p[i * 4 + 1]; out[o + 2] = p[i * 4 + 2]; o += 3 }
        return out
    }

    /// Distinct values per channel, the real-16-bit check.
    public var distinctLevels: [Int] {
        var sets = [Set<UInt16>(), Set<UInt16>(), Set<UInt16>()]
        var i = 0
        while i < pixelsRGB.count { sets[0].insert(pixelsRGB[i]); sets[1].insert(pixelsRGB[i + 1]); sets[2].insert(pixelsRGB[i + 2]); i += 3 }
        return sets.map { $0.count }
    }
}

/// The JPEG XL container is ISO BMFF: 4-byte big-endian size, 4-byte type, payload
/// (size 1 means a 64-bit size follows, size 0 means to the end of the file). The
/// metadata boxes are `Exif` (4-byte offset then a TIFF) and `xml ` (an XMP packet).
enum JXLContainer {
    struct Metadata { var dateTimeOriginal: String?; var make: String?; var model: String?; var xmp: Data? }

    /// Big-endian integers read byte by byte rather than through `load(as:)`.
    ///
    /// A JXL box header sits at whatever offset the previous box ended at, and
    /// `UnsafeRawBufferPointer.load(as:)` traps on an address that is not aligned for the
    /// type it is loading ("load from misaligned raw pointer"). Whether that fires depends
    /// on where `Data` allocates and on the sizes of the boxes in the file. Assembling the
    /// bytes has no alignment requirement and states the byte order in the code.
    @inline(__always) static func beUInt32(_ d: Data, _ i: Int) -> UInt32 {
        (UInt32(d[i]) << 24) | (UInt32(d[i + 1]) << 16) | (UInt32(d[i + 2]) << 8) | UInt32(d[i + 3])
    }

    @inline(__always) static func beUInt64(_ d: Data, _ i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(d[i + k]) }
        return v
    }

    static func metadata(of url: URL) -> Metadata? {
        guard let d = try? Data(contentsOf: url), d.count > 12, d[4..<8] == Data("JXL ".utf8) else { return nil }
        var m = Metadata()
        var p = 0
        while p + 8 <= d.count {
            var size = Int(beUInt32(d, p))
            let type = String(decoding: d[p + 4..<p + 8], as: UTF8.self)
            var header = 8
            if size == 1, p + 16 <= d.count {
                size = Int(beUInt64(d, p + 8)); header = 16
            }
            if size == 0 { size = d.count - p }
            guard size >= header, p + size <= d.count else { break }
            let payload = d[p + header..<p + size]
            if type == "xml " { m.xmp = Data(payload) }
            if type == "Exif", payload.count > 4 {
                let tiff = Data(payload.dropFirst(4))
                if let src = CGImageSourceCreateWithData(tiff as CFData, nil),
                   let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                    let t = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
                    let e = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
                    m.dateTimeOriginal = e?[kCGImagePropertyExifDateTimeOriginal] as? String
                    m.make = t?[kCGImagePropertyTIFFMake] as? String
                    m.model = t?[kCGImagePropertyTIFFModel] as? String
                }
            }
            p += size
        }
        return m
    }
}
