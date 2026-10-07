import Foundation

/// Finds needs in the user's life that the wardrobe does not cover yet
/// ("rain is coming and no shoe handles it", "a formal event and no formal shoes").
/// Deterministic and on-device: no network, no model calls, cheap enough to run
/// whenever Stats opens. Every gap carries the evidence that triggered it so the
/// UI can explain itself, and a suggestion shaped by the user's taste.
enum WardrobeGapAnalyzer {

    // MARK: - Input

    /// Weather the user actually lives in: upcoming forecast + past planning context.
    struct ClimateEvidence: Equatable {
        var upcomingDays = 0
        var upcomingRainyDays = 0
        var upcomingColdDays = 0
        var upcomingHotDays = 0
        /// In-between days (cool morning or evening, mild day): light-jacket weather.
        var upcomingMildDays = 0
        /// Past context samples (from feedback events), used when the forecast is quiet.
        var pastSamples = 0
        var pastRainyShare = 0.0
        var pastColdShare = 0.0
        var pastHotShare = 0.0
        var pastMildShare = 0.0

        static let rainProbabilityThreshold = 0.5
        static let coldThresholdC = 10.0
        static let hotThresholdC = 28.0
        /// A day is "mild" when it reaches this but starts or ends below `mildLowBelowC`.
        static let mildHighFromC = 18.0
        static let mildLowBelowC = 20.0
        /// Past samples in this range count as light-jacket weather.
        static let mildPastRange: Range<Double> = 15..<24
        /// Below this many past samples, history alone never triggers a gap.
        static let minPastSamples = 8
    }

    struct Input {
        var garments: [Garment]
        /// Wear count per garment inside the analysis window (calendar blocks excluded).
        var wearCounts: [UUID: Int] = [:]
        /// Distinct days with at least one wear in the window.
        var wearDays = 0
        var climate = ClimateEvidence()
        /// Upcoming calendar days that call for a formal look.
        var upcomingFormalDays = 0
        /// Share of past plans that asked for formality >= 4 (0...1).
        var pastFormalShare = 0.0
        var taste: TasteAffinityBuilder.Profile = .empty
        var now = Date()
        /// Also flag categories too thin to rotate (Stats and the planner turn this on).
        var checksRotation = false
    }

    // MARK: - Output

    enum Kind: String, CaseIterable {
        case missingCore
        case rainShoes
        case rainOuter
        case warmOuter
        case hotWeatherTops
        case formalTop
        case formalBottom
        case formalShoes
        case workhorseBackup
        /// Light jacket / overshirt for in-between days and to layer over short sleeves.
        case lightLayer
        /// So few items in a category that the planner keeps repeating them.
        case thinRotation
    }

    /// Why the gap was raised. The view layer turns this into localized text.
    enum Reason: Equatable {
        case noItemsInCategory(Category)
        case upcomingRain(days: Int)
        case rainyClimate(share: Double)
        case upcomingCold(days: Int)
        case coldClimate(share: Double)
        case upcomingHeat(days: Int)
        case hotClimate(share: Double)
        case upcomingFormal(days: Int)
        case formalHabit(share: Double)
        /// One item carries a large share of all wear days and has no alternative.
        case heavyRotation(garmentID: UUID, share: Double)
        case upcomingMild(days: Int)
        case mildClimate(share: Double)
        /// `have` usable items where about `target` keep a week of looks fresh.
        case thinRotation(category: Category, have: Int, target: Int)
    }

    struct Suggestion: Equatable {
        var category: Category
        var itemType: ItemType?
        var colors: [ColorTag]
        var fit: FitTag?
        var formality: Int?
        var weatherTags: [WeatherSuitability] = []
        /// Display name of the user's strongest brand in this category, if any.
        var brandName: String?
    }

    struct Gap: Identifiable, Equatable {
        var kind: Kind
        /// For `missingCore` / `workhorseBackup` the target varies, so it joins the id.
        var target: String = ""
        var reason: Reason
        var suggestion: Suggestion
        /// 0...1, higher is more urgent.
        var priority: Double

        var id: String { target.isEmpty ? kind.rawValue : "\(kind.rawValue):\(target)" }
    }

    // MARK: - Analysis

    static let minWardrobeSize = 5

    static func analyze(_ input: Input) -> [Gap] {
        let usable = input.garments.filter { !$0.isBlocked }
        // A near-empty wardrobe is onboarding, not a gap to shop for.
        guard usable.count >= minWardrobeSize else { return [] }

        var gaps: [Gap] = []
        gaps += coreGaps(usable, input: input)
        if let gap = rainShoesGap(usable, input: input) { gaps.append(gap) }
        if let gap = rainOuterGap(usable, input: input) { gaps.append(gap) }
        if let gap = warmOuterGap(usable, input: input) { gaps.append(gap) }
        if let gap = hotWeatherGap(usable, input: input) { gaps.append(gap) }
        gaps += formalGaps(usable, input: input)
        gaps += workhorseGaps(usable, input: input)
        if let gap = lightLayerGap(usable, input: input) { gaps.append(gap) }
        gaps += thinRotationGaps(usable, input: input)

        return gaps.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Rules

    private static let coreCategories: [Category] = [.top, .bottom, .shoes]

    private static func coreGaps(_ garments: [Garment], input: Input) -> [Gap] {
        coreCategories.compactMap { category -> Gap? in
            guard !garments.contains(where: { $0.category == category }) else { return nil }
            return Gap(
                kind: .missingCore,
                target: category.rawValue,
                reason: .noItemsInCategory(category),
                suggestion: makeSuggestion(
                    category: category,
                    itemType: defaultItemType(for: category),
                    garments: garments,
                    taste: input.taste,
                    preferNeutral: true
                ),
                priority: 1.0
            )
        }
    }

    private static func rainShoesGap(_ garments: [Garment], input: Input) -> Gap? {
        guard let reason = rainReason(input.climate) else { return nil }
        let covered = garments.contains { garment in
            garment.category == .shoes && (isWaterResistant(garment) || garment.itemType == .boots)
        }
        guard !covered else { return nil }
        var suggestion = makeSuggestion(
            category: .shoes,
            itemType: .boots,
            garments: garments,
            taste: input.taste,
            preferNeutral: true
        )
        suggestion.weatherTags = [.waterproof]
        return Gap(kind: .rainShoes, reason: reason, suggestion: suggestion, priority: urgency(reason, base: 0.75))
    }

    private static func rainOuterGap(_ garments: [Garment], input: Input) -> Gap? {
        guard let reason = rainReason(input.climate) else { return nil }
        let rainTypes: Set<ItemType> = [.raincoat, .parka, .windbreaker]
        let covered = garments.contains { garment in
            garment.category == .outer
                && (isWaterResistant(garment) || garment.itemType.map { rainTypes.contains($0) } == true)
        }
        guard !covered else { return nil }
        var suggestion = makeSuggestion(
            category: .outer,
            itemType: .raincoat,
            garments: garments,
            taste: input.taste,
            preferNeutral: true
        )
        suggestion.weatherTags = [.waterproof]
        return Gap(kind: .rainOuter, reason: reason, suggestion: suggestion, priority: urgency(reason, base: 0.7))
    }

    private static func warmOuterGap(_ garments: [Garment], input: Input) -> Gap? {
        let climate = input.climate
        let reason: Reason
        if climate.upcomingColdDays > 0 {
            reason = .upcomingCold(days: climate.upcomingColdDays)
        } else if climate.pastSamples >= ClimateEvidence.minPastSamples, climate.pastColdShare >= 0.15 {
            reason = .coldClimate(share: climate.pastColdShare)
        } else {
            return nil
        }
        let covered = garments.contains { $0.category == .outer && effectiveWarmth($0) >= 4 }
        guard !covered else { return nil }
        var suggestion = makeSuggestion(
            category: .outer,
            itemType: .coat,
            garments: garments,
            taste: input.taste,
            preferNeutral: true
        )
        suggestion.weatherTags = [.insulated]
        return Gap(kind: .warmOuter, reason: reason, suggestion: suggestion, priority: urgency(reason, base: 0.75))
    }

    /// Hot climates wear through light tops fast; fewer than three is a real gap.
    static let minHotWeatherTops = 3

    private static func hotWeatherGap(_ garments: [Garment], input: Input) -> Gap? {
        let climate = input.climate
        let reason: Reason
        if climate.upcomingHotDays > 0 {
            reason = .upcomingHeat(days: climate.upcomingHotDays)
        } else if climate.pastSamples >= ClimateEvidence.minPastSamples, climate.pastHotShare >= 0.2 {
            reason = .hotClimate(share: climate.pastHotShare)
        } else {
            return nil
        }
        let lightTops = garments.filter { $0.category == .top && effectiveWarmth($0) <= 2 }
        guard lightTops.count < minHotWeatherTops else { return nil }
        var suggestion = makeSuggestion(
            category: .top,
            itemType: .tshirt,
            garments: garments,
            taste: input.taste,
            preferNeutral: false
        )
        suggestion.weatherTags = [.breathable]
        let missingShare = Double(minHotWeatherTops - lightTops.count) / Double(minHotWeatherTops)
        return Gap(
            kind: .hotWeatherTops,
            reason: reason,
            suggestion: suggestion,
            priority: urgency(reason, base: 0.45 + 0.2 * missingShare)
        )
    }

    static let formalThreshold = 4

    private static func formalGaps(_ garments: [Garment], input: Input) -> [Gap] {
        let reason: Reason
        if input.upcomingFormalDays > 0 {
            reason = .upcomingFormal(days: input.upcomingFormalDays)
        } else if input.pastFormalShare >= 0.15 {
            reason = .formalHabit(share: input.pastFormalShare)
        } else {
            return []
        }

        let slots: [(Kind, Category, ItemType)] = [
            (.formalTop, .top, .shirt),
            (.formalBottom, .bottom, .trousers),
            (.formalShoes, .shoes, .oxfords)
        ]
        return slots.compactMap { entry -> Gap? in
            let (kind, category, itemType) = entry
            let covered = garments.contains {
                $0.category == category && $0.formality >= formalThreshold
            }
            guard !covered else { return nil }
            var suggestion = makeSuggestion(
                category: category,
                itemType: itemType,
                garments: garments,
                taste: input.taste,
                preferNeutral: true
            )
            suggestion.formality = formalThreshold
            return Gap(kind: kind, reason: reason, suggestion: suggestion, priority: urgency(reason, base: 0.7))
        }
    }

    /// An item worn on at least this share of wear days is a workhorse.
    static let workhorseShare = 0.35
    /// Minimum wear days before rotation share means anything.
    static let workhorseMinDays = 10

    private static func workhorseGaps(_ garments: [Garment], input: Input) -> [Gap] {
        guard input.wearDays >= workhorseMinDays else { return [] }
        return garments.compactMap { garment -> Gap? in
            let count = input.wearCounts[garment.id] ?? 0
            let share = Double(count) / Double(input.wearDays)
            guard share >= workhorseShare else { return nil }
            // Accessories (watch, belt) are meant to be worn daily.
            guard garment.category != .accessory else { return nil }
            let hasAlternative = garments.contains { other in
                other.id != garment.id
                    && other.category == garment.category
                    && (garment.itemType == nil || other.itemType == garment.itemType)
                    && abs(other.formality - garment.formality) <= 1
            }
            guard !hasAlternative else { return nil }
            var suggestion = makeSuggestion(
                category: garment.category,
                itemType: garment.itemType,
                garments: garments,
                taste: input.taste,
                preferNeutral: false
            )
            // A backup should work the same way as the original, so lead with its colors.
            let ownColors = garment.safeColorTags.filter { $0 != .multicolor }
            if !ownColors.isEmpty {
                suggestion.colors = Array((ownColors + suggestion.colors).uniqued().prefix(3))
            }
            suggestion.fit = garment.fitTag ?? suggestion.fit
            suggestion.formality = garment.formality
            return Gap(
                kind: .workhorseBackup,
                target: garment.id.uuidString,
                reason: .heavyRotation(garmentID: garment.id, share: share),
                suggestion: suggestion,
                priority: min(0.8, 0.35 + share * 0.5)
            )
        }
    }

    private static func lightLayerGap(_ garments: [Garment], input: Input) -> Gap? {
        let climate = input.climate
        let reason: Reason
        if climate.upcomingMildDays > 0 {
            reason = .upcomingMild(days: climate.upcomingMildDays)
        } else if climate.pastSamples >= ClimateEvidence.minPastSamples, climate.pastMildShare >= 0.25 {
            reason = .mildClimate(share: climate.pastMildShare)
        } else {
            return nil
        }
        let covered = garments.contains {
            $0.category == .outer && !$0.isCurrentlyUnavailable
                && $0.recommendationWarmth <= AIRecommender.styleLayerMaxWarmth
        }
        guard !covered else { return nil }
        let suggestion = makeSuggestion(
            category: .outer,
            itemType: .jacket,
            garments: garments,
            taste: input.taste,
            preferNeutral: true
        )
        return Gap(kind: .lightLayer, reason: reason, suggestion: suggestion, priority: urgency(reason, base: 0.55))
    }

    /// About a week of looks without repeating: the planner rotates through these.
    static let rotationTargets: [Category: Int] = [.top: 7, .bottom: 4, .shoes: 3]

    /// Usable items per category against its rotation target (the wardrobe at a glance).
    struct Coverage: Identifiable, Equatable {
        var category: Category
        var have: Int
        var target: Int
        var id: String { category.rawValue }
        var isShort: Bool { have < target }
    }

    static func coverage(_ garments: [Garment]) -> [Coverage] {
        let usable = garments.filter { !$0.isBlocked && !$0.isCurrentlyUnavailable }
        return [Category.top, .bottom, .shoes].map { category in
            Coverage(
                category: category,
                have: usable.filter { $0.category == category }.count,
                target: rotationTargets[category] ?? 0
            )
        }
    }

    private static func thinRotationGaps(_ garments: [Garment], input: Input) -> [Gap] {
        guard input.checksRotation else { return [] }
        return coverage(garments).compactMap { row -> Gap? in
            // Zero items is `missingCore`.
            guard row.have > 0, row.isShort else { return nil }
            // The type the user owns most in this category is the safest next buy.
            let types = garments.filter { $0.category == row.category }.compactMap(\.itemType)
            let commonType = Dictionary(grouping: types, by: { $0 })
                .max { $0.value.count < $1.value.count }?.key
            let suggestion = makeSuggestion(
                category: row.category,
                itemType: commonType ?? defaultItemType(for: row.category),
                garments: garments,
                taste: input.taste,
                preferNeutral: row.category != .top
            )
            let missingShare = Double(row.target - row.have) / Double(row.target)
            return Gap(
                kind: .thinRotation,
                target: row.category.rawValue,
                reason: .thinRotation(category: row.category, have: row.have, target: row.target),
                suggestion: suggestion,
                priority: 0.4 + 0.35 * missingShare
            )
        }
    }

    // MARK: - Evidence helpers

    private static func rainReason(_ climate: ClimateEvidence) -> Reason? {
        if climate.upcomingRainyDays > 0 {
            return .upcomingRain(days: climate.upcomingRainyDays)
        }
        if climate.pastSamples >= ClimateEvidence.minPastSamples, climate.pastRainyShare >= 0.15 {
            return .rainyClimate(share: climate.pastRainyShare)
        }
        return nil
    }

    /// Upcoming evidence is more urgent than a habit seen in history.
    private static func urgency(_ reason: Reason, base: Double) -> Double {
        switch reason {
        case .upcomingRain(let days), .upcomingCold(let days),
             .upcomingHeat(let days), .upcomingFormal(let days), .upcomingMild(let days):
            return min(1, base + 0.05 * Double(min(days, 4)))
        default:
            return base * 0.8
        }
    }

    static func isWaterResistant(_ garment: Garment) -> Bool {
        let tags = garment.weatherTags ?? []
        return tags.contains(.waterproof) || tags.contains(.rainFriendly)
    }

    static func effectiveWarmth(_ garment: Garment) -> Int {
        garment.thermalWarmthOverride ?? garment.warmth
    }

    // MARK: - Suggestion shaping

    private static let neutralColors: Set<ColorTag> = [
        .black, .white, .gray, .navy, .beige, .brown, .olive, .cream, .denim
    ]

    private static func defaultItemType(for category: Category) -> ItemType? {
        switch category {
        case .top: return .tshirt
        case .bottom: return .jeans
        case .shoes: return .sneakers
        case .outer: return .jacket
        case .accessory: return nil
        }
    }

    private static func makeSuggestion(
        category: Category,
        itemType: ItemType?,
        garments: [Garment],
        taste: TasteAffinityBuilder.Profile,
        preferNeutral: Bool
    ) -> Suggestion {
        Suggestion(
            category: category,
            itemType: itemType,
            colors: suggestedColors(taste: taste, preferNeutral: preferNeutral),
            fit: taste.fitShares(limit: 1).first?.tag,
            formality: nil,
            brandName: preferredBrandName(in: category, garments: garments, taste: taste)
        )
    }

    /// The user's favourite colors minus the ones they avoid. Workhorse pieces
    /// (shoes, coats) lean neutral so they match the rest of the wardrobe.
    static func suggestedColors(taste: TasteAffinityBuilder.Profile, preferNeutral: Bool) -> [ColorTag] {
        let avoided = Set(taste.avoidColorShares(limit: 5).map(\.tag))
        let liked = taste.colorShares(limit: 8)
            .map(\.tag)
            .filter { !avoided.contains($0) && $0 != .multicolor }
        let ranked = preferNeutral
            ? liked.filter(neutralColors.contains) + liked.filter { !neutralColors.contains($0) }
            : liked
        let picked = Array(ranked.prefix(3))
        if !picked.isEmpty { return picked }
        return preferNeutral ? [.black, .navy] : []
    }

    private static func preferredBrandName(
        in category: Category,
        garments: [Garment],
        taste: TasteAffinityBuilder.Profile
    ) -> String? {
        var namesByKey: [String: String] = [:]
        for garment in garments where garment.category == category {
            guard let brand = garment.brand?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !brand.isEmpty else { continue }
            let key = BrandStore.normalizeBrandKey(brand)
            if namesByKey[key] == nil { namesByKey[key] = brand }
        }
        let avoided = Set(taste.avoidBrandShares(limit: 5).map(\.key))
        for row in taste.brandShares(limit: 8) where !avoided.contains(row.key) {
            if let name = namesByKey[row.key] { return name }
        }
        return nil
    }
}

// MARK: - Evidence building

extension WardrobeGapAnalyzer {
    /// Wear counts and distinct wear days inside `windowDays`, ignoring calendar blocks.
    static func wearSummary(
        events: [WearEvent],
        windowDays: Int = 90,
        now: Date = Date()
    ) -> (counts: [UUID: Int], days: Int) {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -windowDays, to: now) ?? now
        var counts: [UUID: Int] = [:]
        var days = Set<Date>()
        for event in events where event.source != .calendarBlock && event.date >= cutoff {
            let day = calendar.startOfDay(for: event.date)
            days.insert(day)
            for id in Set(event.garmentIDs) {
                counts[id, default: 0] += 1
            }
        }
        return (counts, days.count)
    }

    /// Past climate from the context saved with each feedback event.
    static func climate(
        forecasts: [DayForecast],
        pastEvents: [RecommendationEvent]
    ) -> ClimateEvidence {
        var climate = ClimateEvidence()
        climate.upcomingDays = forecasts.count
        for day in forecasts {
            if day.rainProbability >= ClimateEvidence.rainProbabilityThreshold {
                climate.upcomingRainyDays += 1
            }
            if day.lowTempC <= ClimateEvidence.coldThresholdC {
                climate.upcomingColdDays += 1
            }
            if day.highTempC >= ClimateEvidence.hotThresholdC {
                climate.upcomingHotDays += 1
            }
            if day.highTempC >= ClimateEvidence.mildHighFromC,
               day.highTempC < ClimateEvidence.hotThresholdC,
               day.lowTempC < ClimateEvidence.mildLowBelowC {
                climate.upcomingMildDays += 1
            }
        }

        // One sample per plan/day so a burst of feedback on one day doesn't dominate.
        var samples: [String: (temp: Double, rain: Bool)] = [:]
        for event in pastEvents {
            let key = event.dayPlanID?.uuidString
                ?? String(Int(Calendar.current.startOfDay(for: event.createdAt).timeIntervalSince1970))
            samples[key] = (event.temperatureC, event.wasRaining)
        }
        let values = Array(samples.values)
        climate.pastSamples = values.count
        if !values.isEmpty {
            let total = Double(values.count)
            climate.pastRainyShare = Double(values.filter { $0.rain }.count) / total
            climate.pastColdShare = Double(values.filter { $0.temp <= ClimateEvidence.coldThresholdC }.count) / total
            climate.pastHotShare = Double(values.filter { $0.temp >= ClimateEvidence.hotThresholdC }.count) / total
            climate.pastMildShare = Double(values.filter { ClimateEvidence.mildPastRange.contains($0.temp) }.count) / total
        }
        return climate
    }

    static func pastFormalShare(_ events: [RecommendationEvent]) -> Double {
        guard !events.isEmpty else { return 0 }
        let formal = events.filter { $0.desiredFormality >= formalThreshold }.count
        return Double(formal) / Double(events.count)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
