import Foundation
import os

/// Only value snapshots cross the actor boundary. Models created here are never inserted.
actor ShopRankingWorker {
    static let shared = ShopRankingWorker()

    struct Request: Sendable {
        let key: Int
        let products: [ShopProduct]
        let garments: [GarmentValue]
        let wearEvents: [WearValue]
        let recommendationEvents: [RecommendationValue]
        let searchItems: [ShopSearchProfile.OwnedItem]
        let searchFeedback: [ShopSearchProfile.FeedbackItem]
        let profile: PurchaseScorer.Profile?
        let model: ShopPreferenceModel
        let lookWeights: [Double]
        let lookBias: Double
        let lookInteractions: Int
        let forecasts: [DayForecast]
        let plans: [PurchaseScorer.PlannedInput]
        let includeNextSeason: Bool
        let feedback: ShopFeedbackStore.Signals
        let preferences: ShoppingPreferences
        let department: ShopDepartment?
        let comfort: GarmentWeatherHistory
        let hidden: Set<String>
        let now: Date
        var retainedIDs: [String] = []
        var storeIDs: Set<String> = []
    }
    struct Result: Sendable {
        var picks: [PurchaseScorer.Pick] = []
        var matches: [String: PurchaseScorer.Match] = [:]
        var searchProfile: ShopSearchProfile? = nil
    }
    private var cachedKey: Int?
    private var cached = Result()
    private var cachedAt: Date?
    private static let cacheLifetime: TimeInterval = 60

    func reset() {
        cachedKey = nil
        cached = Result()
        cachedAt = nil
    }

    func rank(_ request: Request) -> Result {
        guard !Task.isCancelled else { return Result() }
        let signposter = WearItPerformance.shoppingSignposter
        if cachedKey == request.key, let cachedAt {
            let age = Date().timeIntervalSince(cachedAt)
            if age >= 0, age < Self.cacheLifetime {
                signposter.emitEvent("ranking-cache-hit")
                return cached
            }
        }
        let preparation = signposter.beginInterval("preparation", id: signposter.makeSignpostID())
        let wardrobe = request.garments.filter {
            !$0.blocked && ($0.ownerID == nil || $0.ownerID == request.profile?.id)
        }.map { $0.makeGarment() }
        let wardrobeIDs = Set(wardrobe.map(\.id))
        let wears = request.wearEvents.filter { event in
            event.garmentIDs.contains { wardrobeIDs.contains($0) }
        }.map { $0.makeEvent() }
        let recommendations = request.recommendationEvents.filter {
            $0.profileID == nil || $0.profileID == request.profile?.id
        }.map { $0.makeEvent() }
        let wear = WardrobeGapAnalyzer.wearSummary(events: wears, now: request.now)
        let choices = TasteAffinityBuilder.choiceSignals(wearEvents: wears,
            recommendationEvents: recommendations, now: request.now)
        let taste = TasteAffinityBuilder.build(from: wardrobe, choiceSignals: choices)
        let gaps = WardrobeGapAnalyzer.analyze(WardrobeGapAnalyzer.Input(
            garments: wardrobe, wearCounts: wear.counts, wearDays: wear.days,
            climate: WardrobeGapAnalyzer.climate(forecasts: request.forecasts, pastEvents: recommendations),
            pastFormalShare: WardrobeGapAnalyzer.pastFormalShare(recommendations),
            taste: taste, now: request.now, checksRotation: true))
        let searchProfile = ShopSearchProfile.build(items: request.searchItems.filter { wardrobeIDs.contains($0.id) }, choiceSignals: choices,
            preferences: request.preferences, feedback: request.searchFeedback, now: request.now)
        let state = RecoState(size: 0)
        state.lookWeights = request.lookWeights
        state.lookBias = request.lookBias
        state.lookInteractionCount = request.lookInteractions
        let input = PurchaseScorer.Input(garments: wardrobe, wearCounts: wear.counts,
            taste: taste, gaps: gaps, profile: request.profile, model: request.model, lookState: state,
            now: request.now, forecasts: request.forecasts, upcomingPlans: request.plans,
            includeNextSeasonDeals: request.includeNextSeason, feedbackSignals: request.feedback,
            preferences: request.preferences, department: request.department, comfort: request.comfort,
            signalCount: wear.days + request.model.interactions, searchProfile: searchProfile)
        signposter.endInterval("preparation", preparation)
        guard !Task.isCancelled else { return Result() }
        let ranking = signposter.beginInterval("ranking", id: signposter.makeSignpostID())
        defer { signposter.endInterval("ranking", ranking) }
        let result = PurchaseScorer.rankAndMatch(request.products, input: input, isHidden: { request.hidden.contains($0) },
            limit: 70, retainedIDs: request.retainedIDs, storeIDs: request.storeIDs)
        guard !Task.isCancelled else { return Result() }
        let value = Result(picks: result.picks, matches: result.matches, searchProfile: searchProfile)
        cachedKey = request.key; cached = value; cachedAt = Date()
        return value
    }

    struct WearValue: Sendable {
        let id: UUID
        let date: Date
        let garmentIDs: [UUID]
        let sourceRaw: String
        let occasionRaw: String?

        @MainActor init(_ event: WearEvent) {
            id = event.id; date = event.date; garmentIDs = event.garmentIDs
            sourceRaw = event.sourceRaw; occasionRaw = event.occasionRaw
        }

        func makeEvent() -> WearEvent {
            let event = WearEvent(date: date, garmentIDs: garmentIDs,
                source: WearEventSource(rawValue: sourceRaw) ?? .manual, id: id)
            // The initializer normalizes dates. Preserve the actual stored input instead.
            event.date = date; event.sourceRaw = sourceRaw; event.occasionRaw = occasionRaw
            return event
        }
    }

    struct RecommendationValue: Sendable {
        let id: UUID
        let deduplicationKey: String
        let createdAt: Date
        let profileID: UUID?
        let dayPlanID: UUID?
        let kindRaw: String
        let selectedGarmentIDs: [UUID]
        let shownGarmentIDs: [UUID]
        let temperatureC: Double
        let wasRaining: Bool
        let desiredFormality: Int
        let warmthSensitivity: Int
        let rainTolerance: Int
        let lookTimeRaw: String
        let modelVersion: Int

        @MainActor init(_ event: RecommendationEvent) {
            id = event.id; deduplicationKey = event.deduplicationKey; createdAt = event.createdAt
            profileID = event.profileID; dayPlanID = event.dayPlanID; kindRaw = event.kindRaw
            selectedGarmentIDs = event.selectedGarmentIDs; shownGarmentIDs = event.shownGarmentIDs
            temperatureC = event.temperatureC; wasRaining = event.wasRaining
            desiredFormality = event.desiredFormality; warmthSensitivity = event.warmthSensitivity
            rainTolerance = event.rainTolerance; lookTimeRaw = event.lookTimeRaw; modelVersion = event.modelVersion
        }

        func makeEvent() -> RecommendationEvent {
            let context = RecoContext(desiredFormality: desiredFormality, temperatureC: temperatureC,
                isRaining: wasRaining, now: createdAt, profileID: profileID,
                warmthSensitivity: warmthSensitivity, rainTolerance: rainTolerance,
                lookTime: LookTime(rawValue: lookTimeRaw) ?? .day)
            let event = RecommendationEvent(deduplicationKey: deduplicationKey, profileID: profileID,
                dayPlanID: dayPlanID, kind: RecommendationFeedbackKind(rawValue: kindRaw) ?? .loved,
                selectedGarmentIDs: selectedGarmentIDs, shownGarmentIDs: shownGarmentIDs, context: context)
            event.id = id; event.createdAt = createdAt; event.kindRaw = kindRaw
            event.temperatureC = temperatureC; event.desiredFormality = desiredFormality
            event.warmthSensitivity = warmthSensitivity; event.rainTolerance = rainTolerance
            event.lookTimeRaw = lookTimeRaw; event.modelVersion = modelVersion
            return event
        }
    }

    struct GarmentValue: Sendable {
        let id: UUID
        let category: Category
        let itemType: ItemType?
        let brand: String?
        let colors: [ColorTag]
        let materials: [MaterialTag]?
        let pattern: PatternTag?
        let styles: [StyleTag]?
        let fit: FitTag?
        let season: SeasonSuitability?
        let minimum: Double?
        let maximum: Double?
        let warmth: Int
        let warmthOverride: Int?
        let breathabilityOverride: Int?
        let sleeve: String?
        let formality: Int
        let love: Int
        let ownerID: UUID?
        let favorite: Bool
        let timesWorn: Int
        let lastWorn: Date?
        let size: SizeOption?
        let layer: LayerRole?
        let occasions: [OccasionTag]?
        let occasionFits: [String]?
        let occasionNotFits: [String]?
        let blocked: Bool
        let unavailable: Date?
        let weather: [WeatherSuitability]?
        let enriched: [String]?

        @MainActor init(_ garment: Garment) {
            id = garment.id; category = garment.category; itemType = garment.itemType; brand = garment.brand
            colors = garment.safeColorTags; materials = garment.materialTags; pattern = garment.patternTag
            styles = garment.styleTags; fit = garment.fitTag; season = garment.seasonSuitability
            minimum = garment.minTempC; maximum = garment.maxTempC; warmth = garment.warmth
            warmthOverride = garment.thermalWarmthOverride; breathabilityOverride = garment.thermalBreathabilityOverride
            sleeve = garment.sleeveLengthRaw; formality = garment.formality; love = garment.loveScore
            ownerID = garment.ownerID; favorite = garment.isFavorite; timesWorn = garment.timesWorn
            lastWorn = garment.lastWorn; size = garment.sizeOption; layer = garment.layerRole
            occasions = garment.occasionTags; occasionFits = garment.occasionFitsRaw
            occasionNotFits = garment.occasionNotFitsRaw; blocked = garment.isBlocked
            unavailable = garment.unavailableUntil; weather = garment.weatherTags; enriched = garment.aiEnrichedFieldsRaw
        }
        func makeGarment() -> Garment {
            let garment = Garment(category: category, itemType: itemType, brand: brand, colorTags: colors,
                materialTags: materials, patternTag: pattern, fitTag: fit)
            garment.id = id; garment.styleTags = styles; garment.seasonSuitability = season
            garment.minTempC = minimum; garment.maxTempC = maximum; garment.warmth = warmth
            garment.thermalWarmthOverride = warmthOverride; garment.thermalBreathabilityOverride = breathabilityOverride
            garment.sleeveLengthRaw = sleeve; garment.formality = formality; garment.loveScore = love
            garment.ownerID = ownerID; garment.isFavorite = favorite; garment.timesWorn = timesWorn
            garment.lastWorn = lastWorn; garment.sizeOption = size; garment.layerRole = layer
            garment.occasionTags = occasions; garment.occasionFitsRaw = occasionFits
            garment.occasionNotFitsRaw = occasionNotFits; garment.isBlocked = blocked
            garment.unavailableUntil = unavailable; garment.weatherTags = weather; garment.aiEnrichedFieldsRaw = enriched
            return garment
        }
    }
}
