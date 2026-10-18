// Personal shopping stays on the device. A sale can improve a useful recommendation;
// it cannot make an unrelated product relevant or turn a score into a purchase probability.
import Foundation
import SwiftData

@MainActor
enum PurchaseScorer {
    struct Input {
        var garments: [Garment]
        var wearCounts: [UUID: Int]
        var windowDays: Int = 90
        var taste: TasteAffinityBuilder.Profile
        var gaps: [WardrobeGapAnalyzer.Gap]
        var profile: UserProfile?
        var model: ShopPreferenceModel
        var modelContext: ModelContext
        var now = Date()
        var forecasts: [DayForecast] = []
        var upcomingPlans: [DayPlan] = []
        var includeNextSeasonDeals = false
        var feedbackSignals: ShopFeedbackStore.Signals = .empty
        var preferences = ShoppingPreferences()
        var department: ShopDepartment? = nil
    }

    enum Reason: Hashable {
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

    enum Intent { case everyday, upcoming, nextSeason }

    struct LookPreview {
        var ownedGarmentIDs: [UUID]
        var date: Date? = nil
        var isEvening = false
        /// At most one extra purchase. Every companion passed the same personal/stock gates.
        var companions: [Pick] = []
    }

    struct Pick: Identifiable {
        let product: ShopProduct
        let score: Double
        let wearsPerMonth: Double?
        let looks: Int
        let reasons: [Reason]
        /// Existing positions are preserved; new features are appended.
        let features: [Double]
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

    static func rank(_ products: [ShopProduct], input: Input, isHidden: (String) -> Bool, limit: Int = 40) -> [Pick] {
        let wardrobe = input.garments.filter { !$0.isBlocked && ($0.ownerID == nil || input.profile == nil || $0.ownerID == input.profile?.id) }
        guard !wardrobe.isEmpty, limit > 0 else { return [] }
        let shares = wornTypeShare(wardrobe, wearCounts: input.wearCounts)
        let affinity = Affinity(taste: input.taste, preferences: input.preferences)
        let categoryCounts = Dictionary(grouping: wardrobe, by: \.category).mapValues(\.count)
        var usualSizes: [Category: SizeOption] = [:]
        for category in [Category.top, .bottom, .shoes, .outer] {
            usualSizes[category] = MySizesView.usualSize(for: category, profile: input.profile, garments: wardrobe)
        }
        let candidates: [Candidate] = products.compactMap { product in
            guard product.item.available != false, product.itemType != nil, product.itemType != .other, !isHidden(product.id),
                  (input.department ?? .automatic).includes(product.audience, category: product.category),
                  fitsUsualSize(product, usualSize: usualSizes[product.category]) else { return nil }
            let metrics = affinity.metrics(product, typeShares: shares)
            let need = bestGap(for: product, in: input.gaps)
            let reaction = input.feedbackSignals.score(for: product)
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
                + 0.06 * Double(product.discountPercent ?? 0) / 100
            return Candidate(product: product, metrics: metrics, need: need, reaction: reaction, quickScore: quick)
        }
        let sorted = candidates.sorted { $0.quickScore == $1.quickScore ? $0.product.id < $1.product.id : $0.quickScore > $1.quickScore }
        // Leave room for accessories and personally relevant offers before the expensive look pass.
        var shortlist: [Candidate] = []
        var seen = Set<String>()
        func append(_ pool: [Candidate], count: Int) {
            for candidate in pool.prefix(count) where seen.insert(candidate.product.id).inserted { shortlist.append(candidate) }
        }
        append(sorted.filter { $0.product.category == .accessory }, count: 10)
        append(sorted.filter { $0.product.discountPercent != nil }, count: 15)
        append(sorted, count: deepPoolSize)
        shortlist = Array(shortlist.prefix(deepPoolSize))

        let current = currentContext(input)
        let nextSeason = nextSeason(after: input.now)
        let state = AIRecommender.shared.ensureState(context: input.modelContext, profileID: input.profile?.id)
        let partners = ShoppingPartnerPool(wardrobe: wardrobe, wearCounts: input.wearCounts, ctx: current.context, state: state)
        let plans = plannedLooks(input: input, wardrobe: wardrobe)
        let rates = monthlyWearRate(wardrobe, wearCounts: input.wearCounts, windowDays: input.windowDays)
        // Learning adjusts ordering; the structural relevance and usefulness gates stay in charge.
        let learnedShare = 0.25 * min(1, Double(input.model.interactions) / 40)
        var picks: [Pick] = []
        var previewAlternatives: [String: [[Garment]]] = [:]

        for candidate in shortlist {
            let product = candidate.product
            let garment = transientGarment(for: product)
            let nowFits = !current.hasWeather || weatherFit(garment, context: current.context)
            let planned = bestPlannedLook(for: garment, plans: plans, state: state, input: input)
            let future = !nowFits && planned == nil && input.includeNextSeasonDeals && garment.seasonSuitability == nextSeason
                && (product.discountPercent ?? 0) >= 30 && candidate.metrics.personal >= 0.45
            guard nowFits || future || planned != nil else { continue }
            let lookContext = planned?.context ?? (future ? context(input: input, temperature: seasonalTemperature(nextSeason), raining: false) : current.context)
            let checkWeather = planned?.hasWeather ?? (future || current.hasWeather)
            let matches = partners.goodLooks(with: garment, ctx: lookContext, state: state, checkWeather: checkWeather)
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
                + 0.08 * (planned == nil ? 0 : 1) + 0.07 * discount - redundancy
                + 0.12 * candidate.reaction
            let features = featureVector(taste: candidate.metrics.personal, looks: usefulness, need: need,
                discount: discount, redundancy: redundancy, product: product,
                metrics: candidate.metrics, planned: planned != nil, future: future, reaction: candidate.reaction)
            let score = (1 - learnedShare) * prior + learnedShare * input.model.predict(features)
            guard prior >= 0.27 else { continue }

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
            if candidate.metrics.brand >= 0.6, let brand = product.item.brand { reasons.append(.lovedBrand(brand)) }
            if candidate.metrics.style >= 0.6 { reasons.append(.fitsStyle) }
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
            picks.append(Pick(product: product, score: score, wearsPerMonth: wears, looks: matches.count,
                reasons: reasons, features: features, intent: future ? .nextSeason : (planned == nil ? .everyday : .upcoming), preview: preview))
        }
        let ordered = picks.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        var result = diversified(ordered.filter { $0.intent != .nextSeason }, limit: limit)
        if input.includeNextSeasonDeals {
            let seasonal = Array(ordered.filter { $0.intent == .nextSeason }.prefix(min(2, max(1, limit / 4))))
            result = Array(result.prefix(max(0, limit - seasonal.count))) + seasonal
        }
        diversifyPreviewBottoms(in: &result, alternatives: previewAlternatives, wardrobe: wardrobe)
        addCompanions(to: &result, wardrobe: wardrobe, ctx: current.context, state: state, checkWeather: current.hasWeather)
        return result
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
        ItemTypeDefaults.apply(to: garment)
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
            lookTime: isEvening ? .evening : .day, taste: input.taste, thermalSamples: samples)
    }

    private static func currentContext(_ input: Input) -> (context: RecoContext, hasWeather: Bool) {
        let start = Calendar.current.startOfDay(for: input.now)
        let forecasts = input.forecasts.filter { $0.date >= start && $0.date < start.addingTimeInterval(7 * 86_400) && $0.temperatureC.isFinite }
        let forecast = forecasts.sorted { $0.date < $1.date }.first
        // The neutral context is only for palette/proportion scoring; never claim forecast suitability without weather.
        return (context(input: input, temperature: forecast?.temperatureC ?? 20, raining: forecast?.isRaining ?? false,
            samples: forecast?.thermalSamples(for: .day, now: input.now) ?? []), forecast != nil)
    }

    fileprivate static func weatherFit(_ garment: Garment, context: RecoContext) -> Bool {
        guard let type = garment.itemType else { return false }
        if garment.category == .accessory, ![ItemType.hat, .cap, .scarf].contains(type) { return true }
        if garment.category == .outer, !TemperatureComfort.outerGarmentAllowed(garment, policy: context.outerLayerPolicy) { return false }
        if context.isRaining, garment.itemType == .sandals || garment.itemType == .slippers { return false }
        return TemperatureComfort.garmentScore(garment, context: context) >= 0.4
            && (garment.seasonSuitability == nil || TemperatureComfort.seasonMatch(season: garment.seasonSuitability, temperatureC: context.temperatureC) >= 0.4)
    }

    fileprivate static func lookFitsWeather(_ garments: [Garment], context: RecoContext) -> Bool {
        for garment in garments where garment.category != .top {
            if garment.itemType != nil && !weatherFit(garment, context: context) { return false }
        }
        // Tops may be a base under an outer layer; bottoms and shoes still need to suit the day.
        let hasOuter = garments.contains { $0.category == .outer }
        return garments.filter { $0.category == .top }.allSatisfy {
            $0.itemType == nil || weatherFit($0, context: context) || (hasOuter && context.temperatureC < 20)
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
        let start = Calendar.current.startOfDay(for: input.now)
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start
        let byID = Dictionary(wardrobe.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [PlannedLook] = []
        for plan in input.upcomingPlans.sorted(by: { $0.date < $1.date }) where plan.date >= start && plan.date < end
            && (plan.ownerID == nil || input.profile == nil || plan.ownerID == input.profile?.id) {
            for evening in [false, true] {
                if evening && plan.eveningEnabled != true { continue }
                let status = evening ? plan.eveningLookWearStatus : plan.resolvedDayLookWearStatus
                if status == .worn || status == .notWorn { continue }
                let assignments = evening ? plan.eveningSlotAssignments : plan.slotAssignments
                let ids = assignments.isEmpty && !evening ? plan.selectedGarmentIDs : OutfitSlot.allCases.compactMap { assignments[$0] }
                var seen = Set<UUID>()
                let owned = ids.filter { seen.insert($0).inserted }.compactMap { byID[$0] }.filter { !$0.isCurrentlyUnavailable }
                guard owned.count >= 2 else { continue }
                let forecast = input.forecasts.first { Calendar.current.isDate($0.date, inSameDayAs: plan.date) }
                let persistedTemp = evening ? plan.contextEveningTemp : plan.contextAfternoonTemp
                let savedTemps = [plan.contextTempHigh, plan.contextTempLow].compactMap { $0 }.filter(\.isFinite)
                let savedMean = savedTemps.isEmpty ? nil : savedTemps.reduce(0, +) / Double(savedTemps.count)
                let temperature = persistedTemp.flatMap { $0.isFinite ? $0 : nil } ?? savedMean ?? forecast?.temperatureC
                let hasWeather = temperature?.isFinite == true
                let formality = Int((owned.map { Double($0.formality) }.reduce(0, +) / Double(owned.count)).rounded())
                let ctx = context(input: input, temperature: hasWeather ? temperature! : 20,
                    raining: plan.contextWasRaining ?? forecast?.isRaining ?? false, date: plan.date, isEvening: evening,
                    formality: formality)
                result.append(PlannedLook(owned: owned, date: plan.date, isEvening: evening, context: ctx, hasWeather: hasWeather))
            }
        }
        return Array(result.prefix(14))
    }

    private static func bestPlannedLook(for product: Garment, plans: [PlannedLook], state: RecoState, input: Input) -> PlannedLook? {
        var best: (PlannedLook, Double)?
        for plan in plans {
            if plan.hasWeather && !weatherFit(product, context: plan.context) { continue }
            guard abs(Double(product.formality - plan.context.desiredFormality)) <= 2 else { continue }
            let retained = plan.owned.filter { $0.category != product.category }
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
        let bottoms = Set(wardrobe.filter { $0.category == .bottom }.map(\.id))
        var uses: [UUID: Int] = [:]
        for index in picks.indices {
            guard var preview = picks[index].preview else { continue }
            if picks[index].intent != .upcoming, let options = alternatives[picks[index].id], !options.isEmpty {
                // Options are ordered by compatibility. Equal use counts keep that ordering.
                var chosen = options[0]
                var minimum = chosen.first(where: { $0.category == .bottom }).map { uses[$0.id, default: 0] } ?? 0
                for option in options.dropFirst() {
                    let count = option.first(where: { $0.category == .bottom }).map { uses[$0.id, default: 0] } ?? 0
                    if count < minimum { chosen = option; minimum = count }
                }
                preview.ownedGarmentIDs = chosen.map(\.id)
                picks[index].preview = preview
            }
            for id in preview.ownedGarmentIDs where bottoms.contains(id) { uses[id, default: 0] += 1 }
        }
    }

    private static func addCompanions(to picks: inout [Pick], wardrobe: [Garment], ctx: RecoContext, state: RecoState, checkWeather: Bool) {
        let pool = Array(picks.filter { $0.intent == .everyday }.prefix(16))
        let byID = Dictionary(wardrobe.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in picks.indices.prefix(12) {
            guard picks[index].intent == .everyday, var preview = picks[index].preview else { continue }
            let primary = transientGarment(for: picks[index].product)
            let owned = preview.ownedGarmentIDs.compactMap { byID[$0] }
            let single = ShoppingPartnerPool.score(owned + [primary], ctx: ctx, state: state)
            var best: (Pick, [Garment], Double)?
            for companion in pool where companion.id != picks[index].id && companion.product.category != primary.category {
                let needsPiece = companion.reasons.contains { reason in if case .fillsGap = reason { return true }; return false }
                let newAccessory = companion.product.category == .accessory && !wardrobe.contains { $0.itemType == companion.product.itemType }
                guard needsPiece || newAccessory else { continue }
                let extra = transientGarment(for: companion.product)
                if checkWeather && !weatherFit(extra, context: ctx) { continue }
                let retained = owned.filter { $0.category != extra.category }
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
            guard let index = remaining.indices.max(by: { adjusted(remaining[$0]) < adjusted(remaining[$1]) }) else { break }
            let pick = remaining.remove(at: index)
            counts[pick.product.itemType?.rawValue ?? pick.product.category.rawValue, default: 0] += 1
            result.append(pick)
        }
        return result
    }
}

// MARK: - Bounded owned-wardrobe look pool

@MainActor
private struct ShoppingPartnerPool {
    private var byCategory: [Category: [Garment]] = [:]
    private var baselines: [Category: Double] = [:]
    private var coreLooks: [[Garment]] = []

    init(wardrobe: [Garment], wearCounts: [UUID: Int], ctx: RecoContext, state: RecoState) {
        for category in [Category.top, .bottom, .shoes, .outer] {
            byCategory[category] = Array(wardrobe.filter { $0.category == category && !$0.isCurrentlyUnavailable }
                .sorted {
                    let left = Double(wearCounts[$0.id] ?? 0) + Double($0.loveScore) / 100
                    let right = Double(wearCounts[$1.id] ?? 0) + Double($1.loveScore) / 100
                    return left == right ? $0.id.uuidString < $1.id.uuidString : left > right
                }.prefix(4))
        }
        coreLooks = combinations([.top, .bottom, .shoes].map { byCategory[$0] ?? [] })
        let values = coreLooks.map { Self.score($0, ctx: ctx, state: state) }.sorted()
        if !values.isEmpty { for category in Category.allCases { baselines[category] = values[values.count / 2] } }
    }

    func goodLooks(with product: Garment, ctx: RecoContext, state: RecoState, checkWeather: Bool) -> (count: Int, share: Double, best: [Garment]?, alternatives: [[Garment]]) {
        let slots: [Category] = [.top, .bottom, .shoes]
        let combos = product.category == .outer || product.category == .accessory
            ? coreLooks : combinations(slots.filter { $0 != product.category }.map { byCategory[$0] ?? [] })
        let baseline = baselines[product.category] ?? 0.48
        var good = 0; var best: [Garment]?; var bestScore = -Double.infinity
        var qualifying: [(pieces: [Garment], score: Double)] = []
        for core in combos {
            var combo = core
            if checkWeather && ctx.temperatureC < 16 && product.category != .outer,
               let layer = byCategory[.outer]?.first(where: { PurchaseScorer.weatherFit($0, context: ctx) }) { combo.append(layer) }
            let look = combo + [product]
            guard Self.hasCore(look) else { continue }
            if checkWeather && !PurchaseScorer.lookFitsWeather(look, context: ctx) { continue }
            let score = Self.score(look, ctx: ctx, state: state)
            let original = product.category == .outer || product.category == .accessory ? Self.score(combo, ctx: ctx, state: state) : baseline
            guard score >= max(0.48, original - 0.005) else { continue }
            good += 1
            qualifying.append((combo, score))
            if score > bestScore { best = combo; bestScore = score }
        }
        var seenBottoms = Set<UUID>()
        var alternatives: [[Garment]] = []
        for option in qualifying.sorted(by: { $0.score > $1.score }) where option.score >= bestScore - 0.04 {
            if let bottom = option.pieces.first(where: { $0.category == .bottom }) {
                guard seenBottoms.insert(bottom.id).inserted else { continue }
            } else if !alternatives.isEmpty { continue }
            alternatives.append(option.pieces)
        }
        return (good, combos.isEmpty ? 0 : Double(good) / Double(combos.count), best, alternatives)
    }

    static func hasCore(_ garments: [Garment]) -> Bool {
        [Category.top, .bottom, .shoes].allSatisfy { category in garments.contains { $0.category == category } }
    }

    static func score(_ garments: [Garment], ctx: RecoContext, state: RecoState) -> Double {
        // Equal piece scores isolate palette, silhouette and learned whole-look taste.
        // Weather is a separate gate; lookScore alone does not evaluate it.
        AIRecommender.shared.lookScore(garments: garments, itemScores: Array(repeating: 0.6, count: garments.count), ctx: ctx, state: state).score
    }

    private func combinations(_ lists: [[Garment]]) -> [[Garment]] {
        lists.reduce([[]]) { partial, list in partial.flatMap { combo in list.map { combo + [$0] } } }
    }
}
