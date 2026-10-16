import FilmPositiveCore

/// Synthetic scenes shared by the color axis tests.
enum SceneFixtures {
    /// A scene that averages neutral, multiplied per channel by a known cast, over a green
    /// ramp.
    static func neutralScene(castRG: Double, castBG: Double, width: Int = 200, height: Int = 200) -> DecodedFrame {
        var px = [UInt16](repeating: 0, count: width * height * 3)
        let full = Double(UInt16.max)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 3
                let v = 0.15 + 0.6 * Double(x) / Double(width - 1)
                px[i] = UInt16(min(full, v * castRG * full))
                px[i + 1] = UInt16(min(full, v * full))
                px[i + 2] = UInt16(min(full, v * castBG * full))
            }
        }
        return DecodedFrame(width: width, height: height, pixels: px)
    }
}
