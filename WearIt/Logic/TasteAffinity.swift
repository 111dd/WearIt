import Foundation

/// Derived taste signals from the wardrobe — no extra CloudKit entities required
/// for in-session scoring. A durable snapshot is also persisted via `TasteProfileStore`
/// for future deal / catalog matching.
enum TasteAffinityBuilder {
    struct Profile: Equatable {
        /// Preference mass per color (love × item weight, split across tags).
        var colorMass: [ColorTag: Double]
        /// Preference mass per brand key.
        var brandMass: [String: Double]
        var categoryMass: [Category: Double]
        var styleMass: [StyleTag: Double]
        var materialMass: [MaterialTag: Double]
        var patternMass: [PatternTag: Double]
        var fitMass: [FitTag: Double]
        /// Colors / brands the user consistently dislikes (low love, worn or rejected).
        var avoidColorMass: [ColorTag: Double]
        var avoidBrandMass: [String: Double]
        var formalityMean: Double
        var warmthMean: Double
        var formalitySpread: Double
        var sourceGarmentCount: Int

        /// 0...1 affinity for recommender (mass relative to the strongest color).
        var colorAffinity: [ColorTag: Double] {
            Self.maxNormalized(colorMass)
        }

        /// 0...1 affinity for recommender (mass relative to the strongest brand).
        var brandAffinity: [String: Double] {
            Self.maxNormalized(brandMass)
        }

        var styleAffinity: [StyleTag: Double] {
            Self.maxNormalized(styleMass)
        }

        var categoryAffinity: [Category: Double] {
            Self.maxNormalized(categoryMass)
        }

        static let empty = Profile(
            colorMass: [:],
            brandMass: [:],
            categoryMass: [:],
            styleMass: [:],
            materialMass: [:],
            patternMass: [:],
            fitMass: [:],
            avoidColorMass: [:],
            avoidBrandMass: [:],
            formalityMean: 3,
            warmthMean: 3,
            formalitySpread: 0,
            sourceGarmentCount: 0
        )

        func colorScore(for garment: Garment) -> Double {
            let tags = garment.safeColorTags
            guard !tags.isEmpty else { return 0 }
            let affinity = colorAffinity
            guard !affinity.isEmpty else { return 0 }
            let values = tags.compactMap { affinity[$0] }
            guard !values.isEmpty else { return 0 }
            let positive = values.reduce(0, +) / Double(values.count)
            let avoid = Self.avgAffinity(tags, in: Self.maxNormalized(avoidColorMass))
            return max(0, positive - avoid * 0.5)
        }

        func brandScore(for garment: Garment) -> Double {
            guard let brand = garment.brand?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !brand.isEmpty else { return 0 }
            let key = BrandStore.normalizeBrandKey(brand)
            let positive = brandAffinity[key] ?? 0
            let avoid = Self.maxNormalized(avoidBrandMass)[key] ?? 0
            return max(0, positive - avoid * 0.5)
        }

        func styleScore(for garment: Garment) -> Double {
            let tags = garment.styleTags ?? []
            guard !tags.isEmpty else { return 0 }
            return Self.avgAffinity(tags, in: styleAffinity)
        }

        func categoryScore(for garment: Garment) -> Double {
            categoryAffinity[garment.category] ?? 0
        }

        func materialScore(for garment: Garment) -> Double {
            let tags = garment.materialTags ?? []
            guard !tags.isEmpty else { return 0 }
            return Self.avgAffinity(tags, in: Self.maxNormalized(materialMass))
        }

        func fitScore(for garment: Garment) -> Double {
            guard let fit = garment.fitTag else { return 0 }
            return Self.maxNormalized(fitMass)[fit] ?? 0
        }

        /// Share of total color preference mass (sums to ~1). For Stats %.
        func colorShares(limit: Int = 5) -> [(tag: ColorTag, share: Double)] {
            Self.topShares(colorMass, limit: limit).map { (tag: $0.key, share: $0.share) }
        }

        /// Share of total brand preference mass (sums to ~1). For Stats %.
        func brandShares(limit: Int = 5) -> [(key: String, share: Double)] {
            Self.topShares(brandMass, limit: limit).map { (key: $0.key, share: $0.share) }
        }

        func styleShares(limit: Int = 5) -> [(tag: StyleTag, share: Double)] {
            Self.topShares(styleMass, limit: limit).map { (tag: $0.key, share: $0.share) }
        }

        func categoryShares(limit: Int = 5) -> [(tag: Category, share: Double)] {
            Self.topShares(categoryMass, limit: limit).map { (tag: $0.key, share: $0.share) }
        }

        func materialShares(limit: Int = 5) -> [(tag: MaterialTag, share: Double)] {
            Self.topShares(materialMass, limit: limit).map { (tag: $0.key, share: $0.share) }
        }

        func fitShares(limit: Int = 5) -> [(tag: FitTag, share: Double)] {
            Self.topShares(fitMass, limit: limit).map { (tag: $0.key, share: $0.share) }
        }

        func avoidColorShares(limit: Int = 5) -> [(tag: ColorTag, share: Double)] {
            Self.topShares(avoidColorMass, limit: limit).map { (tag: $0.key, share: $0.share) }
        }

        func avoidBrandShares(limit: Int = 5) -> [(key: String, share: Double)] {
            Self.topShares(avoidBrandMass, limit: limit).map { (key: $0.key, share: $0.share) }
        }

        private static func avgAffinity<Key: Hashable>(_ keys: [Key], in affinity: [Key: Double]) -> Double {
            guard !affinity.isEmpty else { return 0 }
            let values = keys.compactMap { affinity[$0] }
            guard !values.isEmpty else { return 0 }
            return values.reduce(0, +) / Double(values.count)
        }

        private static func maxNormalized<Key: Hashable>(_ mass: [Key: Double]) -> [Key: Double] {
            let peak = mass.values.max() ?? 0
            guard peak > 0 else { return [:] }
            return mass.mapValues { min(1, max(0, $0 / peak)) }
        }

        private static func topShares<Key: Hashable>(
            _ mass: [Key: Double],
            limit: Int
        ) -> [(key: Key, share: Double)] {
            let total = mass.values.reduce(0, +)
            guard total > 0 else { return [] }
            return mass
                .map { (key: $0.key, share: $0.value / total) }
                .sorted { lhs, rhs in
                    if lhs.share != rhs.share { return lhs.share > rhs.share }
                    return String(describing: lhs.key) < String(describing: rhs.key)
                }
                .prefix(limit)
                .map { $0 }
        }
    }

    /// Builds preference mass from love, wears, and favorites.
    /// Multi-color items split their contribution across tags so one accent
    /// color on a mostly-black wardrobe cannot dominate Stats.
    static func build(from garments: [Garment]) -> Profile {
        guard !garments.isEmpty else { return .empty }

        var colorMass: [ColorTag: Double] = [:]
        var brandMass: [String: Double] = [:]
        var categoryMass: [Category: Double] = [:]
        var styleMass: [StyleTag: Double] = [:]
        var materialMass: [MaterialTag: Double] = [:]
        var patternMass: [PatternTag: Double] = [:]
        var fitMass: [FitTag: Double] = [:]
        var avoidColorMass: [ColorTag: Double] = [:]
        var avoidBrandMass: [String: Double] = [:]

        var formalityWeighted = 0.0
        var warmthWeighted = 0.0
        var weightSum = 0.0
        var formalitySquares = 0.0

        for garment in garments {
            let contribution = itemContribution(garment)
            let tags = garment.safeColorTags
            if !tags.isEmpty {
                let perTag = contribution / Double(tags.count)
                for color in tags {
                    colorMass[color, default: 0] += perTag
                }
            }

            if let brand = garment.brand?.trimmingCharacters(in: .whitespacesAndNewlines),
               !brand.isEmpty {
                let key = BrandStore.normalizeBrandKey(brand)
                brandMass[key, default: 0] += contribution
            }

            categoryMass[garment.category, default: 0] += contribution

            let styles = garment.styleTags ?? []
            if !styles.isEmpty {
                let per = contribution / Double(styles.count)
                for style in styles {
                    styleMass[style, default: 0] += per
                }
            }

            let materials = garment.materialTags ?? []
            if !materials.isEmpty {
                let per = contribution / Double(materials.count)
                for material in materials {
                    materialMass[material, default: 0] += per
                }
            }

            if let pattern = garment.patternTag {
                patternMass[pattern, default: 0] += contribution
            }

            if let fit = garment.fitTag {
                fitMass[fit, default: 0] += contribution
            }

            // Negative taste: low love after real exposure.
            let dislike = dislikeContribution(garment)
            if dislike > 0 {
                if !tags.isEmpty {
                    let perTag = dislike / Double(tags.count)
                    for color in tags {
                        avoidColorMass[color, default: 0] += perTag
                    }
                }
                if let brand = garment.brand?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !brand.isEmpty {
                    let key = BrandStore.normalizeBrandKey(brand)
                    avoidBrandMass[key, default: 0] += dislike
                }
            }

            let w = itemWeight(garment)
            formalityWeighted += Double(garment.formality) * w
            warmthWeighted += Double(garment.warmth) * w
            formalitySquares += Double(garment.formality * garment.formality) * w
            weightSum += w
        }

        let formalityMean = weightSum > 0 ? formalityWeighted / weightSum : 3
        let warmthMean = weightSum > 0 ? warmthWeighted / weightSum : 3
        let formalityVar = weightSum > 0
            ? max(0, formalitySquares / weightSum - formalityMean * formalityMean)
            : 0

        return Profile(
            colorMass: colorMass,
            brandMass: brandMass,
            categoryMass: categoryMass,
            styleMass: styleMass,
            materialMass: materialMass,
            patternMass: patternMass,
            fitMass: fitMass,
            avoidColorMass: avoidColorMass,
            avoidBrandMass: avoidBrandMass,
            formalityMean: formalityMean,
            warmthMean: warmthMean,
            formalitySpread: sqrt(formalityVar),
            sourceGarmentCount: garments.count
        )
    }

    private static func itemContribution(_ garment: Garment) -> Double {
        let signal = Double(garment.loveScore) / 100.0
        return max(0.05, signal * itemWeight(garment))
    }

    /// Stronger when the user has worn / rated an item poorly.
    private static func dislikeContribution(_ garment: Garment) -> Double {
        guard garment.loveScore <= 35 else { return 0 }
        let exposed = garment.timesWorn > 0 || garment.lastWorn != nil
        // Never-worn low-love is a weak signal unless extremely low.
        guard exposed || garment.loveScore <= 15 else { return 0 }
        let intensity = (35.0 - Double(garment.loveScore)) / 35.0
        return max(0.05, intensity * itemWeight(garment))
    }

    private static func itemWeight(_ garment: Garment) -> Double {
        var weight = 0.35
        weight += Double(garment.loveScore) / 100.0
        weight += min(1.0, Double(garment.timesWorn) * 0.08)
        if garment.isFavorite { weight += 0.35 }
        return max(0.1, weight)
    }
}
