import Foundation

/// Turns the learned look-level weights into a few plain statements about the
/// user's style ("tone-on-tone suits you", "soft low-contrast looks"). Shown
/// after a Style Swipe deck and on the profile.
enum StyleInsights {
    enum Insight: Equatable, Hashable {
        case palette(LookDNA.Palette)
        case silhouette(LookDNA.Silhouette)
        case highContrast
        case lowContrast
        case colorful
        case muted
        case patterns
        case plain
    }

    /// Look signals needed before insights are worth showing.
    static let minimumSignals = 8
    private static let threshold = 0.15

    static func insights(from state: RecoState, limit: Int = 3) -> [Insight] {
        guard state.lookInteractionCount >= minimumSignals else { return [] }
        let w = state.lookWeights
        guard w.count >= LookDNA.vectorSize else { return [] }

        var candidates: [(insight: Insight, strength: Double)] = []
        let palettes = LookDNA.Palette.allCases
        for (index, palette) in palettes.enumerated() where w[index] > threshold {
            candidates.append((.palette(palette), w[index]))
        }
        let silhouettes = LookDNA.Silhouette.allCases
        for (offset, silhouette) in silhouettes.enumerated() {
            let weight = w[palettes.count + offset]
            if weight > threshold { candidates.append((.silhouette(silhouette), weight)) }
        }

        let base = palettes.count + silhouettes.count
        let contrast = w[base]
        let colorfulness = w[base + 1]
        let patterns = w[base + 2]
        if abs(contrast) > threshold {
            candidates.append((contrast > 0 ? .highContrast : .lowContrast, abs(contrast)))
        }
        if abs(colorfulness) > threshold {
            candidates.append((colorfulness > 0 ? .colorful : .muted, abs(colorfulness)))
        }
        if abs(patterns) > threshold {
            candidates.append((patterns > 0 ? .patterns : .plain, abs(patterns)))
        }

        return candidates
            .sorted { $0.strength > $1.strength }
            .prefix(limit)
            .map(\.insight)
    }

    static func localizationKey(_ insight: Insight) -> String {
        switch insight {
        case .palette(let palette):
            switch palette {
            case .neutral: return "style_insight_palette_neutral"
            case .neutralPlusPop: return "style_insight_palette_pop"
            case .tonal: return "style_insight_palette_tonal"
            case .analogous: return "style_insight_palette_analogous"
            case .complementary: return "style_insight_palette_complementary"
            case .bold: return "style_insight_palette_bold"
            }
        case .silhouette(let silhouette):
            switch silhouette {
            case .balanced: return "style_insight_silhouette_balanced"
            case .relaxed: return "style_insight_silhouette_relaxed"
            case .sleek: return "style_insight_silhouette_sleek"
            }
        case .highContrast: return "style_insight_high_contrast"
        case .lowContrast: return "style_insight_low_contrast"
        case .colorful: return "style_insight_colorful"
        case .muted: return "style_insight_muted"
        case .patterns: return "style_insight_patterns"
        case .plain: return "style_insight_plain"
        }
    }

    static func text(_ insight: Insight) -> String {
        NSLocalizedString(localizationKey(insight), comment: "")
    }

    static func icon(_ insight: Insight) -> String {
        switch insight {
        case .palette: return "swatchpalette"
        case .silhouette: return "figure.stand"
        case .highContrast, .lowContrast: return "circle.lefthalf.filled"
        case .colorful, .muted: return "paintpalette"
        case .patterns, .plain: return "square.grid.3x3"
        }
    }
}
