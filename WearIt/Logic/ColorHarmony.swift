import Foundation

/// Named wardrobe colors as numbers (approximate LCh), so looks can be judged
/// by color rules: tonal, neutral base + one color, complementary, clashing.
/// Values are deliberately rough; fashion rules only need the right ballpark.
enum ColorHarmony {
    struct Info: Equatable {
        /// Lightness 0 (black) ... 100 (white).
        let lightness: Double
        /// Saturation-like strength, 0 for grays.
        let chroma: Double
        /// Hue angle in degrees, nil for true neutrals and multicolor.
        let hue: Double?
        /// Goes with anything (black, white, gray, navy, denim, beige, cream, brown).
        let isNeutral: Bool
        /// Printed / many colors: counts as a pattern and a color accent.
        let isMulticolor: Bool
    }

    static func info(_ tag: ColorTag) -> Info {
        switch tag {
        case .black: return Info(lightness: 5, chroma: 0, hue: nil, isNeutral: true, isMulticolor: false)
        case .white: return Info(lightness: 97, chroma: 0, hue: nil, isNeutral: true, isMulticolor: false)
        case .gray: return Info(lightness: 55, chroma: 0, hue: nil, isNeutral: true, isMulticolor: false)
        case .navy: return Info(lightness: 22, chroma: 30, hue: 265, isNeutral: true, isMulticolor: false)
        case .denim: return Info(lightness: 40, chroma: 25, hue: 250, isNeutral: true, isMulticolor: false)
        case .beige: return Info(lightness: 85, chroma: 12, hue: 80, isNeutral: true, isMulticolor: false)
        case .cream: return Info(lightness: 93, chroma: 8, hue: 90, isNeutral: true, isMulticolor: false)
        case .brown: return Info(lightness: 35, chroma: 25, hue: 60, isNeutral: true, isMulticolor: false)
        case .olive: return Info(lightness: 45, chroma: 30, hue: 110, isNeutral: false, isMulticolor: false)
        case .blue: return Info(lightness: 45, chroma: 60, hue: 260, isNeutral: false, isMulticolor: false)
        case .lightBlue: return Info(lightness: 80, chroma: 25, hue: 240, isNeutral: false, isMulticolor: false)
        case .red: return Info(lightness: 50, chroma: 75, hue: 30, isNeutral: false, isMulticolor: false)
        case .pink: return Info(lightness: 75, chroma: 35, hue: 350, isNeutral: false, isMulticolor: false)
        case .orange: return Info(lightness: 65, chroma: 70, hue: 55, isNeutral: false, isMulticolor: false)
        case .yellow: return Info(lightness: 88, chroma: 75, hue: 95, isNeutral: false, isMulticolor: false)
        case .green: return Info(lightness: 50, chroma: 50, hue: 140, isNeutral: false, isMulticolor: false)
        case .burgundy: return Info(lightness: 28, chroma: 40, hue: 15, isNeutral: false, isMulticolor: false)
        case .purple: return Info(lightness: 40, chroma: 50, hue: 305, isNeutral: false, isMulticolor: false)
        case .multicolor: return Info(lightness: 60, chroma: 55, hue: nil, isNeutral: false, isMulticolor: true)
        }
    }

    /// Shortest distance between two hue angles, 0...180.
    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    /// Muted colors are easy to combine (complementary pairs work when one is muted).
    static let mutedChroma: Double = 35
}
