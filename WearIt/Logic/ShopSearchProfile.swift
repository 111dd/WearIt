import Foundation

/// A local, category-aware discovery prior. These scores order candidates; they are
/// not eligibility rules, purchase probabilities, or permission to contact a shop.
struct ShopSearchProfile: Sendable {
    static let currentVersion = 1

    struct OwnedItem: Sendable {
        let id: UUID
        let productID: String?
        let category: Category
        let itemType: ItemType?
        let brand: String?
        let styles: [StyleTag]
        let fit: FitTag?
        let colors: [ColorTag]
        let estimatedFields: Set<String>
        let wearCount: Int
        let isFavorite: Bool
        let loveScore: Int

        @MainActor init(_ garment: Garment) {
            id = garment.id
            productID = garment.shopProductID
            category = garment.category
            itemType = garment.itemType
            brand = garment.brand
            styles = garment.styleTags ?? []
            fit = garment.fitTag
            colors = garment.safeColorTags
            estimatedFields = garment.aiEnrichedFields
            wearCount = garment.timesWorn
            isFavorite = garment.isFavorite
            loveScore = garment.loveScore
        }
    }

    struct FeedbackItem: Sendable {
        let item: ShopCatalogItem
        let kind: ShopFeedbackKind
        let date: Date

        init(item: ShopCatalogItem, kind: ShopFeedbackKind, date: Date) {
            self.item = item
            self.kind = kind
            self.date = date
        }
    }

    struct Evidence: Sendable {
        let score: Double
        let confidence: Double
        let independentItems: Int
        let positiveMass: Double
        let negativeMass: Double
    }

    struct SourcePriority: Sendable {
        let storeID: String
        let storeName: String
        let score: Double
        let confidence: Double
        let productCount: Int
        /// Only brands actually present in the supplied catalog, never inferred shop ties.
        let matchingBrandKeys: [String]
    }

    let version: Int
    let generatedAt: Date
    let evidenceCount: Int
    /// Strongest supported dimension; confidence remains available per attribute too.
    let confidence: Double
    let brandsByCategory: [Category: [String: Evidence]]
    let stylesByCategory: [Category: [StyleTag: Evidence]]
    let typesByCategory: [Category: [ItemType: Evidence]]
    let explicitBrandKeys: Set<String>
    let explicitStyles: Set<StyleTag>
    let department: ShopDepartment

    static func build(items: [OwnedItem], choiceSignals: [UUID: Double], preferences: ShoppingPreferences,
        feedback: [FeedbackItem], now: Date) -> ShopSearchProfile {
        var brands: [Category: [String: Accumulator]] = [:]
        var styles: [Category: [StyleTag: Accumulator]] = [:]
        var types: [Category: [ItemType: Accumulator]] = [:]
        var identities = Set<String>()

        for item in items {
            let identity = item.productID.flatMap(nonempty).map { "product:\($0)" } ?? "garment:\(item.id.uuidString)"
            identities.insert(identity)
            let rawChoice = choiceSignals[item.id] ?? 0
            let choice = rawChoice.isFinite ? min(1.5, max(-1.5, rawChoice)) : 0
            // Ownership alone is weak. Repeated use and deliberate positive choices
            // add support, while the independent-item count still damps a lone item.
            let positive: Double = positiveSupport(for: item, choice: choice)
            let negative: Double = 0.12 * max(0.0, -choice)
            // Legacy brand/type form provenance is not reliably persisted. Keep
            // owned metadata conservative; explicit preferences and shop facts are separate.
            let metadataReliability = 0.65
            if let raw = item.brand, let brand = nonempty(BrandStore.normalizeBrandKey(raw)) {
                add(brand, category: item.category, identity: identity, positive: positive * metadataReliability,
                    negative: negative * metadataReliability, to: &brands)
            }
            let tags = Set(item.styles)
            let styleReliability = item.estimatedFields.contains(ItemTypeDefaults.FieldKey.styleTags)
                ? 0.25 : Self.styleReliability(tags, itemType: item.itemType)
            for style in tags {
                let scale = styleReliability / Double(tags.count)
                add(style, category: item.category, identity: identity, positive: positive * scale,
                    negative: negative * scale, to: &styles)
            }
            if let type = item.itemType, type != .other {
                add(type, category: item.category, identity: identity, positive: positive * metadataReliability,
                    negative: negative * metadataReliability, to: &types)
            }
        }

        // Multiple actions on the same product are one observation. A purchase wins;
        // otherwise a later save/dismissal wins, and visits cannot erase either.
        var effectiveFeedback: [String: FeedbackItem] = [:]
        for observation in feedback {
            if let previous = effectiveFeedback[observation.item.id], !supersedes(observation, previous) { continue }
            effectiveFeedback[observation.item.id] = observation
        }
        for id in effectiveFeedback.keys.sorted() {
            guard let observation = effectiveFeedback[id] else { continue }
            // A discontinued purchase is still evidence about taste. Mapping this
            // copy must not make it available in the actual catalog or bypass gates.
            var raw = observation.item
            raw.available = nil
            guard let product = ShopCatalogService.map(raw, storeName: raw.store) else { continue }
            let identity = "product:\(product.id)"
            identities.insert(identity)
            let age = max(0, now.timeIntervalSince(observation.date) / 86_400)
            let decay = pow(0.5, age / 180)
            let positive: Double
            let negative: Double
            switch observation.kind {
            case .bought: positive = 1.3 * decay; negative = 0
            case .saved: positive = 0.9 * decay; negative = 0
            case .opened: positive = 0.04 * decay; negative = 0
            case .dismissed: positive = 0; negative = 0.18 * decay
            }
            if let rawBrand = product.item.brand, let brand = nonempty(BrandStore.normalizeBrandKey(rawBrand)) {
                add(brand, category: product.category, identity: identity, positive: positive, negative: negative, to: &brands)
            }
            // Default style tags describe the type, not an observed style choice.
            let explicit = Set(ProductFieldMapper.mapStyles([raw.title, raw.description, raw.categoryPath]
                .compactMap { $0 }.joined(separator: " ")))
            for style in explicit {
                add(style, category: product.category, identity: identity, positive: positive / Double(explicit.count),
                    negative: negative / Double(explicit.count), to: &styles)
            }
            if let type = product.itemType, type != .other {
                add(type, category: product.category, identity: identity, positive: positive, negative: negative, to: &types)
            }
        }

        let brandEvidence: [Category: [String: Evidence]] = brands.mapValues { category in
            category.mapValues { $0.evidence }
        }
        let styleEvidence: [Category: [StyleTag: Evidence]] = styles.mapValues { category in
            category.mapValues { $0.evidence }
        }
        let typeEvidence: [Category: [ItemType: Evidence]] = types.mapValues { category in
            category.mapValues { $0.evidence }
        }
        let explicitBrands: Set<String> = Set(preferences.preferredBrands.compactMap { brand in
            nonempty(BrandStore.normalizeBrandKey(brand))
        })
        let explicitStyles: Set<StyleTag> = Set(preferences.preferredStyles)
        var learnedConfidence: Double = 0
        for category in brandEvidence.values {
            for evidence in category.values { learnedConfidence = max(learnedConfidence, evidence.confidence) }
        }
        for category in styleEvidence.values {
            for evidence in category.values { learnedConfidence = max(learnedConfidence, evidence.confidence) }
        }
        for category in typeEvidence.values {
            for evidence in category.values { learnedConfidence = max(learnedConfidence, evidence.confidence) }
        }
        return ShopSearchProfile(version: currentVersion, generatedAt: now,
            evidenceCount: identities.count + explicitBrands.count + explicitStyles.count,
            confidence: explicitBrands.isEmpty && explicitStyles.isEmpty ? learnedConfidence : 1,
            brandsByCategory: brandEvidence, stylesByCategory: styleEvidence, typesByCategory: typeEvidence,
            explicitBrandKeys: explicitBrands, explicitStyles: explicitStyles, department: preferences.department)
    }

    private static func positiveSupport(for item: OwnedItem, choice: Double) -> Double {
        let favoriteSupport: Double = item.isFavorite ? 0.18 : 0.0
        let loveFraction: Double = (Double(item.loveScore) - 50.0) / 50.0
        let loveSupport: Double = 0.2 * max(0.0, min(1.0, loveFraction))
        let wearCount: Double = Double(max(0, item.wearCount))
        let wearSupport: Double = 0.2 * min(4.0, log2(wearCount + 1.0))
        let choiceSupport: Double = 0.6 * max(0.0, choice)
        var support: Double = 0.12 + favoriteSupport
        support += loveSupport
        support += wearSupport
        support += choiceSupport
        return support
    }

    func brandAffinity(for product: ShopProduct) -> Double {
        guard let raw = product.item.brand else { return 0 }
        let key = BrandStore.normalizeBrandKey(raw)
        if explicitBrandKeys.contains(key) { return 1 }
        return brandsByCategory[product.category]?[key]?.score ?? 0
    }

    func styleAffinity(for product: ShopProduct) -> Double {
        let tags = Set(product.styleTags)
        guard !tags.isEmpty else { return 0 }
        let reliability = Self.styleReliability(tags, itemType: product.itemType)
        let orderedTags: [StyleTag] = tags.sorted { $0.rawValue < $1.rawValue }
        var total: Double = 0
        for style in orderedTags {
            let learnedScore: Double = stylesByCategory[product.category]?[style]?.score ?? 0
            total += explicitStyles.contains(style) ? 1.0 : learnedScore
        }
        return total / Double(tags.count) * reliability
    }

    func typeAffinity(for product: ShopProduct) -> Double {
        guard let type = product.itemType else { return 0 }
        return typesByCategory[product.category]?[type]?.score ?? 0
    }

    /// Local coverage hints only. Every store with eligible coverage is represented; no
    /// retailer relationships or search support are invented from brand similarity.
    func sourcePriorities(products: [ShopProduct], department resolvedDepartment: ShopDepartment? = nil) -> [SourcePriority] {
        let resolved = resolvedDepartment ?? department
        let available = products.filter { product in
            guard product.item.available != false, product.audience != .children else { return false }
            return resolved.includes(product.audience, category: product.category)
        }
        let byStore: [String: [ShopProduct]] = Dictionary(grouping: available, by: { $0.item.store })
        var priorities: [SourcePriority] = []
        for (storeID, storeProducts) in byStore {
            if let priority = sourcePriority(storeID: storeID, products: storeProducts) {
                priorities.append(priority)
            }
        }
        return priorities.sorted { left, right in
            left.score == right.score ? left.storeID < right.storeID : left.score > right.score
        }
    }

    private struct ScoredProduct {
        let product: ShopProduct
        let score: Double
    }

    private func sourcePriority(storeID: String, products: [ShopProduct]) -> SourcePriority? {
        guard !storeID.isEmpty else { return nil }
        var unique: [String: ShopProduct] = [:]
        for product in products where unique[product.id] == nil { unique[product.id] = product }
        var scored: [ScoredProduct] = []
        var brandKeys: Set<String> = []
        for product in unique.values {
            let brandScore: Double = brandAffinity(for: product)
            let styleScore: Double = styleAffinity(for: product)
            let typeScore: Double = typeAffinity(for: product)
            var score: Double = 0.5 * brandScore + 0.3 * styleScore
            score += 0.2 * typeScore
            scored.append(ScoredProduct(product: product, score: score))
            if brandScore > 0.2, let brand = product.item.brand {
                brandKeys.insert(BrandStore.normalizeBrandKey(brand))
            }
        }
        scored.sort { left, right in
            left.score == right.score ? left.product.id < right.product.id : left.score > right.score
        }
        let covered: [ScoredProduct] = Array(scored.prefix(20))
        guard let first = covered.first else { return nil }
        var scoreTotal: Double = 0
        var confidenceTotal: Double = 0
        for candidate in covered {
            scoreTotal += candidate.score
            confidenceTotal += productConfidence(candidate.product)
        }
        let denominator: Double = Double(covered.count)
        return SourcePriority(storeID: storeID, storeName: first.product.storeName,
            score: scoreTotal / denominator, confidence: confidenceTotal / denominator,
            productCount: unique.count, matchingBrandKeys: brandKeys.sorted())
    }

    private func productConfidence(_ product: ShopProduct) -> Double {
        let brand = product.item.brand.map(BrandStore.normalizeBrandKey) ?? ""
        let brandConfidence = explicitBrandKeys.contains(brand) ? 1 : (brandsByCategory[product.category]?[brand]?.confidence ?? 0)
        let tags = Set(product.styleTags)
        let styleConfidence = tags.map { explicitStyles.contains($0) ? 1 : (stylesByCategory[product.category]?[$0]?.confidence ?? 0) }.max() ?? 0
        let typeConfidence = product.itemType.flatMap { typesByCategory[product.category]?[$0]?.confidence } ?? 0
        return max(brandConfidence, max(styleConfidence * Self.styleReliability(tags, itemType: product.itemType), typeConfidence))
    }

    private static func styleReliability(_ tags: Set<StyleTag>, itemType: ItemType?) -> Double {
        guard !tags.isEmpty else { return 0 }
        let defaults = itemType.flatMap { ItemTypeDefaults.defaults(for: $0)?.styleTags } ?? []
        // Older items may lack provenance. Exact type defaults stay weak even then;
        // they cannot become strong style evidence just because a flag is missing.
        return tags == Set(defaults) ? 0.25 : 1
    }

    private static func nonempty(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func supersedes(_ candidate: FeedbackItem, _ previous: FeedbackItem) -> Bool {
        if candidate.kind == .bought || previous.kind == .bought {
            if candidate.kind != previous.kind { return candidate.kind == .bought }
        } else if candidate.kind == .opened || previous.kind == .opened {
            if candidate.kind != previous.kind { return previous.kind == .opened }
        }
        return candidate.date == previous.date ? candidate.kind.rawValue < previous.kind.rawValue : candidate.date > previous.date
    }

    private static func add<Key: Hashable>(_ key: Key, category: Category, identity: String,
        positive: Double, negative: Double, to values: inout [Category: [Key: Accumulator]]) {
        values[category, default: [:]][key, default: Accumulator()].record(identity: identity, positive: positive, negative: negative)
    }

    private struct Accumulator {
        struct Contribution {
            var positive: Double
            var negative: Double
        }
        var items: [String: Contribution] = [:]

        mutating func record(identity: String, positive: Double, negative: Double) {
            let previous = items[identity]
            // The same purchased wardrobe item and its shop reaction are not two
            // independent items; retain the strongest support instead of adding it.
            items[identity] = Contribution(positive: max(previous?.positive ?? 0, positive),
                negative: max(previous?.negative ?? 0, negative))
        }

        var evidence: Evidence {
            let observations = items.keys.sorted().compactMap { items[$0] }
            let positive = observations.reduce(0) { $0 + $1.positive }
            let negative = observations.reduce(0) { $0 + $1.negative }
            let count = observations.filter { $0.positive > 0 }.count
            let confidence = Double(count) / Double(count + 2)
                * min(1, positive / max(0.5, Double(count) * 0.5))
            // Dismissal reasons are unknown. Their weak attribute evidence may
            // soften a preference, but can never ban a brand or its retailer.
            let score = confidence * positive / (positive + min(negative, positive * 0.35) + 0.25)
            return Evidence(score: min(1, max(0, score)), confidence: min(1, max(0, confidence)),
                independentItems: items.count, positiveMass: positive, negativeMass: negative)
        }
    }
}
