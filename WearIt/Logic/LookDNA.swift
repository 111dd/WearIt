import Foundation

/// A look's style fingerprint, computed from its pieces' existing tags (color,
/// pattern, fit, style, formality). Lets the recommender judge a look as a
/// whole, learn which kinds of looks the user likes, and find similar or
/// contrasting combinations. Computed on the fly, never stored.
struct LookDNA: Equatable {
    enum Palette: String, CaseIterable {
        /// Only neutrals (black, white, gray, navy, denim, beige...).
        case neutral
        /// Neutral base with a single color accent.
        case neutralPlusPop
        /// Colors from the same hue family.
        case tonal
        /// Neighboring hues.
        case analogous
        /// Opposite hues.
        case complementary
        /// Unrelated strong colors.
        case bold
    }

    enum Silhouette: String, CaseIterable {
        /// Loose with fitted (the classic balanced proportion).
        case balanced
        /// Loose top and loose bottom.
        case relaxed
        /// Fitted top and fitted bottom.
        case sleek
    }

    var scheme: Palette
    /// Lightness range across pieces, 0...1.
    var contrast: Double
    /// Mean color strength, 0...1.
    var colorfulness: Double
    /// Pieces with a pattern or many colors.
    var patternLoad: Int
    var formalityMean: Double
    /// Max − min formality across pieces, 0...4.
    var formalitySpread: Double
    /// Average style-tag overlap between pieces, 0...1 (0.5 when unknown).
    var styleCoherence: Double
    /// nil when the top or bottom has no fit tag.
    var silhouette: Silhouette?

    // MARK: - Build

    init(garments: [Garment]) {
        let colors = garments.compactMap { $0.safeColorTags.first }.map(ColorHarmony.info)
        let hues = colors.filter { !$0.isNeutral }.compactMap(\.hue)
        let hasMulticolor = colors.contains(where: \.isMulticolor)
        scheme = Self.classify(hues: hues, hasMulticolor: hasMulticolor)

        let lightness = colors.map(\.lightness)
        if let high = lightness.max(), let low = lightness.min(), lightness.count >= 2 {
            contrast = (high - low) / 100
        } else {
            contrast = 0
        }
        colorfulness = colors.isEmpty
            ? 0
            : min(1, colors.map(\.chroma).reduce(0, +) / Double(colors.count) / 75)

        patternLoad = garments.filter { garment in
            if let pattern = garment.patternTag, pattern != .solid { return true }
            return garment.safeColorTags.first == .multicolor
        }.count

        let formalities = garments.map { Double($0.formality) }
        formalityMean = formalities.isEmpty ? 3 : formalities.reduce(0, +) / Double(formalities.count)
        formalitySpread = (formalities.max() ?? 3) - (formalities.min() ?? 3)

        styleCoherence = Self.coherence(garments.map { Set($0.styleTags ?? []) })
        silhouette = Self.silhouette(
            top: garments.first(where: { $0.category == .top })?.fitTag,
            bottom: garments.first(where: { $0.category == .bottom })?.fitTag
        )
    }

    private static func classify(hues: [Double], hasMulticolor: Bool) -> Palette {
        switch hues.count {
        case 0:
            return hasMulticolor ? .neutralPlusPop : .neutral
        case 1:
            return hasMulticolor ? .bold : .neutralPlusPop
        default:
            var maxDistance = 0.0
            for i in 0..<hues.count {
                for j in (i + 1)..<hues.count {
                    maxDistance = max(maxDistance, ColorHarmony.hueDistance(hues[i], hues[j]))
                }
            }
            if hasMulticolor { return .bold }
            if maxDistance <= 20 { return .tonal }
            if maxDistance <= 45 { return .analogous }
            if hues.count == 2, maxDistance >= 150 { return .complementary }
            return .bold
        }
    }

    private static func coherence(_ styleSets: [Set<StyleTag>]) -> Double {
        let tagged = styleSets.filter { !$0.isEmpty }
        guard tagged.count >= 2 else { return 0.5 }
        var total = 0.0
        var pairs = 0
        for i in 0..<tagged.count {
            for j in (i + 1)..<tagged.count {
                let union = tagged[i].union(tagged[j]).count
                total += union > 0 ? Double(tagged[i].intersection(tagged[j]).count) / Double(union) : 0
                pairs += 1
            }
        }
        return pairs > 0 ? total / Double(pairs) : 0.5
    }

    private static func silhouette(top: FitTag?, bottom: FitTag?) -> Silhouette? {
        guard let top, let bottom else { return nil }
        func isLoose(_ fit: FitTag) -> Bool { fit == .relaxed || fit == .oversized }
        func isFitted(_ fit: FitTag) -> Bool { fit == .skinny || fit == .slim }
        if isLoose(top) && isLoose(bottom) { return .relaxed }
        if isFitted(top) && isFitted(bottom) { return .sleek }
        return .balanced
    }

    // MARK: - Numbers

    static let vectorSize = Palette.allCases.count + Silhouette.allCases.count + 5

    /// Fixed-order features for the look-level preference model.
    var vector: [Double] {
        var v: [Double] = Palette.allCases.map { $0 == scheme ? 1 : 0 }
        v += Silhouette.allCases.map { $0 == silhouette ? 1 : 0 }
        v.append(contrast)
        v.append(colorfulness)
        v.append(Double(min(patternLoad, 2)) / 2)
        v.append(min(formalitySpread, 4) / 4)
        v.append(styleCoherence)
        return v
    }

    /// Rule-of-thumb quality before any learning, 0...1.
    var priorScore: Double {
        var score: Double
        switch scheme {
        case .neutral: score = 0.70
        case .neutralPlusPop: score = 0.85
        case .tonal: score = 0.80
        case .analogous: score = 0.75
        // Opposite hues work when the colors are muted rather than both loud.
        case .complementary: score = colorfulness * 75 < 45 ? 0.75 : 0.60
        case .bold: score = 0.30
        }
        score -= 0.20 * Double(max(0, patternLoad - 1))
        if formalitySpread > 2 { score -= 0.20 }
        score += 0.10 * styleCoherence
        return min(1, max(0, score))
    }

    /// Cosine similarity of the two fingerprints, 0...1.
    func similarity(to other: LookDNA) -> Double {
        let a = vector
        let b = other.vector
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<min(a.count, b.count) {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return max(0, dot / (na.squareRoot() * nb.squareRoot()))
    }

    /// The same look with its most distinctive trait turned around, used to look
    /// for "something different" that still makes sense.
    var contrasting: LookDNA {
        var flipped = self
        switch scheme {
        case .neutral: flipped.scheme = .neutralPlusPop
        case .neutralPlusPop, .tonal, .analogous: flipped.scheme = contrast < 0.5 ? .neutral : .complementary
        case .complementary, .bold: flipped.scheme = .neutral
        }
        flipped.contrast = 1 - contrast
        switch silhouette {
        case .balanced?: flipped.silhouette = .relaxed
        case .relaxed?: flipped.silhouette = .sleek
        case .sleek?: flipped.silhouette = .balanced
        case nil: break
        }
        return flipped
    }
}
