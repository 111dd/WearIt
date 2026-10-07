import Foundation
import SwiftData
import CoreGraphics

//
//  AIRecommender.swift
//  WearIt
//
//  Improved for MVP stability:
//  - No randomness by default (epsilon = 0)
//  - Uses rain/temperature context features
//  - Stable ranking (no shuffling)
//  - Per-item learning with negative sampling
//  - Cold-start heuristics

// MARK: - SwiftData Model State

@Model final class RecoState {
    var id: String = "global"
    /// 2 = original feature set; 3 = + color/brand affinity features;
    /// 4 = + weekday/weekend formality features; 5 = + look-level (Look DNA) weights
    static let currentVersion = 5
    var version: Int = 3
    var profileID: UUID?
    var weights: [Double] = []
    var bias: Double = 0.0
    var epsilon: Double = 0.0      // exploration rate (0 = stable, 0.1 = some exploration)
    var lr: Double = 0.08          // learning rate
    var learnedWarmthOffset: Double = 0.0
    var learnedFormalityOffset: Double = 0.0
    
    /// Track how many times user has given feedback. Optional for migration compatibility.
    var totalInteractions: Int?

    /// Look-level preference weights over `LookDNA.vector` (v5). Empty until the
    /// first look signal; padded/truncated to `LookDNA.vectorSize` on use.
    var lookWeights: [Double] = []
    var lookBias: Double = 0.0
    /// Number of look-level signals (swipes, rated/worn looks). Optional for migration.
    var lookInteractions: Int?

    init(size: Int, profileID: UUID? = nil) {
        self.id = profileID.map { "profile-\($0.uuidString)" } ?? "global"
        self.version = RecoState.currentVersion
        self.profileID = profileID
        self.weights = Array(repeating: 0.0, count: size)
        self.bias = 0.0
        self.epsilon = 0.0   // MVP: No randomness by default
        self.lr = 0.08
        self.learnedWarmthOffset = 0
        self.learnedFormalityOffset = 0
        self.totalInteractions = 0
    }
    
    /// Safe accessor that defaults to 0 if nil (for migrated records)
    var interactionCount: Int {
        get { totalInteractions ?? 0 }
        set { totalInteractions = newValue }
    }

    var lookInteractionCount: Int {
        get { lookInteractions ?? 0 }
        set { lookInteractions = newValue }
    }
}

// MARK: - Feature Space

enum FeatureSpace {
    // Categories (one-hot encoded)
    static let categories: [Category] = Category.allCases
    static let catCount = categories.count

    // Feature indices
    static let iCatStart = 0
    static let iCatEnd   = iCatStart + catCount

    // Core features
    static let iWarmthMatch   = iCatEnd          // how well warmth matches temperature
    static let iFormalMatch   = iWarmthMatch + 1 // how well formality matches desired
    static let iLove          = iFormalMatch + 1 // love score 0..1
    static let iRecency       = iLove + 1        // days since worn (normalized)
    
    // Context features (NEW)
    static let iIsRaining     = iRecency + 1     // 1 if raining, 0 otherwise
    static let iTempCold      = iIsRaining + 1   // 1 if temp < 10°C
    static let iTempMild      = iTempCold + 1    // 1 if 10-20°C
    static let iTempWarm      = iTempMild + 1    // 1 if 20-28°C
    static let iTempHot       = iTempWarm + 1    // 1 if > 28°C
    
    // Category-context interactions (NEW)
    static let iOuterInCold   = iTempHot + 1     // outer + cold weather
    static let iShoesInRain   = iOuterInCold + 1 // shoes + rain
    
    // Cold-start helpers
    static let iNeverWorn     = iShoesInRain + 1 // never been worn (boost new items)
    static let iFavorite      = iNeverWorn + 1   // is favorite
    static let iTempInRange   = iFavorite + 1    // explicit temperature suitability
    static let iWarmthTaste   = iTempInRange + 1 // explicit profile warmth preference
    static let iRainTaste     = iWarmthTaste + 1 // explicit rain avoidance preference
    static let iEvening       = iRainTaste + 1   // evening look context

    // Taste affinities (v3) — appended so older RecoState weights migrate by zero-pad
    static let iColorAffinity = iEvening + 1     // 0..1 from wardrobe color taste
    static let iBrandAffinity = iColorAffinity + 1 // 0..1 from wardrobe brand taste

    // Routine (v4): formality split by weekday vs weekend, so the model can learn
    // "dressier on workdays, casual on weekends" per garment.
    static let iWeekdayFormality = iBrandAffinity + 1
    static let iWeekendFormality = iWeekdayFormality + 1

    static let total          = iWeekendFormality + 1
}

// MARK: - Recommendation Context

struct RecoContext {
    let desiredFormality: Int
    let temperatureC: Double
    let isRaining: Bool
    let now: Date
    let profileID: UUID?
    let warmthSensitivity: Int
    let rainTolerance: Int
    let lookTime: LookTime
    /// Soft wardrobe-derived taste. Empty maps → affinity features stay 0 (neutral).
    let taste: TasteAffinityBuilder.Profile
    /// Soft co-wear / dismissed pair affinities.
    let combination: CombinationAffinity
    /// Calendar-derived occasion (wedding, sport, work…).
    let occasionKind: CalendarOccasionKind
    /// Optional morning→evening temps for smarter layering decisions.
    let diurnal: DiurnalTemps?
    let thermalSamples: [ThermalWeatherSample]
    let allowRepeatedItems: Bool
    /// What the user actually wears per occasion (learned from tagged wear history).
    let occasionStyle: OccasionStyleProfile
    /// The occasion to look up in `occasionStyle`. Unlike `occasionKind`, a free
    /// dress-code work day stays `.work` so the user's own work look is learned.
    let habitOccasion: CalendarOccasionKind
    /// The user's answer for this day ("short with a jacket" / "long" / "short").
    let layerChoice: DayLayerChoice?
    /// Learned temperature from which the user wears short sleeves.
    let shortSleeveFromC: Double?

    init(
        desiredFormality: Int,
        temperatureC: Double,
        isRaining: Bool,
        now: Date,
        profileID: UUID? = nil,
        warmthSensitivity: Int = 3,
        rainTolerance: Int = 3,
        lookTime: LookTime = .day,
        taste: TasteAffinityBuilder.Profile = .empty,
        combination: CombinationAffinity = .empty,
        occasionKind: CalendarOccasionKind = .none,
        diurnal: DiurnalTemps? = nil,
        thermalSamples: [ThermalWeatherSample] = [],
        allowRepeatedItems: Bool = false,
        occasionStyle: OccasionStyleProfile = .empty,
        habitOccasion: CalendarOccasionKind? = nil,
        layerChoice: DayLayerChoice? = nil,
        shortSleeveFromC: Double? = nil
    ) {
        self.desiredFormality = min(max(desiredFormality, 1), 5)
        self.temperatureC = temperatureC
        self.isRaining = isRaining
        self.now = now
        self.profileID = profileID
        self.warmthSensitivity = min(max(warmthSensitivity, 1), 5)
        self.rainTolerance = min(max(rainTolerance, 1), 5)
        self.lookTime = lookTime
        self.taste = taste
        self.combination = combination
        self.occasionKind = occasionKind
        self.diurnal = diurnal
        self.thermalSamples = thermalSamples
        self.allowRepeatedItems = allowRepeatedItems
        self.occasionStyle = occasionStyle
        self.habitOccasion = habitOccasion ?? occasionKind
        self.layerChoice = layerChoice
        self.shortSleeveFromC = shortSleeveFromC
    }
    
    // Temperature bucket helpers
    var isCold: Bool { temperatureC < 10 }
    var isMild: Bool { temperatureC >= 10 && temperatureC < 20 }
    var isWarm: Bool { temperatureC >= 20 && temperatureC < 28 }
    var isHot: Bool { temperatureC >= 28 }

    /// Dry-weather cutoff: at/above this temp, heavy outer layers are not recommended.
    static let outerLayerTempThresholdC: Double = 20

    var outerLayerPolicy: OuterLayerPolicy {
        let policy = TemperatureComfort.outerLayerPolicy(
            temperatureC: temperatureC,
            isRaining: isRaining,
            lookTime: lookTime,
            diurnal: diurnal
        )
        // The day's answer is about the daytime look; evenings keep their own call.
        return lookTime == .day
            ? ComfortPreferences.adjusted(policy, choice: layerChoice, isRaining: isRaining)
            : policy
    }

    /// True when an outer layer is appropriate (cool weather, rain, or light packable).
    var prefersOuterLayer: Bool {
        switch outerLayerPolicy {
        case .prefer: return true
        case .lightOnly, .suppress: return false
        }
    }

    /// True when outer layers should be fully suppressed.
    var suppressesOuterLayer: Bool {
        outerLayerPolicy == .suppress
    }

    /// True when only light/packable outers should be considered.
    var prefersLightOuterOnly: Bool {
        outerLayerPolicy == .lightOnly
    }

    var targetWarmth: Double {
        TemperatureComfort.targetWarmth(
            temperatureC: temperatureC,
            warmthTaste: warmthTaste
        )
    }

    var warmthTaste: Double {
        Double(warmthSensitivity - 3) / 2.0
    }

    var rainAvoidance: Double {
        Double(rainTolerance - 1) / 4.0
    }

    /// Locale-aware weekend (Fri/Sat in Israel, Sat/Sun elsewhere).
    var isWeekend: Bool {
        Calendar.current.isDateInWeekend(now)
    }
}

// MARK: - AI Recommender

final class AIRecommender {
    static let shared = AIRecommender()
    private init() {}

    // MARK: - State Management

    /// Resolved states are memoized per profile: scoring loops (suggest / score /
    /// OutfitChangeAdvisor) call `ensureState` many times per pass, and a full
    /// SwiftData fetch each time was measurable main-thread churn.
    /// Lock-guarded because tests may exercise the singleton concurrently.
    private let stateCacheLock = NSLock()
    private var cachedStates: [String: RecoState] = [:]

    private func stateCacheKey(profileID: UUID?) -> String {
        profileID.map { "profile-\($0.uuidString)" } ?? "global"
    }

    func ensureState(context: ModelContext, profileID: UUID? = nil) -> RecoState {
        let cacheKey = stateCacheKey(profileID: profileID)
        stateCacheLock.lock()
        let cached = cachedStates[cacheKey]
        stateCacheLock.unlock()
        // profileID must still match: legacy-global adoption re-keys a state in
        // place, which would otherwise leave a stale entry under "global".
        if let cached,
           !cached.isDeleted,
           cached.modelContext === context,
           cached.profileID == profileID {
            return cached
        }

        let state = fetchOrCreateState(context: context, profileID: profileID)
        stateCacheLock.lock()
        cachedStates[cacheKey] = state
        stateCacheLock.unlock()
        return state
    }

    private func fetchOrCreateState(context: ModelContext, profileID: UUID?) -> RecoState {
        let states = (try? context.fetch(FetchDescriptor<RecoState>())) ?? []

        if let matching = states.first(where: { $0.profileID == profileID && (profileID != nil || $0.id == "global") }) {
            migrateStateIfNeeded(matching)
            return matching
        }

        if let profileID,
           let legacy = states.first(where: { $0.profileID == nil && $0.id == "global" }) {
            legacy.profileID = profileID
            legacy.id = "profile-\(profileID.uuidString)"
            migrateStateIfNeeded(legacy)
            try? context.save()
            return legacy
        }

        let st = RecoState(size: FeatureSpace.total, profileID: profileID)
        context.insert(st)
        try? context.save()
        return st
    }

    private func migrateStateIfNeeded(_ state: RecoState) {
        if state.weights.count < FeatureSpace.total {
            state.weights.append(contentsOf: repeatElement(0.0, count: FeatureSpace.total - state.weights.count))
        } else if state.weights.count > FeatureSpace.total {
            state.weights = Array(state.weights.prefix(FeatureSpace.total))
        }
        state.version = RecoState.currentVersion
    }

    // MARK: - Feature Extraction

    func features(for g: Garment, ctx: RecoContext) -> [Double] {
        features(for: g, ctx: ctx, warmthOffset: 0, formalityOffset: 0)
    }

    private func features(
        for g: Garment,
        ctx: RecoContext,
        warmthOffset: Double,
        formalityOffset: Double
    ) -> [Double] {
        var x = Array(repeating: 0.0, count: FeatureSpace.total)

        // 1) One-hot category
        if let idx = FeatureSpace.categories.firstIndex(of: g.category) {
            x[FeatureSpace.iCatStart + idx] = 1.0
        }

        // 2) Warmth match (based on temperature)
        x[FeatureSpace.iWarmthMatch] = TemperatureComfort.garmentScore(g, context: ctx, warmthOffset: warmthOffset)

        // 3) Formality match
        let targetFormality = min(max(Double(ctx.desiredFormality) + formalityOffset, 1), 5)
        let formalDelta = abs(Double(g.formality) - targetFormality)
        x[FeatureSpace.iFormalMatch] = max(0, 1.0 - formalDelta / 4.0)

        // 4) Love score
        x[FeatureSpace.iLove] = Double(g.loveScore) / 100.0

        // 5) Recency (prefer items not worn recently)
        let days: Double
        if let last = g.lastWorn {
            days = max(0, ctx.now.timeIntervalSince(last) / 86400.0)
        } else {
            days = 30 // Never worn = high recency
        }
        x[FeatureSpace.iRecency] = min(1.0, days / 14.0)

        // 6) Context: Rain
        x[FeatureSpace.iIsRaining] = ctx.isRaining ? 1.0 : 0.0

        // 7) Context: Temperature buckets
        x[FeatureSpace.iTempCold] = ctx.isCold ? 1.0 : 0.0
        x[FeatureSpace.iTempMild] = ctx.isMild ? 1.0 : 0.0
        x[FeatureSpace.iTempWarm] = ctx.isWarm ? 1.0 : 0.0
        x[FeatureSpace.iTempHot]  = ctx.isHot ? 1.0 : 0.0

        // 8) Category-context interactions
        // Outer in cold weather
        if g.category == .outer && ctx.isCold {
            x[FeatureSpace.iOuterInCold] = 1.0
        }
        // Shoes in rain (penalize formal shoes)
        if g.category == .shoes && ctx.isRaining && g.formality >= 4 {
            x[FeatureSpace.iShoesInRain] = -(0.5 + ctx.rainAvoidance)
        }

        // 9) Cold-start helpers
        x[FeatureSpace.iNeverWorn] = (g.lastWorn == nil) ? 1.0 : 0.0
        x[FeatureSpace.iFavorite] = g.isFavorite ? 1.0 : 0.0
        
        // 10) Temperature suitability (using garment's temp range)
        let tempRange = g.effectiveTempRange
        let rangeScore = TemperatureComfort.tempRangeScore(
            temperatureC: ctx.temperatureC,
            range: tempRange
        )
        x[FeatureSpace.iTempInRange] = rangeScore
        if rangeScore < 1.0 {
            x[FeatureSpace.iWarmthMatch] -= (1.0 - rangeScore) * 0.35
        }

        // 11) Explicit user-context interactions. These vary per garment, so the
        // linear model can learn useful ranking differences within one request.
        let normalizedGarmentWarmth = Double(g.recommendationWarmth - 3) / 2.0
        x[FeatureSpace.iWarmthTaste] = ctx.warmthTaste * normalizedGarmentWarmth

        let rainTags = Set(g.weatherTags ?? [])
        let isRainReady = rainTags.contains(.rainFriendly) || rainTags.contains(.waterproof)
        if ctx.isRaining, isRainReady {
            x[FeatureSpace.iRainTaste] = 0.5 + ctx.rainAvoidance
        }

        if ctx.lookTime == .evening {
            x[FeatureSpace.iEvening] = Double(g.formality - 1) / 4.0
        }

        // 12) Taste affinities (color / brand) — 0 when taste profile is empty
        x[FeatureSpace.iColorAffinity] = ctx.taste.colorScore(for: g)
        x[FeatureSpace.iBrandAffinity] = ctx.taste.brandScore(for: g)

        // 13) Routine: centered formality, routed to the weekday or weekend slot
        let centeredFormality = Double(g.formality - 3) / 2.0
        if ctx.isWeekend {
            x[FeatureSpace.iWeekendFormality] = centeredFormality
        } else {
            x[FeatureSpace.iWeekdayFormality] = centeredFormality
        }

        return x
    }

    // MARK: - Scoring

    private func modelScore(w: [Double], b: Double, x: [Double]) -> Double {
        var s = b
        for i in 0..<min(w.count, x.count) {
            s += w[i] * x[i]
        }
        // Sigmoid to 0..1
        return 1.0 / (1.0 + exp(-s))
    }

    private func similarityBonus(for g: Garment, among garments: [Garment]) -> Double {
        // Only apply to new items (never worn or recently added)
        if g.lastWorn != nil { return 0 }
        if let created = g.createdAt, created < Date().addingTimeInterval(-14 * 86400) {
            return 0
        }

        let colors = Set(g.safeColorTags)
        let styles = Set(g.styleTags ?? [])
        var bestScore: Double = 0

        for other in garments where other.id != g.id {
            var sim: Double = 0

            if other.category == g.category { sim += 0.4 }
            if let itemType = g.itemType, itemType == other.itemType { sim += 0.25 }

            let otherColors = Set(other.safeColorTags)
            if !colors.isEmpty || !otherColors.isEmpty {
                let overlap = colors.intersection(otherColors).count
                let union = colors.union(otherColors).count
                if union > 0 {
                    sim += 0.2 * (Double(overlap) / Double(union))
                }
            }

            if let s1 = g.seasonSuitability, let s2 = other.seasonSuitability {
                if s1 == s2 || s1 == .allSeason || s2 == .allSeason {
                    sim += 0.1
                }
            }

            if !styles.isEmpty, let otherStyles = other.styleTags {
                let overlap = styles.intersection(otherStyles).count
                let union = styles.union(otherStyles).count
                if union > 0 {
                    sim += 0.05 * (Double(overlap) / Double(union))
                }
            }

            // When on-device visual prints exist, how alike the photos look
            // counts as much as matching tags.
            if other.category == g.category,
               let visual = GarmentVisualSimilarity.shared.similarity(g.id, other.id) {
                sim = 0.5 * sim + 0.5 * visual
            }

            let love = Double(other.loveScore) / 100.0
            let preference = min(1.0, love + (other.isFavorite ? 0.3 : 0))
            let blended = sim * (0.5 + preference * 0.5)

            bestScore = max(bestScore, blended)
        }

        // Cap bonus to keep risk low
        return min(0.12, bestScore * 0.12)
    }

    /// Cold-start heuristic score (used when model has few interactions)
    private func heuristicScore(
        for g: Garment,
        ctx: RecoContext,
        warmthOffset: Double,
        formalityOffset: Double
    ) -> Double {
        var score = 0.5
        
        // Temperature suitability (primary signal)
        let tempRange = g.effectiveTempRange
        let rangeScore = TemperatureComfort.tempRangeScore(
            temperatureC: ctx.temperatureC,
            range: tempRange
        )
        score += (rangeScore - 0.5) * 0.5  // in-range ≈ +0.25, far out ≈ −0.25
        
        // Warmth match (secondary) — asymmetric in heat/cold
        let warmthMatch = TemperatureComfort.garmentScore(g, context: ctx, warmthOffset: warmthOffset)
        score += warmthMatch * 0.15

        // Soft season prior when tagged
        let seasonScore = TemperatureComfort.seasonMatch(
            season: g.seasonSuitability,
            temperatureC: ctx.temperatureC
        )
        if seasonScore > 0 {
            score += seasonScore * 0.06
        }
        
        // Formality match
        let targetFormality = min(max(Double(ctx.desiredFormality) + formalityOffset, 1), 5)
        let formalMatch = 1.0 - abs(Double(g.formality) - targetFormality) / 4.0
        score += formalMatch * 0.1
        
        // Love score boost
        score += (Double(g.loveScore) / 100.0) * 0.1
        
        // Recency boost (haven't worn in a while — stronger after ~3 weeks)
        if g.lastWorn == nil {
            score += 0.12
        } else if let last = g.lastWorn {
            let days = ctx.now.timeIntervalSince(last) / 86400.0
            if days >= 21 {
                score += min(0.14, 0.06 + (days - 21) / 120.0)
            } else {
                score += min(0.08, days / 140.0)
            }
        }
        
        // Favorite boost
        if g.isFavorite {
            score += 0.05
        }
        
        // Rain penalty for formal shoes
        if ctx.isRaining && g.category == .shoes && g.formality >= 4 {
            score -= 0.15 * (0.5 + ctx.rainAvoidance)
        }

        // Prefer explicitly rain-ready pieces when the user cares about staying dry.
        let rainTags = Set(g.weatherTags ?? [])
        if ctx.isRaining,
           rainTags.contains(.rainFriendly) || rainTags.contains(.waterproof) {
            score += 0.08 * (0.5 + ctx.rainAvoidance)
        }
        
        // Cold weather: boost outer
        if ctx.isCold && g.category == .outer {
            score += 0.1
        }

        // Outer-layer policy: suppress / light-only / prefer
        if g.category == .outer {
            switch ctx.outerLayerPolicy {
            case .suppress:
                score -= ctx.isHot ? 0.35 : 0.28
            case .lightOnly:
                if !TemperatureComfort.isLightLayer(g) {
                    score -= 0.3
                } else if g.recommendationWarmth <= 2 {
                    score += 0.06
                } else {
                    // A regular jacket (warmth 3) is the usual light layer.
                    score += 0.03
                }
            case .prefer:
                if g.recommendationWarmth >= 4, ctx.temperatureC >= 16 {
                    score -= 0.08
                }
            }
        }

        // Soft taste priors from wardrobe history (safe when affinities are empty)
        let colorAffinity = ctx.taste.colorScore(for: g)
        if colorAffinity > 0 {
            score += colorAffinity * 0.08
        }
        let brandAffinity = ctx.taste.brandScore(for: g)
        if brandAffinity > 0 {
            score += brandAffinity * 0.06
        }
        let styleAffinity = ctx.taste.styleScore(for: g)
        if styleAffinity > 0 {
            score += styleAffinity * 0.05
        }
        let materialAffinity = ctx.taste.materialScore(for: g)
        if materialAffinity > 0 {
            score += materialAffinity * 0.03
        }
        let fitAffinity = ctx.taste.fitScore(for: g)
        if fitAffinity > 0 {
            score += fitAffinity * 0.03
        }

        // Occasion priors from calendar context
        switch ctx.occasionKind {
        case .sport:
            if g.formality <= 2 { score += 0.08 }
            if g.category == .shoes, (g.itemType == .sneakers || g.itemType == .slippers) {
                score += 0.05
            }
            if g.category == .outer, g.formality >= 4 { score -= 0.08 }
        case .work:
            if g.formality >= 3 { score += 0.05 }
        case .formal, .blackTie, .holiday, .shabbat:
            if g.formality >= 4 { score += 0.06 }
            if ctx.occasionKind == .blackTie, g.formality >= 4 { score += 0.04 }
        case .travel:
            if g.fitTag == .relaxed || g.fitTag == .oversized { score += 0.03 }
        case .outdoor:
            if g.category == .outer { score += 0.04 }
        case .mourning:
            if g.formality >= 3 { score += 0.05 }
        case .socialEvening, .socialDay, .none:
            break
        }

        return max(0, min(1, score))
    }

    /// Combined score blending heuristics and learned model
    private func combinedScore(g: Garment, ctx: RecoContext, state: RecoState) -> Double {
        let x = features(
            for: g,
            ctx: ctx,
            warmthOffset: state.learnedWarmthOffset,
            formalityOffset: state.learnedFormalityOffset
        )
        let learned = modelScore(w: state.weights, b: state.bias, x: x)
        let heuristic = heuristicScore(
            for: g,
            ctx: ctx,
            warmthOffset: state.learnedWarmthOffset,
            formalityOffset: state.learnedFormalityOffset
        )
        
        // Blend based on interaction count
        // More interactions = trust learned model more
        let interactionWeight = min(1.0, Double(state.interactionCount) / 20.0)
        
        // Start with 80% heuristic, gradually shift to 80% learned
        let learnedWeight = 0.2 + (interactionWeight * 0.6)
        let heuristicWeight = 1.0 - learnedWeight
        
        let blended = (learned * learnedWeight) + (heuristic * heuristicWeight)
        return max(0, min(1, blended + occasionFit(g, ctx: ctx) + sleeveFit(g, ctx: ctx)))
    }

    /// Calendar occasion fit that doesn't fade as the model learns: the learned
    /// model has no occasion features, so a workout look needs workout clothes
    /// and a funeral needs muted colors no matter how much was learned.
    private func occasionFit(_ g: Garment, ctx: RecoContext) -> Double {
        // The user's own habit for this occasion gradually takes over from the rules.
        let habitConfidence = ctx.occasionStyle.confidence(for: ctx.habitOccasion)
        let habit = ctx.occasionStyle.fit(g, occasion: ctx.habitOccasion)
        return habit
            + ruleOccasionFit(g, ctx: ctx) * (1 - 0.6 * habitConfidence)
            + situationFit(g, ctx: ctx, habitConfidence: habitConfidence)
    }

    /// The item's own fit for the situation: the user's answer counts fully;
    /// otherwise what the item implies nudges formal, evening and outdoor looks
    /// (work and workouts are covered by the rules above).
    private func situationFit(_ g: Garment, ctx: RecoContext, habitConfidence: Double) -> Double {
        guard let situation = GarmentOccasion(calendar: ctx.occasionKind) else { return 0 }
        if g.occasionFits.contains(situation) { return 0.08 }
        if g.occasionNotFits.contains(situation) { return -0.15 }
        switch situation {
        case .formal, .eveningOut, .outdoor:
            let derived = GarmentOccasionProfile.derivedScore(g, for: situation)
            return (derived - 0.5) * 0.10 * (1 - 0.5 * habitConfidence)
        default:
            return 0
        }
    }

    /// Short or long sleeves: the day's answer decides, else the learned threshold nudges.
    private func sleeveFit(_ g: Garment, ctx: RecoContext) -> Double {
        guard let sleeve = g.sleeveLength else { return 0 }
        if ctx.lookTime == .day, let choice = ctx.layerChoice {
            return sleeve == choice.sleeve ? 0.10 : -0.10
        }
        guard let threshold = ctx.shortSleeveFromC else { return 0 }
        let wanted: SleeveLength = ctx.temperatureC >= threshold ? .short : .long
        return sleeve == wanted ? 0.05 : -0.05
    }

    private func ruleOccasionFit(_ g: Garment, ctx: RecoContext) -> Double {
        switch ctx.occasionKind {
        case .sport:
            if g.isActivewear { return 0.12 }
            return g.formality >= 4 ? -0.10 : 0
        case .work:
            return g.isWorkwear ? 0.06 : 0
        case .mourning:
            guard let color = g.safeColorTags.first else { return 0 }
            let muted: Set<ColorTag> = [.black, .navy, .gray, .white, .brown, .beige, .cream]
            if muted.contains(color) { return 0.06 }
            return ColorHarmony.info(color).chroma > 40 ? -0.10 : 0
        default:
            return 0
        }
    }

    func score(_ garment: Garment, ctx: RecoContext, modelContext: ModelContext) -> Double {
        let state = ensureState(context: modelContext, profileID: ctx.profileID)
        return combinedScore(g: garment, ctx: ctx, state: state)
    }

    // MARK: - Suggestion

    /// Suggest top K garments. Stable ranking, no random shuffling.
    /// - Parameters:
    ///   - garments: Pool of available garments
    ///   - k: Number of items to suggest
    ///   - ctx: Recommendation context (weather, formality, etc.)
    ///   - modelContext: SwiftData context
    ///   - excludedIDs: IDs to exclude (e.g., garments used in previous days)
    ///   - penalizedIDs: IDs to penalize but not exclude (reduce score by 30%)
    func suggest(
        from garments: [Garment],
        k: Int,
        ctx: RecoContext,
        modelContext: ModelContext,
        excludedIDs: Set<UUID> = [],
        penalizedIDs: Set<UUID> = [],
        pairedWith: [Garment] = []
    ) -> [Garment] {
        rankedSuggestions(
            from: garments,
            k: k,
            ctx: ctx,
            modelContext: modelContext,
            excludedIDs: excludedIDs,
            penalizedIDs: penalizedIDs,
            pairedWith: pairedWith
        ).map { $0.garment }
    }

    /// Same as `suggest`, keeping each garment's score for look-level ranking.
    func rankedSuggestions(
        from garments: [Garment],
        k: Int,
        ctx: RecoContext,
        modelContext: ModelContext,
        excludedIDs: Set<UUID> = [],
        penalizedIDs: Set<UUID> = [],
        pairedWith: [Garment] = []
    ) -> [(garment: Garment, score: Double)] {
        // Filter out blocked and excluded garments
        let pool = garments.filter { g in
            !g.isBlocked && !excludedIDs.contains(g.id)
        }
        guard !pool.isEmpty else { return [] }
        
        let state = ensureState(context: modelContext, profileID: ctx.profileID)

        // Score all garments
        var scored: [(garment: Garment, score: Double)] = pool.map { g in
            var score = combinedScore(g: g, ctx: ctx, state: state)
            
            // Apply penalty for items used recently (in previous days)
            if penalizedIDs.contains(g.id) {
                score *= 0.7  // 30% penalty
            }

            // Similarity prior for new items (AI-ready without AI)
            score += similarityBonus(for: g, among: pool)

            // Soft boost/penalty from historically co-worn or dismissed pairs
            if !pairedWith.isEmpty {
                let pairAffinity = ctx.combination.affinity(of: g, with: pairedWith)
                score += pairAffinity * 0.12
            }
            
            return (garment: g, score: score)
        }

        // Stable sort by score (descending) - NO shuffling for MVP stability
        scored.sort { $0.score > $1.score }

        // Add light diversity: avoid recommending 3+ of same category in top K
        var result: [(garment: Garment, score: Double)] = []
        var categoryCounts: [Category: Int] = [:]
        
        for entry in scored {
            let cat = entry.garment.category
            let count = categoryCounts[cat, default: 0]
            
            // Allow max 2 of same category in suggestions
            if count < 2 {
                result.append(entry)
                categoryCounts[cat] = count + 1
            }
            
            if result.count >= k {
                break
            }
        }
        
        // If diversity rules limited us, fill with remaining top scores
        if result.count < k {
            for entry in scored {
                if !result.contains(where: { $0.garment.id == entry.garment.id }) {
                    result.append(entry)
                    if result.count >= k { break }
                }
            }
        }

        return result
    }

    // MARK: - Whole-look ranking (Look DNA)

    /// A candidate look (core pieces, optionally with outer / accessory) and its score.
    struct ScoredLook {
        let garments: [Garment]
        let score: Double
        let dna: LookDNA
    }

    /// Optional steering toward (or away from) a look fingerprint, used for
    /// "more like this" / "something different" and Style Swipe decks.
    struct LookTarget {
        let dna: LookDNA
        /// Bonus weight for similarity to `dna`.
        let weight: Double
        /// Max pieces a candidate may share with `avoidSharingWith`.
        let maxShared: Int
        let avoidSharingWith: Set<UUID>

        init(dna: LookDNA, weight: Double = 0.35, maxShared: Int = 1, avoidSharingWith: Set<UUID> = []) {
            self.dna = dna
            self.weight = weight
            self.maxShared = maxShared
            self.avoidSharingWith = avoidSharingWith
        }
    }

    /// Learned look-level preference, 0...1 (0.5 = no opinion yet).
    func lookPreference(_ dna: LookDNA, state: RecoState) -> Double {
        let w = paddedLookWeights(state)
        let x = dna.vector
        var s = state.lookBias
        for i in 0..<min(w.count, x.count) {
            s += w[i] * x[i]
        }
        return 1.0 / (1.0 + exp(-s))
    }

    func lookPreference(_ dna: LookDNA, profileID: UUID?, modelContext: ModelContext) -> Double {
        lookPreference(dna, state: ensureState(context: modelContext, profileID: profileID))
    }

    /// Whole-look score: piece scores + color/proportion rules + learned look taste
    /// + how well the pieces have gone together before.
    func lookScore(
        garments: [Garment],
        itemScores: [Double],
        ctx: RecoContext,
        state: RecoState,
        target: LookTarget? = nil
    ) -> (score: Double, dna: LookDNA) {
        let dna = LookDNA(garments: garments)
        let itemMean = itemScores.isEmpty ? 0 : itemScores.reduce(0, +) / Double(itemScores.count)

        // Trust the learned look taste more as look signals accumulate.
        let learnedShare = 0.2 + 0.6 * min(1.0, Double(state.lookInteractionCount) / 20.0)
        let lookPart = (1 - learnedShare) * dna.priorScore + learnedShare * lookPreference(dna, state: state)

        var pairTotal = 0.0
        var pairCount = 0
        for i in 0..<garments.count {
            for j in (i + 1)..<garments.count {
                pairTotal += ctx.combination.score(between: garments[i].id, and: garments[j].id)
                pairCount += 1
            }
        }
        let pairMean = pairCount > 0 ? pairTotal / Double(pairCount) : 0

        var score = 0.6 * itemMean + 0.4 * lookPart + 0.12 * pairMean
        if let target {
            score += target.weight * dna.similarity(to: target.dna)
        }
        return (score, dna)
    }

    /// Ranks whole looks instead of picking piece by piece: takes the best
    /// `perSlot` candidates for top / bottom / shoes, scores every combination
    /// as a look, then adds outer / accessory where they improve the look.
    func rankLooks(
        from garments: [Garment],
        ctx: RecoContext,
        modelContext: ModelContext,
        excludedIDs: Set<UUID> = [],
        penalizedIDs: Set<UUID> = [],
        locked: Garment? = nil,
        perSlot: Int = 6,
        limit: Int = 1,
        includeOptionalLayers: Bool = true,
        target: LookTarget? = nil
    ) -> [ScoredLook] {
        let state = ensureState(context: modelContext, profileID: ctx.profileID)
        var excludeSet = excludedIDs
        var base: [(garment: Garment, score: Double)] = []
        if let locked {
            let lockedScore = combinedScore(g: locked, ctx: ctx, state: state)
            base.append((garment: locked, score: lockedScore))
            excludeSet.insert(locked.id)
        }
        let lockedCategory = locked?.category

        func pool(for category: Category) -> [Garment] {
            garments.filter { g in
                guard g.category == category,
                      !g.isBlocked,
                      !excludeSet.contains(g.id),
                      !g.isCurrentlyUnavailable else { return false }
                if category == .outer {
                    return TemperatureComfort.outerGarmentAllowed(g, policy: ctx.outerLayerPolicy)
                }
                return true
            }
        }

        // Candidate lists for the core slots.
        var slotCandidates: [[(garment: Garment, score: Double)]] = []
        for category in [Category.top, .bottom, .shoes] where category != lockedCategory {
            let candidates = rankedSuggestions(
                from: pool(for: category),
                k: perSlot,
                ctx: ctx,
                modelContext: modelContext,
                excludedIDs: excludeSet,
                penalizedIDs: penalizedIDs,
                pairedWith: base.map { $0.garment }
            )
            if !candidates.isEmpty {
                slotCandidates.append(candidates)
            }
        }

        // Every combination of the core candidates.
        var combos: [[(garment: Garment, score: Double)]] = [base]
        for candidates in slotCandidates {
            var next: [[(garment: Garment, score: Double)]] = []
            next.reserveCapacity(combos.count * candidates.count)
            for combo in combos {
                for candidate in candidates {
                    next.append(combo + [candidate])
                }
            }
            combos = next
        }

        var looks: [ScoredLook] = combos.compactMap { (combo) -> ScoredLook? in
            guard !combo.isEmpty else { return nil }
            let pieces = combo.map { $0.garment }
            if let target, !target.avoidSharingWith.isEmpty {
                let shared = pieces.filter { target.avoidSharingWith.contains($0.id) }.count
                if shared > target.maxShared { return nil }
            }
            let result = lookScore(
                garments: pieces,
                itemScores: combo.map { $0.score },
                ctx: ctx,
                state: state,
                target: target
            )
            return ScoredLook(garments: pieces, score: result.score, dna: result.dna)
        }
        looks.sort { $0.score > $1.score }

        // Keep looks that differ by at least two pieces, so "the next best" is a real alternative.
        var picked: [ScoredLook] = []
        for look in looks {
            let ids = Set(look.garments.map(\.id))
            let distinct = picked.allSatisfy { other in
                ids.subtracting(other.garments.map(\.id)).count >= min(2, ids.count)
            }
            if distinct {
                picked.append(look)
            }
            if picked.count >= limit { break }
        }

        guard includeOptionalLayers else { return picked }
        if picked.isEmpty {
            // No core pieces available: still offer outer / accessory around the lock.
            let pieces = base.map { $0.garment }
            picked = [ScoredLook(garments: pieces, score: 0, dna: LookDNA(garments: pieces))]
        }

        // Outer / accessory: add the candidate that makes the whole look score best.
        return picked.map { (look) -> ScoredLook in
            var pieces = look.garments
            var current = look
            for category in [Category.outer, .accessory] where category != lockedCategory {
                // A warm, dry day has no weather layer; a light jacket over short
                // sleeves is still offered on some days as a styling option.
                var styleLayer = false
                if category == .outer, ctx.outerLayerPolicy == .suppress {
                    guard Self.offersStyleLayer(over: pieces, ctx: ctx) else { continue }
                    styleLayer = true
                }
                let used = excludeSet.union(pieces.map(\.id))
                let source = styleLayer
                    ? garments.filter { g in
                        g.category == .outer && !g.isBlocked && !excludeSet.contains(g.id)
                            && !g.isCurrentlyUnavailable && TemperatureComfort.isLightLayer(g)
                    }
                    : pool(for: category)
                let candidates = rankedSuggestions(
                    from: source,
                    k: 4,
                    ctx: ctx,
                    modelContext: modelContext,
                    excludedIDs: used,
                    penalizedIDs: penalizedIDs,
                    pairedWith: pieces
                )
                var best: ScoredLook?
                for candidate in candidates {
                    let withCandidate = pieces + [candidate.garment]
                    let scores = withCandidate.map { g in
                        g.id == candidate.garment.id ? candidate.score : combinedScore(g: g, ctx: ctx, state: state)
                    }
                    let result = lookScore(garments: withCandidate, itemScores: scores, ctx: ctx, state: state, target: target)
                    if best == nil || result.score > best!.score {
                        best = ScoredLook(garments: withCandidate, score: result.score, dna: result.dna)
                    }
                }
                // Outer layers are weather-driven: add the best one whenever allowed.
                // Accessories only when they don't drag the look down.
                // A style layer is added on the days `offersStyleLayer` picks, whatever its weather score.
                if let best, category == .outer || best.score >= current.score - 0.02 {
                    pieces = best.garments
                    current = best
                }
            }
            return current
        }
        .filter { !$0.garments.isEmpty }
    }

    // MARK: - Style layer

    /// Mild enough that a light jacket over short sleeves is comfortable
    /// (the day's weighted temperature, so a 19–29° day lands near 26).
    static let styleLayerTempRange: Range<Double> = 18..<27

    /// A light jacket over a short-sleeve top on a mild, dry day, on about every
    /// other such day (stable per day and top) so the looks vary. Not when the
    /// user said "short, no jacket" for the day.
    static func offersStyleLayer(over pieces: [Garment], ctx: RecoContext) -> Bool {
        guard !ctx.isRaining, styleLayerTempRange.contains(ctx.temperatureC) else { return false }
        if ctx.lookTime == .day, ctx.layerChoice == .shortNoLayer || ctx.layerChoice == .long { return false }
        guard let top = pieces.first(where: { $0.category == .top }), top.sleeveLength == .short else { return false }
        if ctx.lookTime == .day, ctx.layerChoice == .shortWithLayer { return true }
        let day = Int(Calendar.current.startOfDay(for: ctx.now).timeIntervalSince1970 / 86_400)
        let topSeed = top.id.uuidString.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 1_000 }
        return (day + topSeed) % 2 == 0
    }

    /// Suggest a complete outfit, ranked as a whole look (see `rankLooks`).
    func suggestOutfit(
        from garments: [Garment],
        ctx: RecoContext,
        modelContext: ModelContext,
        excludedIDs: Set<UUID> = [],
        penalizedIDs: Set<UUID> = [],
        locked: Garment? = nil
    ) -> [Garment] {
        rankLooks(
            from: garments,
            ctx: ctx,
            modelContext: modelContext,
            excludedIDs: excludedIDs,
            penalizedIDs: penalizedIDs,
            locked: locked
        ).first?.garments ?? (locked.map { [$0] } ?? [])
    }

    private func paddedLookWeights(_ state: RecoState) -> [Double] {
        var w = state.lookWeights
        if w.count < LookDNA.vectorSize {
            w.append(contentsOf: repeatElement(0.0, count: LookDNA.vectorSize - w.count))
        } else if w.count > LookDNA.vectorSize {
            w = Array(w.prefix(LookDNA.vectorSize))
        }
        return w
    }

    /// Look-level learning: `reward` 0...1 for the whole look (swipe, worn, loved, rejected).
    func learnLook(
        _ garments: [Garment],
        reward: Double,
        learningRate: Double = 0.08,
        profileID: UUID?,
        modelContext: ModelContext,
        save: Bool = true
    ) {
        guard garments.count >= 2 else { return }
        let state = ensureState(context: modelContext, profileID: profileID)
        var w = paddedLookWeights(state)
        let x = LookDNA(garments: garments).vector
        var s = state.lookBias
        for i in 0..<min(w.count, x.count) { s += w[i] * x[i] }
        let err = reward - 1.0 / (1.0 + exp(-s))
        for i in 0..<min(w.count, x.count) {
            w[i] += learningRate * err * x[i]
        }
        state.lookWeights = w
        state.lookBias += learningRate * err * 0.5
        state.lookInteractionCount += 1
        if save {
            try? modelContext.save()
        }
    }

    /// Pairwise look update: the look after a user's swap beats the look before it.
    func learnLookPreference(
        chosen: [Garment],
        over rejected: [Garment],
        learningRate: Double = 0.08,
        profileID: UUID?,
        modelContext: ModelContext,
        save: Bool = true
    ) {
        guard chosen.count >= 2, rejected.count >= 2 else { return }
        let state = ensureState(context: modelContext, profileID: profileID)
        var w = paddedLookWeights(state)
        let xChosen = LookDNA(garments: chosen).vector
        let xRejected = LookDNA(garments: rejected).vector
        var margin = 0.0
        for i in 0..<min(w.count, xChosen.count) { margin += w[i] * (xChosen[i] - xRejected[i]) }
        let gradient = 1.0 - 1.0 / (1.0 + exp(-margin))
        for i in 0..<min(w.count, xChosen.count) {
            w[i] += learningRate * gradient * (xChosen[i] - xRejected[i])
        }
        state.lookWeights = w
        state.lookInteractionCount += 1
        if save {
            try? modelContext.save()
        }
    }

    // MARK: - Learning

    /// Learn from user feedback with per-item updates and negative sampling
    func learn(
        from selected: [Garment],
        shown: [Garment]? = nil,  // Other options that were shown but not selected
        ctx: RecoContext,
        reward: Double,
        weight: Double = 1.0,
        modelContext: ModelContext,
        save: Bool = true
    ) {
        let state = ensureState(context: modelContext, profileID: ctx.profileID)
        var w = state.weights
        var b = state.bias
        let lr = state.lr * max(0, weight)

        // Per-item learning for selected items (reward)
        for g in selected {
            let x = features(
                for: g,
                ctx: ctx,
                warmthOffset: state.learnedWarmthOffset,
                formalityOffset: state.learnedFormalityOffset
            )
            let yhat = modelScore(w: w, b: b, x: x)
            let err = reward - yhat
            
            for i in 0..<min(w.count, x.count) {
                w[i] += lr * err * x[i]
            }
            b += lr * err
        }

        // Negative sampling: shown but not selected items get reward = 0
        if let shownItems = shown {
            let notSelected = shownItems.filter { item in
                !selected.contains(where: { $0.id == item.id })
            }
            
            // Sample up to 3 negative examples
            let negatives = Array(notSelected.prefix(3))
            for g in negatives {
                let x = features(
                    for: g,
                    ctx: ctx,
                    warmthOffset: state.learnedWarmthOffset,
                    formalityOffset: state.learnedFormalityOffset
                )
                let yhat = modelScore(w: w, b: b, x: x)
                let negReward = 0.3  // Slight negative signal (not 0, to avoid over-penalizing)
                let err = negReward - yhat
                
                // Smaller learning rate for negatives
                for i in 0..<min(w.count, x.count) {
                    w[i] += (lr * 0.5) * err * x[i]
                }
                b += (lr * 0.5) * err
            }
        }

        state.weights = w
        state.bias = b
        state.interactionCount += 1
        if save {
            try? modelContext.save()
        }
    }

    /// Pairwise (RankNet-style) update: the user picked `chosen` over `rejected`
    /// in the same slot and context. Moves weights along the feature difference,
    /// which is far more informative than an absolute reward on either item.
    /// Pass `save: false` when the caller persists through the planner debounce.
    func learnPreference(
        chosen: Garment,
        over rejected: Garment,
        ctx: RecoContext,
        weight: Double = 1.0,
        modelContext: ModelContext,
        save: Bool = true
    ) {
        guard chosen.id != rejected.id else { return }
        let state = ensureState(context: modelContext, profileID: ctx.profileID)
        var w = state.weights
        let xChosen = features(
            for: chosen,
            ctx: ctx,
            warmthOffset: state.learnedWarmthOffset,
            formalityOffset: state.learnedFormalityOffset
        )
        let xRejected = features(
            for: rejected,
            ctx: ctx,
            warmthOffset: state.learnedWarmthOffset,
            formalityOffset: state.learnedFormalityOffset
        )
        var margin = 0.0
        for i in 0..<min(w.count, xChosen.count, xRejected.count) {
            margin += w[i] * (xChosen[i] - xRejected[i])
        }
        // Gradient of log σ(margin): large when the model ranked them the wrong way.
        let gradient = 1.0 - 1.0 / (1.0 + exp(-margin))
        let lr = state.lr * max(0, weight)
        for i in 0..<min(w.count, xChosen.count, xRejected.count) {
            w[i] += lr * gradient * (xChosen[i] - xRejected[i])
        }
        state.weights = w
        state.interactionCount += 1
        if save {
            try? modelContext.save()
        }
    }

    /// 0...0.95 estimate of how much has been learned, for the "stylist knows you" ring.
    func learningProgress(profileID: UUID?, modelContext: ModelContext) -> Double {
        let state = ensureState(context: modelContext, profileID: profileID)
        let signals = Double(state.interactionCount) + Double(state.lookInteractionCount) * 1.5
        return min(0.95, 1.0 - exp(-signals / 40.0))
    }

    func applyDirectionalFeedback(
        _ kind: RecommendationFeedbackKind,
        ctx: RecoContext,
        modelContext: ModelContext
    ) {
        let state = ensureState(context: modelContext, profileID: ctx.profileID)
        let step = 0.25

        switch kind {
        case .tooCold:
            state.learnedWarmthOffset = min(1.5, state.learnedWarmthOffset + step)
        case .tooWarm:
            state.learnedWarmthOffset = max(-1.5, state.learnedWarmthOffset - step)
        case .tooFormal:
            state.learnedFormalityOffset = max(-1.5, state.learnedFormalityOffset - step)
        case .tooCasual:
            state.learnedFormalityOffset = min(1.5, state.learnedFormalityOffset + step)
        case .loved, .notMyStyle, .justRight, .worn, .replaced, .swipeLiked, .swipeDisliked:
            return
        }

        state.interactionCount += 1
        try? modelContext.save()
    }
    
    // MARK: - Settings
    
    /// Enable exploration (for advanced users who want variety)
    func setExploration(enabled: Bool, profileID: UUID? = nil, modelContext: ModelContext) {
        let state = ensureState(context: modelContext, profileID: profileID)
        state.epsilon = enabled ? 0.1 : 0.0
        try? modelContext.save()
    }
    
    /// Reset learned weights (start fresh)
    /// Drops cached learning states, e.g. after "delete all my data" removed them from the store.
    func clearStateCache() {
        stateCacheLock.lock()
        cachedStates.removeAll()
        stateCacheLock.unlock()
    }

    func resetLearning(profileID: UUID? = nil, modelContext: ModelContext) {
        let state = ensureState(context: modelContext, profileID: profileID)
        state.weights = Array(repeating: 0.0, count: FeatureSpace.total)
        state.bias = 0.0
        state.lookWeights = []
        state.lookBias = 0.0
        state.lookInteractionCount = 0
        state.learnedWarmthOffset = 0
        state.learnedFormalityOffset = 0
        state.interactionCount = 0
        try? modelContext.save()
    }
}
