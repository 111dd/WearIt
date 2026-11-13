// Personal shopping stays on the device. A sale can improve a useful recommendation;
// it cannot make an unrelated product relevant or turn a score into a purchase probability.
import Foundation
import SwiftData

enum PurchaseScorer {
    struct Profile: Sendable {
        let id: UUID
        let warmthSensitivity: Int
        let rainTolerance: Int
        let sizes: [Category: SizeOption]
    }
    struct PlannedInput: Sendable {
        let ids: [UUID]
        let date: Date
        let isEvening: Bool
        let temperature: Double?
        let raining: Bool
    }
    struct Match: Sendable {
        let taste: Double
        var wardrobe: Double? = nil
        var weather: Double? = nil
        var signals: Int = 0
        /// Component fit index, not a calibrated probability or model-accuracy claim.
        var percent: Int {
            var sum = taste * 0.5, weight = 0.5
            if let wardrobe { sum += wardrobe * 0.35; weight += 0.35 }
            if let weather { sum += weather * 0.15; weight += 0.15 }
            return Int((min(1, max(0, sum / weight)) * 100).rounded())
        }
    }
    struct Input {
        var garments: [Garment]
        var wearCounts: [UUID: Int]
        var windowDays: Int = 90
        var taste: TasteAffinityBuilder.Profile
        var gaps: [WardrobeGapAnalyzer.Gap]
        var profile: Profile?
        var model: ShopPreferenceModel
        var lookState: RecoState
        var now = Date()
        var forecasts: [DayForecast] = []
        var upcomingPlans: [PlannedInput] = []
        var includeNextSeasonDeals = false
        var feedbackSignals: ShopFeedbackStore.Signals = .empty
        var preferences = ShoppingPreferences()
        var department: ShopDepartment? = nil
        var comfort = GarmentWeatherHistory()
        var signalCount = 0
        /// Category-specific, confidence-damped evidence adjusts order after existing gates.
        var searchProfile: ShopSearchProfile? = nil
    }

    enum Reason: Hashable, Sendable {
        case fillsGap(WardrobeGapAnalyzer.Kind, Category)
        case opensLooks(Int)
        case lovedColor(ColorTag)
        case lovedBrand(String)
        case wornType(ItemType)
        case onSale(Int)
        case inYourSize(SizeOption)
        case alreadyHave(Int, ItemType)
        case fitsStyle, everydayRotation, completesLook, checkSize
        case upcomingLook(Date, Bool)
        case nextSeasonDeal(SeasonSuitability)
    }

    enum Intent: Sendable { case everyday, upcoming, nextSeason }

    struct LookPreview: Sendable {
        var ownedGarmentIDs: [UUID]
        var date: Date? = nil
        var isEvening = false
        /// At most one extra purchase. Every companion passed the same personal/stock gates.
        var companions: [Pick] = []
    }

    struct Pick: Identifiable, Sendable {
        let product: ShopProduct
        let score: Double
        let wearsPerMonth: Double?
        let looks: Int
        let reasons: [Reason]
        /// Existing positions are preserved; new features are appended.
        let features: [Double]
        var match: Match? = nil
        var intent: Intent = .everyday
        var preview: LookPreview? = nil
        var id: String { product.id }
    }

    private struct Candidate {
        let product: ShopProduct
        let metrics: Affinity.Metrics
        let need: WardrobeGapAnalyzer.Gap?
        let reaction: Double
        let quickScore: Double
    }

    private static let deepPoolSize = 70

    private struct ProductEvidence {
        let metrics: Affinity.Metrics
        let reaction: Double
    }

    /// Evaluate cheap catalog evidence once for both Explore estimates and the deep shortlist.
    static func rankAndMatch(_ products: [ShopProduct], input: Input, isHidden: (String) -> Bool,
        limit: Int = 40, retainedIDs: [String] = []) -> (picks: [Pick], matches: [String: Match]) {
        let evidence = productEvidence(products, input: input)
        guard !Task.isCancelled else { return ([], [:]) }
        let matches = browseMatches(evidence, input: input)
        let picks = rank(products, input: input, isHidden: isHidden, limit: limit,
            retainedIDs: retainedIDs, evidence: evidence)
        return Task.isCancelled ? ([], [:]) : (picks, matches)
    }

    static func rank(_ products: [ShopProduct], input: Input, isHidden: (String) -> Bool, limit: Int = 40,
        retainedIDs: [String] = []) -> [Pick] {
        rank(products, input: input, isHidden: isHidden, limit: limit, retainedIDs: retainedIDs, evidence: nil)
    }

    private static func rank(_ products: [ShopProduct], input: Input, isHidden: (String) -> Bool, limit: Int,
        retainedIDs: [String], evidence: [String: ProductEvidence]?) -> [Pick] {
        let wardrobe = input.garments.filter { !$0.isBlocked && ($0.ownerID == nil || input.profile == nil || $0.ownerID == input.profile?.id) }
        guard !wardrobe.isEmpty, limit > 0 else { return [] }
        let shares = wornTypeShare(wardrobe, wearCounts: input.wearCounts)
        let affinity = Affinity(taste: input.taste, preferences: input.preferences)
        let categoryCounts = Dictionary(grouping: wardrobe, by: \.category).mapValues(\.count)
        var usualSizes: [Category: SizeOption] = [:]
        for category in [Category.top, .bottom, .shoes, .outer] {
            usualSizes[category] = input.profile?.sizes[category]
        }
        let candidates: [Candidate] = products.compactMap { product in
            guard !Task.isCancelled, product.item.available != false, product.itemType != nil, product.itemType != .other, !isHidden(product.id),
                  (input.department ?? .automatic).includes(product.audience, category: product.category),
                  fitsUsualSize(product, usualSize: usualSizes[product.category]) else { return nil }
            let metrics = evidence?[product.id]?.metrics ?? affinity.metrics(product, typeShares: shares)
            let need = bestGap(for: product, in: input.gaps)
            let reaction = evidence?[product.id]?.reaction ?? input.feedbackSignals.score(for: product)
            // A new type in a well-established category needs evidence beyond a generic color/style.
            let unfamiliar = metrics.type == 0 && (categoryCounts[product.category] ?? 0) >= 3 && product.category != .accessory
            let strongExploration = metrics.personal >= 0.55
                && [metrics.color, metrics.brand, metrics.style, metrics.fit, metrics.pattern].filter { $0 >= 0.6 }.count >= 3
            let specificNeed = need.map { $0.suggestion.itemType == product.itemType && $0.kind != .thinRotation && $0.kind != .missingCore } ?? false
            guard !unfamiliar || specificNeed || reaction >= 0.25 || strongExploration else { return nil }
            // A first belt/bag has no owned-type/style evidence yet; its actual whole-look
            // compatibility must supply that evidence in the deep pass.
            let accessoryEvidence = product.category == .accessory && max(metrics.color, metrics.brand) >= 0.7
            guard metrics.personal >= (accessoryEvidence ? 0.2 : 0.28), metrics.evidence >= 2 || accessoryEvidence,
                  metrics.avoid < 0.8, reaction > -0.6 else { return nil }
            let quick = metrics.personal + 0.22 * (need?.priority ?? 0) + 0.15 * reaction
                + searchBonus(product, profile: input.searchProfile)
                + usefulDealBoost(product, personal: metrics.personal, usefulness: 0.65,
                    need: need?.priority ?? 0, redundancy: 0)
            return Candidate(product: product, metrics: metrics, need: need, reaction: reaction, quickScore: quick)
        }
        let sorted = candidates.sorted { $0.quickScore == $1.quickScore ? $0.product.id < $1.product.id : $0.quickScore > $1.quickScore }
        // Diversify before the expensive cutoff; a dominant type must not consume every slot.
        var shortlist: [Candidate] = []
        var selectedIDs = Set<String>()
        var categories: [Category: Int] = [:]
        var types: [ItemType: Int] = [:]
        var brands: [String: Int] = [:]
        func adjusted(_ candidate: Candidate) -> Double {
            let product = candidate.product
            return candidate.quickScore - 0.06 * Double(categories[product.category, default: 0])
                - 0.04 * Double(product.itemType.map { types[$0, default: 0] } ?? 0)
                - 0.02 * Double(brands[product.item.brand.map(BrandStore.normalizeBrandKey) ?? "", default: 0])
        }
        func append(_ candidate: Candidate) {
            guard selectedIDs.insert(candidate.product.id).inserted else { return }
            shortlist.append(candidate)
            categories[candidate.product.category, default: 0] += 1
            if let type = candidate.product.itemType { types[type, default: 0] += 1 }
            brands[candidate.product.item.brand.map(BrandStore.normalizeBrandKey) ?? "", default: 0] += 1
        }
        func bestIndex(in pool: [Candidate]) -> Int? {
            pool.indices.max {
                let left = adjusted(pool[$0]), right = adjusted(pool[$1])
                return left == right ? pool[$0].product.id > pool[$1].product.id : left < right
            }
        }
        // Recheck held recommendations even when new stock changes the cheap top 500.
        // Holding a position never bypasses the personal, stock or deep suitability gates.
        let candidatesByID = Dictionary(candidates.map { ($0.product.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in retainedIDs.prefix(20) {
            if let candidate = candidatesByID[id], candidate.product.category != .accessory { append(candidate) }
        }
        // Offers have a separate diverse reserve inside the same bounded deep pass.
        var offers = Array(sorted.filter {
            $0.product.category != .accessory && $0.product.discountPercent != nil && !selectedIDs.contains($0.product.id)
        }.prefix(500))
        var reservedOffers = 0
        while reservedOffers < 15, shortlist.count < deepPoolSize, !offers.isEmpty, !Task.isCancelled {
            guard let index = bestIndex(in: offers) else { break }
            append(offers.remove(at: index))
            reservedOffers += 1
        }
        var remaining = Array(sorted.filter {
            $0.product.category != .accessory && !selectedIDs.contains($0.product.id)
        }.prefix(500))
        while shortlist.count < deepPoolSize, !remaining.isEmpty, !Task.isCancelled {
            guard let index = bestIndex(in: remaining) else { break }
            append(remaining.remove(at: index))
        }
        shortlist += sorted.filter { $0.product.category == .accessory }.prefix(10)

        let current = currentContext(input)
        let nextSeason = nextSeason(after: input.now)
        let state = input.lookState
        let partnerPools = (0..<3).map { offset in
            ShoppingPartnerPool(wardrobe: wardrobe, wearCounts: input.wearCounts, ctx: current.context, state: state, rotationOffset: offset * 2)
        }
        let plans = plannedLooks(input: input, wardrobe: wardrobe)
        let rates = monthlyWearRate(wardrobe, wearCounts: input.wearCounts, windowDays: input.windowDays)
        // Learning adjusts ordering; the structural relevance and usefulness gates stay in charge.
        let learnedShare = 0.25 * min(1, Double(input.model.interactions) / 40)
        var picks: [Pick] = []
        var previewAlternatives: [String: [[Garment]]] = [:]

        for candidate in shortlist {
            guard !Task.isCancelled else { return [] }
            let product = candidate.product
            let garment = transientGarment(for: product)
            let hasSuitableLayer = garment.category == .top && current.context.temperatureC < 20
                && wardrobe.contains { $0.category == .outer && !$0.isCurrentlyUnavailable && weatherFit($0, context: current.context) }
            let nowFits = !current.hasWeather || weatherFit(garment, context: current.context) || hasSuitableLayer
            let planned = bestPlannedLook(for: garment, plans: plans, state: state, input: input)
            let future = !nowFits && planned == nil && input.includeNextSeasonDeals && garment.seasonSuitability == nextSeason
                && (product.discountPercent ?? 0) >= 30 && candidate.metrics.personal >= 0.45
            guard nowFits || future || planned != nil else { continue }
            let lookContext = planned?.context ?? (future ? context(input: input, temperature: seasonalTemperature(nextSeason), raining: false) : current.context)
            let checkWeather = planned?.hasWeather ?? (future || current.hasWeather)
            let poolIndex = product.id.utf8.reduce(0) { ($0 * 31 + Int($1)) % partnerPools.count }
            let matches = partnerPools[poolIndex].goodLooks(with: garment, ctx: lookContext, state: state, checkWeather: checkWeather)
            // Neither discounts nor learned positive bias can pass an item without an actual look.
            guard matches.count > 0 || planned != nil else { continue }
            let usefulness = max(matches.share, planned == nil ? 0 : 1)
            let owned = ownedCount(like: product, in: wardrobe)
            let rotationRate = rates[product.category] ?? 0
            let redundancy = min(0.5, Double(max(0, owned - 1)) * (rotationRate >= 5 ? 0.08 : 0.16)
                + input.feedbackSignals.recentPurchasePenalty(for: product))
            let discount = Double(product.discountPercent ?? 0) / 100
            let need = candidate.need?.priority ?? 0
            let prior = 0.42 * candidate.metrics.personal + 0.28 * usefulness + 0.15 * need
                + 0.08 * (planned == nil ? 0 : 1) - redundancy
                + 0.12 * candidate.reaction
            // The item must be worth recommending before its price earns any priority.
            guard prior >= 0.27 else { continue }
            let features = featureVector(taste: candidate.metrics.personal, looks: usefulness, need: need,
                discount: discount, redundancy: redundancy, product: product,
                metrics: candidate.metrics, planned: planned != nil, future: future, reaction: candidate.reaction)
            let score = (1 - learnedShare) * prior + learnedShare * input.model.predict(features)
                + searchBonus(product, profile: input.searchProfile)
                + usefulDealBoost(product, personal: candidate.metrics.personal, usefulness: usefulness,
                    need: need, redundancy: redundancy)

            var reasons: [Reason] = []
            if future { reasons.append(.nextSeasonDeal(nextSeason)) }
            else if let planned { reasons.append(.upcomingLook(planned.date, planned.isEvening)) }
            else if product.category == .accessory { reasons.append(.completesLook) }
            else if let gap = candidate.need { reasons.append(.fillsGap(gap.kind, gap.suggestion.category)) }
            else if rotationRate >= 3 && candidate.metrics.type > 0 { reasons.append(.everydayRotation) }
            if let percent = product.discountPercent { reasons.append(.onSale(percent)) }
            if let color = product.colors.first(where: { (affinity.colors[$0] ?? 0) >= 0.6 }), candidate.metrics.color >= 0.5 {
                reasons.append(.lovedColor(color))
            }
            if (input.searchProfile?.brandAffinity(for: product) ?? candidate.metrics.brand) >= 0.6,
               let brand = product.item.brand { reasons.append(.lovedBrand(brand)) }
            if (input.searchProfile?.styleAffinity(for: product) ?? candidate.metrics.style) >= 0.6 { reasons.append(.fitsStyle) }
            if matches.count >= 2 { reasons.append(.opensLooks(matches.count)) }
            if let type = product.itemType, candidate.metrics.type >= 0.5 { reasons.append(.wornType(type)) }
            if product.category != .accessory,
               let size = usualSizes[product.category],
               product.inStockSizes.contains(size) { reasons.append(.inYourSize(size)) }
            else if product.category != .accessory { reasons.append(.checkSize) }
            if owned >= 2, let type = product.itemType { reasons.append(.alreadyHave(owned, type)) }
            let preview = planned.map { LookPreview(ownedGarmentIDs: $0.owned.map(\.id), date: $0.date, isEvening: $0.isEvening) }
                ?? matches.best.map { LookPreview(ownedGarmentIDs: $0.map(\.id)) }
            if planned == nil { previewAlternatives[product.id] = matches.alternatives }
            // This is a wear-frequency heuristic, never a conversion prediction; future use is unknown.
            let wears = future ? nil : rates[product.category].map { $0 * (0.4 + min(1, max(0, prior))) }
            let wardrobeMatch = planned.map { ShoppingPartnerPool.score($0.owned + [garment], ctx: $0.context, state: state) } ?? matches.share
            picks.append(Pick(product: product, score: score, wearsPerMonth: wears, looks: matches.count,
                reasons: reasons, features: features, match: Match(taste: min(1, max(0, candidate.metrics.personal + 0.18 * candidate.reaction)),
                    wardrobe: wardrobeMatch, weather: checkWeather && !future ? TemperatureComfort.garmentScore(garment, context: lookContext) : nil,
                    signals: input.signalCount), intent: future ? .nextSeason : (planned == nil ? .everyday : .upcoming), preview: preview))
        }
        let ordered = picks.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        let clothes = ordered.filter { $0.product.category != .accessory }
        var result = diversified(clothes.filter { $0.intent != .nextSeason }, limit: limit)
        if input.includeNextSeasonDeals {
            result += clothes.filter { $0.intent == .nextSeason }.prefix(4)
        }
        // Keep eligible held picks and offers available to their own views, even if diversity
        // kept them outside the default selection. The deep pass still caps this pool at 70.
        let selected = Set(result.map(\.id))
        let held = Set(retainedIDs.prefix(20))
        result += clothes.filter { !selected.contains($0.id) && ($0.product.discountPercent != nil || held.contains($0.id)) }
        diversifyPreviewBottoms(in: &result, alternatives: previewAlternatives, wardrobe: wardrobe)
        let accessories = Array(ordered.filter { $0.product.category == .accessory }.prefix(10))
        addCompanions(to: &result, accessories: accessories, wardrobe: wardrobe, ctx: current.context, state: state, checkWeather: current.hasWeather)
        result += accessories
        return result
    }

    static func browseMatches(_ products: [ShopProduct], input: Input) -> [String: Match] {
        guard input.garments.count >= 5 else { return [:] }
        return browseMatches(productEvidence(products, input: input), input: input)
    }

    private static func productEvidence(_ products: [ShopProduct], input: Input) -> [String: ProductEvidence] {
        let affinity = Affinity(taste: input.taste, preferences: input.preferences)
        let shares = wornTypeShare(input.garments, wearCounts: input.wearCounts)
        var result: [String: ProductEvidence] = [:]
        result.reserveCapacity(products.count)
        for product in products {
            guard !Task.isCancelled else { return [:] }
            result[product.id] = ProductEvidence(metrics: affinity.metrics(product, typeShares: shares),
                reaction: input.feedbackSignals.score(for: product))
        }
        return result
    }

    private static func browseMatches(_ evidence: [String: ProductEvidence], input: Input) -> [String: Match] {
        guard input.garments.count >= 5 else { return [:] }
        return evidence.mapValues {
            Match(taste: min(1, max(0, $0.metrics.personal + 0.18 * $0.reaction)), signals: input.signalCount)
        }
    }

    private static func searchBonus(_ product: ShopProduct, profile: ShopSearchProfile?) -> Double {
        guard let profile else { return 0 }
        // These soft bonuses never admit an otherwise ineligible product or exclude a new brand.
        return 0.05 * profile.brandAffinity(for: product)
            + 0.035 * profile.styleAffinity(for: product)
            + 0.015 * profile.typeAffinity(for: product)
    }

    // MARK: - Taste and stock

    private struct Affinity {
        var colors: [ColorTag: Double]
        var brands: [String: Double]
        var styles: [StyleTag: Double]
        var fits: [FitTag: Double]
        var patterns: [PatternTag: Double]
        var avoidColors: [ColorTag: Double]
        var avoidBrands: [String: Double]
        init(taste: TasteAffinityBuilder.Profile, preferences: ShoppingPreferences) {
            colors = taste.colorAffinity; brands = taste.brandAffinity; styles = taste.styleAffinity
            fits = Self.normalized(taste.fitMass); patterns = Self.normalized(taste.patternMass)
            avoidColors = Self.normalized(taste.avoidColorMass); avoidBrands = Self.normalized(taste.avoidBrandMass)
            if !preferences.preferredColors.isEmpty {
                colors = colors.mapValues { $0 * 0.5 }
                for color in preferences.preferredColors { colors[color] = 1; avoidColors[color] = nil }
            }
            if !preferences.preferredBrands.isEmpty {
                brands = brands.mapValues { $0 * 0.5 }
                for brand in preferences.preferredBrands {
                    let key = BrandStore.normalizeBrandKey(brand)
                    brands[key] = 1; avoidBrands[key] = nil
                }
            }
            if !preferences.preferredStyles.isEmpty {
                styles = styles.mapValues { $0 * 0.5 }
                for style in preferences.preferredStyles { styles[style] = 1 }
            }
        }
        struct Metrics {
            var color, brand, style, type, fit, pattern, avoid: Double
            var personal: Double {
                max(0, 0.28 * color + 0.20 * brand + 0.18 * style + 0.16 * type + 0.10 * fit + 0.08 * pattern - 0.3 * avoid)
            }
            var evidence: Int { [color, brand, style, type, fit, pattern].filter { $0 >= 0.35 }.count }
        }
        func metrics(_ product: ShopProduct, typeShares: [ItemType: Double]) -> Metrics {
            let brand = product.item.brand.map(BrandStore.normalizeBrandKey) ?? ""
            let tags = product.styleTags
            let color = Self.mean(product.colors.map { max(0, (colors[$0] ?? 0) - 0.5 * (avoidColors[$0] ?? 0)) })
            return Metrics(color: color, brand: max(0, (brands[brand] ?? 0) - 0.5 * (avoidBrands[brand] ?? 0)),
                style: Self.mean(tags.map { styles[$0] ?? 0 }), type: min(1, (product.itemType.flatMap { typeShares[$0] } ?? 0) * 1.5),
                fit: product.fit.flatMap { fits[$0] } ?? 0, pattern: product.pattern.flatMap { patterns[$0] } ?? 0,
                avoid: max(Self.mean(product.colors.map { avoidColors[$0] ?? 0 }), avoidBrands[brand] ?? 0))
        }
        static func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        static func normalized<K: Hashable>(_ mass: [K: Double]) -> [K: Double] {
            let peak = mass.values.max() ?? 0
            return peak > 0 ? mass.mapValues { max(0, min(1, $0 / peak)) } : [:]
        }
    }

    private static func fitsUsualSize(_ product: ShopProduct, usualSize: SizeOption?) -> Bool {
        guard product.hasKnownSizeAvailability else { return true }
        guard !product.inStockSizes.isEmpty else { return false }
        // A belt's size is not a bag/watch/jewelry size; there is no category-wide usual accessory size.
        if product.category == .accessory { return true }
        guard let size = usualSize else { return true }
        return product.inStockSizes.contains(size)
    }

    static func transientGarment(for product: ShopProduct) -> Garment {
        let garment = Garment(category: product.category, itemType: product.itemType, brand: product.item.brand,
            colorTags: product.colors, materialTags: product.materials, patternTag: product.pattern, fitTag: product.fit)
        garment.aiEnrichedFieldsRaw = ItemTypeDefaults.apply(to: garment)
        if !product.styleTags.isEmpty { garment.styleTags = product.styleTags }
        return garment
    }

    private static func wornTypeShare(_ wardrobe: [Garment], wearCounts: [UUID: Int]) -> [ItemType: Double] {
        var mass: [ItemType: Double] = [:]
        var totals: [Category: Double] = [:]
        for garment in wardrobe {
            guard let type = garment.itemType else { continue }
            let value = Double(wearCounts[garment.id] ?? 0) + 0.25
            mass[type, default: 0] += value; totals[garment.category, default: 0] += value
        }
        var result: [ItemType: Double] = [:]
        for category in Category.allCases {
            for type in category.itemTypes where (totals[category] ?? 0) > 0 { result[type] = (mass[type] ?? 0) / totals[category]! }
        }
        return result
    }

    private static func monthlyWearRate(_ wardrobe: [Garment], wearCounts: [UUID: Int], windowDays: Int) -> [Category: Double] {
        var result: [Category: Double] = [:]
        for category in Category.allCases {
            let items = wardrobe.filter { $0.category == category }
            let wears = items.reduce(0) { $0 + (wearCounts[$1.id] ?? 0) }
            if !items.isEmpty, wears > 0 { result[category] = Double(wears) / Double(items.count) / max(1, Double(windowDays) / 30) }
        }
        return result
    }

    private static func bestGap(for product: ShopProduct, in gaps: [WardrobeGapAnalyzer.Gap]) -> WardrobeGapAnalyzer.Gap? {
        gaps.filter { gap in
            gap.suggestion.category == product.category && (gap.suggestion.itemType == nil
                || gap.suggestion.itemType == product.itemType || gap.kind == .thinRotation || gap.kind == .missingCore)
        }.max { $0.priority < $1.priority }
    }

    private static func ownedCount(like product: ShopProduct, in wardrobe: [Garment]) -> Int {
        wardrobe.filter { $0.itemType == product.itemType && !Set($0.safeColorTags).isDisjoint(with: product.colors) }.count
    }

    /// A meaningful, verified saving gets priority only in proportion to personal use.
    /// Deep eligibility is decided without this bonus; redundant purchases earn less of it.
    private static func usefulDealBoost(_ product: ShopProduct, personal: Double, usefulness: Double,
        need: Double, redundancy: Double) -> Double {
        guard let percent = product.discountPercent, percent >= 15, personal >= 0.4 else { return 0 }
        let saving = min(1, Double(percent) / 50)
        let fit = min(1, personal / 0.65)
        let use = min(1, max(usefulness, need))
        let novelty = max(0, 1 - redundancy / 0.5)
        return 0.16 * saving * fit * use * novelty
    }

    private static func featureVector(taste: Double, looks: Double, need: Double, discount: Double, redundancy: Double,
        product: ShopProduct, metrics: Affinity.Metrics, planned: Bool, future: Bool, reaction: Double) -> [Double] {
        var x = [taste, looks, need, discount, redundancy]
        x += Category.allCases.map { $0 == product.category ? 1.0 : 0.0 }
        let price = product.price ?? 0
        x.append(price > 0 ? min(1, log10(price) / 3) : 0)
        x += [metrics.color, metrics.brand, metrics.style, metrics.fit, metrics.pattern,
              planned ? 1 : 0, future ? 1 : 0, reaction, product.hasKnownSizeAvailability ? 1 : 0]
        return x
    }

    // MARK: - Actual weather and persisted planned looks

    private static func context(input: Input, temperature: Double, raining: Bool, date: Date? = nil,
        isEvening: Bool = false, formality: Int? = nil, samples: [ThermalWeatherSample] = []) -> RecoContext {
        RecoContext(desiredFormality: formality ?? Int(input.taste.formalityMean.rounded()), temperatureC: temperature,
            isRaining: raining, now: date ?? input.now, profileID: input.profile?.id,
            warmthSensitivity: input.profile?.warmthSensitivity ?? 3, rainTolerance: input.profile?.rainTolerance ?? 3,
            lookTime: isEvening ? .evening : .day, taste: input.taste, thermalSamples: samples, weatherHistory: input.comfort)
    }

    private static func currentContext(_ input: Input) -> (context: RecoContext, hasWeather: Bool) {
        let start = Calendar.current.startOfDay(for: input.now)
        let forecasts = input.forecasts.filter { $0.date >= start && $0.date < start.addingTimeInterval(7 * 86_400) && $0.temperatureC.isFinite }
        let forecast = forecasts.sorted { $0.temperatureC < $1.temperatureC }.dropFirst(forecasts.count / 2).first
        // The neutral context is only for palette/proportion scoring; never claim forecast suitability without weather.
        return (context(input: input, temperature: forecast?.temperatureC ?? 20, raining: forecast?.isRaining ?? false,
            samples: forecast?.thermalSamples(for: .day, now: input.now) ?? []), forecast != nil)
    }

    fileprivate static func weatherFit(_ garment: Garment, context: RecoContext, comfort: Double? = nil) -> Bool {
        guard let type = garment.itemType else { return false }
        if garment.category == .accessory, ![ItemType.hat, .cap, .scarf].contains(type) { return true }
        if garment.category == .outer, !TemperatureComfort.outerGarmentAllowed(garment, policy: context.outerLayerPolicy) { return false }
        if context.isRaining, garment.itemType == .sandals || garment.itemType == .slippers { return false }
        // Weather history can override an automatic season label, including shorts on cool days.
        return (comfort ?? TemperatureComfort.garmentScore(garment, context: context)) >= 0.4
    }

    fileprivate static func lookFitsWeather(_ garments: [Garment], context: RecoContext, comfort: [UUID: Double] = [:]) -> Bool {
        for garment in garments where garment.category != .top {
            if garment.itemType != nil && !weatherFit(garment, context: context, comfort: comfort[garment.id]) { return false }
        }
        // Tops may be a base under an outer layer; bottoms and shoes still need to suit the day.
        let hasOuter = garments.contains { $0.category == .outer }
        return garments.filter { $0.category == .top }.allSatisfy {
            $0.itemType == nil || weatherFit($0, context: context, comfort: comfort[$0.id]) || (hasOuter && context.temperatureC < 20)
        }
    }

    private struct PlannedLook {
        var owned: [Garment]
        var date: Date
        var isEvening: Bool
        var context: RecoContext
        var hasWeather: Bool
    }

    private static func plannedLooks(input: Input, wardrobe: [Garment]) -> [PlannedLook] {
        let byID = Dictionary(wardrobe.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [PlannedLook] = []
        for plan in input.upcomingPlans {
            let owned = plan.ids.compactMap { byID[$0] }.filter { !$0.isCurrentlyUnavailable }
            guard owned.count >= 2 else { continue }
            let formality = Int((owned.map { Double($0.formality) }.reduce(0, +) / Double(owned.count)).rounded())
            let ctx = context(input: input, temperature: plan.temperature ?? 20, raining: plan.raining,
                date: plan.date, isEvening: plan.isEvening, formality: formality)
            result.append(PlannedLook(owned: owned, date: plan.date, isEvening: plan.isEvening,
                context: ctx, hasWeather: plan.temperature != nil))
        }
        return Array(result.prefix(14))
    }

    private static func bestPlannedLook(for product: Garment, plans: [PlannedLook], state: RecoState, input: Input) -> PlannedLook? {
        var best: (PlannedLook, Double)?
        for plan in plans {
            guard !Task.isCancelled else { return nil }
            // Whole-look weather checks below evaluate a top together with its layer.
            if plan.hasWeather && product.category != .top && !weatherFit(product, context: plan.context) { continue }
            guard abs(Double(product.formality - plan.context.desiredFormality)) <= 2 else { continue }
            let retained = ShoppingPartnerPool.retainingCompatible(plan.owned, whenAdding: product)
            let combined = retained + [product]
            guard ShoppingPartnerPool.hasCore(combined) else { continue }
            if plan.hasWeather && !lookFitsWeather(combined, context: plan.context) { continue }
            let score = ShoppingPartnerPool.score(combined, ctx: plan.context, state: state)
            let baseline = ShoppingPartnerPool.score(plan.owned, ctx: plan.context, state: state)
            guard score >= 0.48, score >= baseline + 0.005 || !ShoppingPartnerPool.hasCore(plan.owned) else { continue }
            let value = score + (Calendar.current.isDate(plan.date, inSameDayAs: input.now) ? 0.02 : 0)
            if best == nil || value > best!.1 {
                best = (PlannedLook(owned: retained, date: plan.date, isEvening: plan.isEvening, context: plan.context, hasWeather: plan.hasWeather), value)
            }
        }
        return best?.0
    }

    /// Israel is the only catalog country. These broad seasons are opportunities, not forecasts.
    private static func nextSeason(after date: Date) -> SeasonSuitability {
        switch Calendar.current.component(.month, from: date) {
        case 12, 1, 2: return .transitional
        case 3...5: return .summer
        case 6...8: return .transitional
        default: return .winter
        }
    }
    private static func seasonalTemperature(_ season: SeasonSuitability) -> Double {
        switch season { case .winter: return 10; case .summer: return 27; case .transitional: return 18; case .allSeason: return 20 }
    }

    // MARK: - Useful two-purchase looks

    /// Rotate equally useful owned bottoms across the visible feed. Planned looks
    /// retain their actual assignments, and every alternative already passed weather/quality gates.
    private static func diversifyPreviewBottoms(in picks: inout [Pick], alternatives: [String: [[Garment]]], wardrobe: [Garment]) {
        let ownedIDs = Set(wardrobe.map(\.id))
        var uses: [UUID: Int] = [:]
        for index in picks.indices {
            guard var preview = picks[index].preview else { continue }
            if picks[index].intent != .upcoming, let options = alternatives[picks[index].id], !options.isEmpty {
                // Options are ordered by compatibility. Equal use counts keep that ordering.
                var chosen = options[0]
                var minimum = chosen.reduce(0) { $0 + uses[$1.id, default: 0] * ($1.category == .bottom ? 2 : 1) }
                for option in options.dropFirst() {
                    let count = option.reduce(0) { $0 + uses[$1.id, default: 0] * ($1.category == .bottom ? 2 : 1) }
                    if count < minimum { chosen = option; minimum = count }
                }
                preview.ownedGarmentIDs = chosen.map(\.id)
                picks[index].preview = preview
            }
            for id in preview.ownedGarmentIDs where ownedIDs.contains(id) { uses[id, default: 0] += 1 }
        }
    }

    private static func addCompanions(to picks: inout [Pick], accessories: [Pick], wardrobe: [Garment], ctx: RecoContext, state: RecoState, checkWeather: Bool) {
        let pool = accessories.filter { $0.intent == .everyday }
        var used = Set<String>()
        let byID = Dictionary(wardrobe.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in picks.indices.prefix(12) {
            guard index % 3 == 1, picks[index].intent == .everyday, var preview = picks[index].preview else { continue }
            let primary = transientGarment(for: picks[index].product)
            let owned = preview.ownedGarmentIDs.compactMap { byID[$0] }
            let single = ShoppingPartnerPool.score(owned + [primary], ctx: ctx, state: state)
            var best: (Pick, [Garment], Double)?
            for companion in pool where !used.contains(companion.id) && companion.id != picks[index].id && companion.product.category != primary.category {
                let needsPiece = companion.reasons.contains { reason in if case .fillsGap = reason { return true }; return false }
                let newAccessory = companion.product.category == .accessory && !wardrobe.contains { $0.itemType == companion.product.itemType }
                guard needsPiece || newAccessory else { continue }
                let extra = transientGarment(for: companion.product)
                if checkWeather && !weatherFit(extra, context: ctx) { continue }
                let retained = ShoppingPartnerPool.retainingCompatible(owned, whenAdding: extra)
                let look = retained + [primary, extra]
                guard ShoppingPartnerPool.hasCore(look) else { continue }
                if checkWeather && !lookFitsWeather(look, context: ctx) { continue }
                let score = ShoppingPartnerPool.score(look, ctx: ctx, state: state)
                // Compare both single-purchase alternatives: buying two must add something concrete.
                guard let companionPreview = companion.preview else { continue }
                let companionOwned = companionPreview.ownedGarmentIDs.compactMap { byID[$0] }
                let secondLook = companionOwned + [extra]
                guard ShoppingPartnerPool.hasCore(secondLook) else { continue }
                let secondOnly = ShoppingPartnerPool.score(secondLook, ctx: ctx, state: state)
                guard score >= max(single, secondOnly) + 0.015 else { continue }
                if best == nil || score > best!.2 { best = (companion, retained, score) }
            }
            if let best {
                var companion = best.0; companion.preview = nil
                used.insert(companion.id)
                preview.ownedGarmentIDs = best.1.map(\.id); preview.companions = [companion]
                picks[index].preview = preview
            }
        }
    }

    private static func diversified(_ sorted: [Pick], limit: Int) -> [Pick] {
        var remaining = sorted; var result: [Pick] = []; var counts: [String: Int] = [:]
        while !remaining.isEmpty && result.count < limit {
            func adjusted(_ pick: Pick) -> Double {
                pick.score * pow(0.85, Double(counts[pick.product.itemType?.rawValue ?? pick.product.category.rawValue] ?? 0))
            }
            // Variety chooses among similarly useful options; it cannot bury a much better
            // match or useful deal merely because its clothing type has appeared before.
            let bestScore = remaining.map(\.score).max() ?? 0
            let eligible = remaining.indices.filter { remaining[$0].score >= bestScore - 0.1 }
            guard let index = eligible.max(by: {
                let left = adjusted(remaining[$0]), right = adjusted(remaining[$1])
                return left == right ? remaining[$0].id > remaining[$1].id : left < right
            }) else { break }
            let pick = remaining.remove(at: index)
            counts[pick.product.itemType?.rawValue ?? pick.product.category.rawValue, default: 0] += 1
            result.append(pick)
        }
        return result
    }
}

// MARK: - Bounded owned-wardrobe look pool

private struct ShoppingPartnerPool {
    private var bySlot: [OutfitSlot: [Garment]] = [:]
    private var baselines: [Category: Double] = [:]
    private var coreLooks: [[Garment]] = []

    init(wardrobe: [Garment], wearCounts: [UUID: Int], ctx: RecoContext, state: RecoState, rotationOffset: Int) {
        for slot in [OutfitSlot.top, .bottom, .shoes, .outer, .onePiece] {
            let ranked = wardrobe.filter { slot.accepts($0) && !$0.isCurrentlyUnavailable }
                .sorted {
                    let left = log1p(Double(wearCounts[$0.id] ?? 0)) + Double($0.loveScore) / 100
                    let right = log1p(Double(wearCounts[$1.id] ?? 0)) + Double($1.loveScore) / 100
                    return left == right ? $0.id.uuidString < $1.id.uuidString : left > right
                }
            let suitable = ranked.filter { slot == .top || slot == .onePiece || PurchaseScorer.weatherFit($0, context: ctx) }
            let candidates = suitable.isEmpty ? ranked : suitable
            var chosen = Array(candidates.prefix(3))
            let others = Array(candidates.dropFirst(3))
            if !others.isEmpty {
                let day = Int(ctx.now.timeIntervalSince1970 / 86400)
                for offset in 0..<min(2, others.count) { chosen.append(others[(abs(day) + rotationOffset + offset) % others.count]) }
            }
            bySlot[slot] = chosen

        }
        coreLooks = combinations([.top, .bottom, .shoes].map { bySlot[$0] ?? [] })
            + combinations([.onePiece, .shoes].map { bySlot[$0] ?? [] })
        let comfort = Dictionary(bySlot.values.flatMap { $0 }.map {
            ($0.id, TemperatureComfort.garmentScore($0, context: ctx))
        }, uniquingKeysWith: { first, _ in first })
        let values = coreLooks.map { Self.score($0, ctx: ctx, state: state, comfort: comfort) }.sorted()
        if !values.isEmpty { for category in Category.allCases { baselines[category] = values[values.count / 2] } }
    }

    func goodLooks(with product: Garment, ctx: RecoContext, state: RecoState, checkWeather: Bool) -> (count: Int, share: Double, best: [Garment]?, alternatives: [[Garment]]) {
        let combos: [[Garment]]
        switch OutfitSlot.from(garment: product) {
        case .onePiece:
            combos = combinations([bySlot[.shoes] ?? []])
        case .top:
            combos = combinations([.bottom, .shoes].map { bySlot[$0] ?? [] })
        case .bottom:
            combos = combinations([.top, .shoes].map { bySlot[$0] ?? [] })
        case .shoes:
            combos = combinations([.top, .bottom].map { bySlot[$0] ?? [] })
                + (bySlot[.onePiece] ?? []).map { [$0] }
        default:
            combos = coreLooks
        }
        let baseline = baselines[product.category] ?? 0.48
        let comfort = Dictionary((bySlot.values.flatMap { $0 } + [product]).map {
            ($0.id, TemperatureComfort.garmentScore($0, context: ctx))
        }, uniquingKeysWith: { first, _ in first })
        var good = 0; var best: [Garment]?; var bestScore = -Double.infinity
        var qualifying: [(pieces: [Garment], score: Double)] = []
        for core in combos {
            if Task.isCancelled { break }
            var combo = core
            let needsLayer = ctx.temperatureC < 16 || (product.category == .top && !PurchaseScorer.weatherFit(product, context: ctx, comfort: comfort[product.id]))
            if checkWeather && needsLayer && product.category != .outer,
               let layer = bySlot[.outer]?.first(where: { PurchaseScorer.weatherFit($0, context: ctx) }) { combo.append(layer) }
            let look = combo + [product]
            guard Self.hasCore(look) else { continue }
            if checkWeather && !PurchaseScorer.lookFitsWeather(look, context: ctx, comfort: comfort) { continue }
            let score = Self.score(look, ctx: ctx, state: state, comfort: comfort)
            let original = product.category == .outer || product.category == .accessory ? Self.score(combo, ctx: ctx, state: state, comfort: comfort) : baseline
            guard score >= max(0.48, original - 0.005) else { continue }
            good += 1
            qualifying.append((combo, score))
            if score > bestScore { best = combo; bestScore = score }
        }
        let alternatives = qualifying.sorted(by: { $0.score > $1.score })
            .filter { $0.score >= bestScore - 0.06 }.map(\.pieces)
        return (good, combos.isEmpty ? 0 : Double(good) / Double(combos.count), best, alternatives)
    }

    static func hasCore(_ garments: [Garment]) -> Bool {
        guard Set(garments.map(\.id)).count == garments.count,
              garments.filter({ $0.category == .shoes }).count == 1 else { return false }
        let onePieces = garments.filter { $0.itemType?.isOnePiece == true }
        let tops = garments.filter { $0.category == .top && $0.itemType?.isOnePiece != true }
        let bottoms = garments.filter { $0.category == .bottom }
        return onePieces.count == 1 && tops.isEmpty && bottoms.isEmpty
            || onePieces.isEmpty && tops.count == 1 && bottoms.count == 1
    }

    /// Shopping previews are transient: replace the relevant silhouette rather
    /// than combining a dress/jumpsuit with the planned shirt and trousers.
    static func retainingCompatible(_ garments: [Garment], whenAdding product: Garment) -> [Garment] {
        let slot = OutfitSlot.from(garment: product)
        return garments.filter { garment in
            let existing = OutfitSlot.from(garment: garment)
            if slot.isAccessory {
                return !(existing.isAccessory && garment.itemType == product.itemType)
            }
            return existing != slot && !slot.conflictingSlots.contains(existing)
        }
    }

    static func score(_ garments: [Garment], ctx: RecoContext, state: RecoState, comfort: [UUID: Double] = [:]) -> Double {
        // Blend compatibility with comfort so marginal-weather favorites do not
        // keep winning every preview. Eligibility is checked separately.
        AIRecommender.shared.lookScore(garments: garments, itemScores: garments.map { 0.45 + 0.25 * (comfort[$0.id] ?? TemperatureComfort.garmentScore($0, context: ctx)) }, ctx: ctx, state: state).score
    }

    private func combinations(_ lists: [[Garment]]) -> [[Garment]] {
        lists.reduce([[]]) { partial, list in partial.flatMap { combo in list.map { combo + [$0] } } }
    }
}
