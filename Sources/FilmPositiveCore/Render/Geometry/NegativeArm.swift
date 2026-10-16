import Foundation
import FilmSidecar

/// The gamma-encoded NEGATIVE, for detectors that read the film rather than the operator's
/// view of it.
///
/// Why a second arm exists at all. The perforation rung finds the sprocket holes, and on the
/// developed positive of a well-exposed color negative the rebate renders black, so the
/// holes vanish into it: 13 of a set of 114 frames, every one a Gold or Vision3 frame the
/// rung then refused. On the negative the holes are bare light against the clear base and
/// cannot hide. The rung reads the holes here and the frame edges on the positive.
///
/// Why sRGB and not the linear decode. Every threshold in the crop engine is a number on a
/// display-referred scale (see `ColorGrid.sample`), measured on the camera's sRGB preview.
/// A linear frame compresses the shadows and moves every threshold at once. The transfer is
/// sRGB rather than a 2.2 power law because that is what the camera wrote, and it matches
/// the arm the rung was scored with exactly.
///
/// Why the geometry is applied here. The app renders the developed frame with the frame's
/// quarter turn and flip already applied, and the two grids the rung reads have to line up
/// pixel for pixel. Straighten and crop are deliberately NOT applied: detection runs on the
/// uncropped, unstraightened picture (see `AppModel.autoCropSelection`).
public enum NegativeArm {

    /// sRGB-encode a linear decode.
    public static func encode(_ decoded: DecodedFrame) -> DecodedFrame {
        var px = decoded.pixels
        for i in 0..<px.count {
            let v = Double(px[i]) / 65535
            let e = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
            px[i] = UInt16(min(max(e, 0), 1) * 65535)
        }
        return DecodedFrame(width: decoded.width, height: decoded.height, pixels: px)
    }

    /// The arm the detector wants: the proxy decode, encoded, turned and flipped like the
    /// developed frame it will be read beside. Straighten and crop are dropped on purpose.
    public static func from(decoded: DecodedFrame, geometry g: GeometrySettings) -> DecodedFrame {
        let oriented = GeometrySettings(rotate: g.rotate, flip: g.flip, straightenDegrees: 0, crop: nil)
        return Geometry.apply(encode(decoded), oriented)
    }
}

public extension CPURenderService {
    /// The negative arm for `AutoCrop.detect(in:expecting:negative:)`, from the same cached
    /// proxy decode the developed frame came from, so it costs one encode and no second
    /// LibRaw pass. `geometry` is the frame's sidecar geometry; only rotate and flip are used.
    func negativeArm(for url: URL, geometry: GeometrySettings) throws -> DecodedFrame {
        NegativeArm.from(decoded: try decoded(url, scale: .proxy), geometry: geometry)
    }
}
