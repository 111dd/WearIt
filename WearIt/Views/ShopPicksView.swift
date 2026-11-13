//
//  ShopPicksView.swift
//  WearIt
//
//  "Picks for you": shop products ranked on the device by how much the user would wear them
//  (`PurchaseScorer`), with save / open in the shop / not for me / bought feeding `ShopFeedbackStore`.
//  `ShopPicksSection` is the short version shown in Stats.
//

import SwiftUI
import SwiftData
import UIKit

// MARK: - Engine

@MainActor
enum ShopPicksEngine {
    static let minimumWardrobe = 5

    /// Both surfaces use the same bounded history; Stats keeps its own statistics window.
    static func wearDescriptor() -> FetchDescriptor<WearEvent> {
        var descriptor = FetchDescriptor<WearEvent>(sortBy: [SortDescriptor(\WearEvent.date, order: .reverse)])
        descriptor.fetchLimit = 400
        return descriptor
    }

    static func recommendationDescriptor() -> FetchDescriptor<RecommendationEvent> {
        var descriptor = FetchDescriptor<RecommendationEvent>(sortBy: [SortDescriptor(\RecommendationEvent.createdAt, order: .reverse)])
        descriptor.fetchLimit = 300
        return descriptor
    }

    static func picks(
        products: [ShopProduct],
        garments: [Garment],
        wearEvents: [WearEvent],
        recommendationEvents: [RecommendationEvent],
        forecasts: [DayForecast],
        profile: UserProfile?,
        feedback: ShopFeedbackStore,
        context: ModelContext,
        upcomingPlans: [DayPlan] = [],
        includeNextSeasonDeals: Bool = false,
        contentSignature: Int
    ) async -> ShopRankingWorker.Result {
        guard !Task.isCancelled else { return .init() }
        let wardrobe = personalWardrobe(garments, profile: profile)
        guard wardrobe.count >= minimumWardrobe, !products.isEmpty else {
            return .init()
        }
        let preferences = profile?.shoppingPreferences ?? ShoppingPreferences()
        let retainedIDs = ShopPersonalSelection.retainedIDs(profileID: profile?.id, preferences: preferences)
        let state = AIRecommender.shared.ensureState(context: context, profileID: profile?.id)
        var hash = Hasher()
        hash.combine(contentSignature)
        hash.combine(profile?.id)
        hash.combine(preferences)
        hash.combine(retainedIDs)
        hash.combine(state.lookWeights)
        hash.combine(state.lookBias)
        hash.combine(state.lookInteractionCount)
        let now = Date()
        // Expire reuse on lookup without making elapsed time a semantic stale-result check.
        hash.combine(Int(now.timeIntervalSince1970 / 60))
        let key = hash.finalize()

        return await ShopRankingCoordinator.shared.result(key: key) {
            // Canonical value order lets Shopping and Stats reuse the same result.
            let ordered = wardrobe.sorted { $0.id.uuidString < $1.id.uuidString }
            let sizes = Dictionary(uniqueKeysWithValues: [Category.top, .bottom, .shoes, .outer].compactMap { category in
                MySizesView.usualSize(for: category, profile: profile, garments: ordered).map { (category, $0) }
            })
            let profileValue = profile.map { PurchaseScorer.Profile(id: $0.id, warmthSensitivity: $0.warmthSensitivity,
                rainTolerance: $0.rainTolerance, sizes: sizes) }
            let resolution = ShoppingPreferences.resolvedDepartment(profile: profile, garments: ordered,
                feedback: feedback, products: products)
            let recommendations = recommendationEvents.sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
            }
            return ShopRankingWorker.Request(key: key, products: products,
                garments: ordered.map { ShopRankingWorker.GarmentValue($0) },
                wearEvents: wearEvents.sorted {
                    $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date
                }.map { ShopRankingWorker.WearValue($0) },
                recommendationEvents: recommendations.map { ShopRankingWorker.RecommendationValue($0) },
                searchItems: ordered.map { ShopSearchProfile.OwnedItem($0) },
                searchFeedback: searchFeedback(feedback),
                profile: profileValue, model: feedback.state.model,
                lookWeights: state.lookWeights, lookBias: state.lookBias, lookInteractions: state.lookInteractionCount,
                forecasts: forecasts, plans: planSnapshots(upcomingPlans, forecasts: forecasts, profileID: profile?.id, now: now),
                includeNextSeason: includeNextSeasonDeals, feedback: feedback.signals, preferences: preferences,
                department: preferences.department == .automatic ? resolution.department : preferences.department,
                comfort: GarmentWeatherHistory(events: recommendations, garments: ordered, profileID: profile?.id),
                hidden: Set(feedback.state.actions.keys.filter { feedback.isHidden($0, now: now) }).union(ordered.compactMap(\.shopProductID)),
                now: now, retainedIDs: retainedIDs)
        }
    }

    private static func searchFeedback(_ feedback: ShopFeedbackStore) -> [ShopSearchProfile.FeedbackItem] {
        feedback.state.actions.keys.sorted().compactMap { id in
            guard let actions = feedback.state.actions[id],
                  let item = feedback.state.observedItems?[id] ?? feedback.state.keptItems[id] else { return nil }
            let kind: ShopFeedbackKind
            if actions[.bought] != nil { kind = .bought }
            else if let dismissed = actions[.dismissed], dismissed >= (actions[.saved] ?? .distantPast) { kind = .dismissed }
            else if actions[.saved] != nil { kind = .saved }
            else { kind = .opened }
            guard let date = actions[kind] else { return nil }
            return ShopSearchProfile.FeedbackItem(item: item, kind: kind, date: date)
        }
    }

    private static func planSnapshots(_ plans: [DayPlan], forecasts: [DayForecast], profileID: UUID?, now: Date) -> [PurchaseScorer.PlannedInput] {
        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start
        var result: [PurchaseScorer.PlannedInput] = []
        for plan in plans.sorted(by: { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }) where plan.date >= start && plan.date < end && (plan.ownerID == nil || plan.ownerID == profileID) {
            for evening in [false, true] {
                if evening && plan.eveningEnabled != true { continue }
                let status = evening ? plan.eveningLookWearStatus : plan.resolvedDayLookWearStatus
                if status == .worn || status == .notWorn { continue }
                let assignments = evening ? plan.eveningSlotAssignments : plan.slotAssignments
                let ids = assignments.isEmpty && !evening ? plan.selectedGarmentIDs : OutfitSlot.allCases.compactMap { assignments[$0] }
                let forecast = forecasts.first { Calendar.current.isDate($0.date, inSameDayAs: plan.date) }
                let saved = evening ? plan.contextEveningTemp : plan.contextAfternoonTemp
                let temps = [plan.contextTempHigh, plan.contextTempLow].compactMap { $0 }.filter(\.isFinite)
                let mean = temps.isEmpty ? nil : temps.reduce(0, +) / Double(temps.count)
                let temperature = saved.flatMap { $0.isFinite ? $0 : nil } ?? mean ?? forecast?.temperatureC
                result.append(PurchaseScorer.PlannedInput(ids: Array(Set(ids)), date: plan.date, isEvening: evening,
                    temperature: temperature, raining: plan.contextWasRaining ?? forecast?.isRaining ?? false))
            }
        }
        return Array(result.prefix(14))
    }

    static func personalWardrobe(_ garments: [Garment], profile: UserProfile?) -> [Garment] {
        garments.filter { !$0.isBlocked && ($0.ownerID == nil || $0.ownerID == profile?.id) }
    }

    nonisolated static func browse(
        products: [ShopProduct], preferences: ShoppingPreferences, hidden: Set<String>,
        matches: [String: PurchaseScorer.Match], category: Category?, dealsOnly: Bool,
        query: String = "", limit: Int = 100, itemType: ItemType? = nil, includesAccessories: Bool = false
    ) -> [PurchaseScorer.Pick] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = products.filter { product in
            guard !Task.isCancelled, product.item.available != false, !hidden.contains(product.id),
                  preferences.allows(product: product) else { return false }
            if let category { if product.category != category { return false } }
            else if product.category == .accessory && !includesAccessories { return false }
            if let itemType, product.itemType != itemType { return false }
            if dealsOnly && product.discountPercent == nil { return false }
            if product.hasKnownSizeAvailability, let sizes = product.item.inStockSizes, sizes.isEmpty { return false }
            guard !search.isEmpty else { return true }
            return [product.title, product.item.brand ?? "", product.storeName, product.category.title,
                product.itemType?.title ?? ""].joined(separator: " ").localizedStandardContains(search)
        }
        // Stable round-robin by category and type/brand; crawl order never determines the feed.
        var groups: [Category: [ShopProduct]] = [:]
        for category in Category.allCases {
            let buckets = Dictionary(grouping: matching.filter { $0.category == category }) {
                ($0.itemType?.rawValue ?? "") + "|" + ($0.item.brand ?? "")
            }
            let keys = buckets.keys.sorted()
            let maximum = buckets.values.map(\.count).max() ?? 0
            var items: [ShopProduct] = []
            for row in 0..<maximum {
                for key in keys {
                    if let bucket = buckets[key], row < bucket.count { items.append(bucket[row]) }
                }
                if items.count >= limit { break }
            }
            groups[category] = items
        }
        var result: [PurchaseScorer.Pick] = []
        for row in 0..<max(0, limit) {
            for category in Category.allCases {
                guard let items = groups[category], row < items.count else { continue }
                let product = items[row]
                result.append(PurchaseScorer.Pick(product: product, score: 0, wearsPerMonth: nil, looks: 0,
                    reasons: [.checkSize], features: [], match: matches[product.id]))
                if result.count >= limit { return result }
            }
            if Task.isCancelled { return [] }
        }
        return result
    }

    static func reasonText(_ reason: PurchaseScorer.Reason) -> String {
        switch reason {
        case .fillsGap(let kind, let category):
            switch kind {
            case .rainShoes, .rainOuter: return String(localized: "shop_reason_gap_rain")
            case .warmOuter: return String(localized: "shop_reason_gap_cold")
            case .hotWeatherTops: return String(localized: "shop_reason_gap_heat")
            case .formalTop, .formalBottom, .formalShoes: return String(localized: "shop_reason_gap_formal")
            case .lightLayer: return String(localized: "shop_reason_gap_light_layer")
            case .missingCore, .thinRotation, .workhorseBackup:
                return String(format: NSLocalizedString("shop_reason_gap_category_format", comment: ""), category.title)
            }
        case .opensLooks(let count):
            return String(format: NSLocalizedString("shop_reason_looks_format", comment: ""), count)
        case .lovedColor(let color):
            return String(format: NSLocalizedString("shop_reason_color_format", comment: ""), color.title)
        case .lovedBrand(let brand):
            return String(format: NSLocalizedString("shop_reason_brand_format", comment: ""), brand)
        case .wornType(let type):
            return String(format: NSLocalizedString("shop_reason_worn_type_format", comment: ""), type.title)
        case .onSale(let percent):
            return String(format: NSLocalizedString("shop_reason_sale_format", comment: ""), percent)
        case .inYourSize(let size):
            return String(format: NSLocalizedString("shop_reason_size_format", comment: ""), size.title)
        case .alreadyHave(let count, let type):
            return String(format: NSLocalizedString("shop_reason_already_have_format", comment: ""), count, type.title)
        case .fitsStyle:
            return String(localized: "shop_reason_style")
        case .everydayRotation:
            return String(localized: "shop_reason_everyday")
        case .completesLook:
            return String(localized: "shop_reason_completes_look")
        case .upcomingLook(let date, let isEvening):
            let key = isEvening ? "shop_reason_upcoming_evening_format" : "shop_reason_upcoming_format"
            return String(format: NSLocalizedString(key, comment: ""), date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
        case .nextSeasonDeal(let season):
            return String(format: NSLocalizedString("shop_reason_next_season_format", comment: ""), seasonTitle(season))
        case .checkSize:
            return String(localized: "shop_reason_check_size")
        }
    }

    private static func seasonTitle(_ season: SeasonSuitability) -> String {
        switch season {
        case .summer: return String(localized: "shop_season_summer")
        case .winter: return String(localized: "shop_season_winter")
        case .transitional: return String(localized: "shop_season_transition")
        case .allSeason: return String(localized: "shop_season_all")
        }
    }

    static func wearsText(_ pick: PurchaseScorer.Pick) -> String? {
        guard let wears = pick.wearsPerMonth, wears >= 0.5 else { return nil }
        let rounded = max(1, Int(wears.rounded()))
        return String(format: NSLocalizedString("shop_wears_per_month_format", comment: ""), rounded)
    }

    /// Observe values the ranking consumes: edits and same-sized catalog refreshes matter too.
    static func signature(
        catalogRevision: Int, garments: [Garment], wearEvents: [WearEvent],
        recommendationEvents: [RecommendationEvent], forecasts: [DayForecast],
        users: [UserProfile], plans: [DayPlan], feedback: ShopFeedbackStore,
        includeNextSeasonDeals: Bool
    ) -> Int {
        var hash = Hasher()
        hash.combine(catalogRevision)
        hash.combine(includeNextSeasonDeals)
        hash.combine(AuthManager.shared.userIdentifier)
        hash.combine(Calendar.current.startOfDay(for: .now))
        hash.combine(Calendar.current.identifier)
        hash.combine(TimeZone.current.identifier)
        hash.combine(Locale.current.identifier)
        for garment in garments.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hash.combine(garment.id)
            hash.combine(garment.ownerID)
            hash.combine(garment.category)
            hash.combine(garment.itemType)
            hash.combine(garment.brand)
            hash.combine(garment.safeColorTags)
            hash.combine(garment.materialTags)
            hash.combine(garment.styleTags)
            hash.combine(garment.patternTag)
            hash.combine(garment.fitTag)
            hash.combine(garment.sizeOption)
            hash.combine(garment.layerRole)
            hash.combine(garment.weatherTags)
            hash.combine(garment.occasionTags)
            hash.combine(garment.occasionFitsRaw)
            hash.combine(garment.occasionNotFitsRaw)
            hash.combine(garment.sleeveLengthRaw)
            hash.combine(garment.formality)
            hash.combine(garment.loveScore)
            hash.combine(garment.isFavorite)
            hash.combine(garment.timesWorn)
            hash.combine(garment.lastWorn)
            hash.combine(garment.warmth)
            hash.combine(garment.thermalWarmthOverride)
            hash.combine(garment.thermalBreathabilityOverride)
            hash.combine(garment.minTempC)
            hash.combine(garment.maxTempC)
            hash.combine(garment.seasonSuitability)
            hash.combine(garment.isBlocked)
            hash.combine(garment.unavailableUntil)
            hash.combine(garment.shopProductID)
            hash.combine(garment.shopProductURL)
            hash.combine(garment.photoMetadata.values.compactMap(\.sourceURL).sorted())
            hash.combine(garment.aiEnrichedFieldsRaw)
        }
        for event in wearEvents.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hash.combine(event.id)
            hash.combine(event.sourceRaw)
            hash.combine(event.date)
            hash.combine(event.garmentIDs)
            hash.combine(event.occasionRaw)
        }
        for event in recommendationEvents.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hash.combine(event.id)
            hash.combine(event.profileID)
            hash.combine(event.createdAt)
            hash.combine(event.kindRaw)
            hash.combine(event.dayPlanID)
            hash.combine(event.deduplicationKey)
            hash.combine(event.selectedGarmentIDs)
            hash.combine(event.shownGarmentIDs)
            hash.combine(event.temperatureC)
            hash.combine(event.wasRaining)
            hash.combine(event.desiredFormality)
            hash.combine(event.warmthSensitivity)
            hash.combine(event.rainTolerance)
            hash.combine(event.lookTimeRaw)
        }
        for forecast in forecasts.sorted(by: { $0.date < $1.date }) {
            hash.combine(forecast.date)
            hash.combine(forecast.temperatureC)
            hash.combine(forecast.highTempC)
            hash.combine(forecast.lowTempC)
            hash.combine(forecast.rainProbability)
            for sample in forecast.thermalSamples(for: .day) {
                hash.combine(sample.date); hash.combine(sample.temperatureC)
                hash.combine(sample.apparentTemperatureC); hash.combine(sample.rainProbability)
            }
        }
        for user in users.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hash.combine(user.id)
            hash.combine(user.userIdentifier)
            hash.combine(user.createdAt)
            hash.combine(user.topSizeRaw)
            hash.combine(user.bottomSizeRaw)
            hash.combine(user.shoeSizeRaw)
            hash.combine(user.preferredFormality)
            hash.combine(user.warmthSensitivity)
            hash.combine(user.rainTolerance)
            hash.combine(user.workDressCodeRaw)
            hash.combine(user.shoppingPreferencesRaw)
        }
        for plan in plans.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hash.combine(plan.id)
            hash.combine(plan.ownerID)
            hash.combine(plan.date)
            hash.combine(plan.updatedAt)
            hash.combine(plan.selectedGarmentIDs)
            hash.combine(plan.eveningEnabled)
            for slot in plan.slotAssignments.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                hash.combine(slot)
                hash.combine(plan.slotAssignments[slot])
            }
            for slot in plan.eveningSlotAssignments.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                hash.combine(slot)
                hash.combine(plan.eveningSlotAssignments[slot])
            }
            hash.combine(plan.contextTempHigh)
            hash.combine(plan.contextTempLow)
            hash.combine(plan.contextWasRaining)
            hash.combine(plan.contextMorningTemp)
            hash.combine(plan.contextAfternoonTemp)
            hash.combine(plan.contextEveningTemp)
            hash.combine(plan.contextRainProbability)
            hash.combine(plan.dayLookWearStatusRaw)
            hash.combine(plan.eveningLookWearStatusRaw)
            hash.combine(plan.wasWornConfirmed)
            hash.combine(plan.eveningUsesDayBottom)
        }
        hash.combine(feedback.revision)
        hash.combine(feedback.state.model.weights)
        hash.combine(feedback.state.model.bias)
        hash.combine(feedback.state.model.interactions)
        for id in feedback.state.actions.keys.sorted() {
            hash.combine(id)
            for kind in feedback.state.actions[id, default: [:]].keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                hash.combine(kind)
                hash.combine(feedback.state.actions[id]?[kind])
            }
        }
        return hash.finalize()
    }
}

// MARK: - Full screen

struct ShopPicksView: View {
    private let isRoot: Bool
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var weather: WeatherCenter
    @ObservedObject private var catalog = ShopCatalogService.shared
    @ObservedObject private var feedback = ShopFeedbackStore.shared

    @ObservedObject private var personalSelection = ShopPersonalSelection.shared

    @Query private var garments: [Garment]
    @Query private var wearEvents: [WearEvent]
    @Query private var recommendationEvents: [RecommendationEvent]
    @Query private var users: [UserProfile]
    @Query private var recommendationStates: [RecoState]
    @Query private var upcomingPlans: [DayPlan]

    @AppStorage("shop.includeNextSeasonDeals") private var includeNextSeasonDeals = false
    @State private var personalFilters = ShopResultFilters()
    @State private var browseFilters = ShopResultFilters()
    @State private var picks: [PurchaseScorer.Pick] = []
    @State private var personalPicks: [PurchaseScorer.Pick] = []
    @State private var productDetails: PurchaseScorer.Pick?
    @State private var refreshGeneration = 0
    @State private var matches: [String: PurchaseScorer.Match] = [:]
    @State private var matchRevision = 0
    @State private var isRanking = false
    @State private var purchaseNotice: PurchaseNotice?
    @State private var purchaseDetails: Garment?
    @State private var purchaseError = false
    private struct PurchaseNotice: Identifiable {
        let id = UUID()
        let imported: ShopPurchaseImporter.Result
        let profile: UserProfile?
        let undo: ShopFeedbackStore.PurchaseUndo
        var garment: Garment { imported.garment }
    }
    @State private var mode: Mode = .personalized
    @State private var shoppingPreferencesProfile: UserProfile?
    @State private var showBrowseFilters = false
    @State private var browseQuery = ""
    @State private var browseLimit = 60
    @State private var browsedPicks: [PurchaseScorer.Pick] = []
    @State private var browseResultKey: BrowseKey?
    @State private var browsePreferences = ShoppingPreferences()
    @State private var hasInitializedBrowsePreferences = false

    private enum Mode: String, CaseIterable, Identifiable {
        case personalized, browse
        var id: String { rawValue }
        var title: String {
            switch self {
            case .personalized: return String(localized: "shop_mode_personalized")
            case .browse: return String(localized: "shop_mode_browse")
            }
        }
    }

    init(isRoot: Bool = false) {
        self.isRoot = isRoot
        _wearEvents = Query(ShopPicksEngine.wearDescriptor())
        _recommendationEvents = Query(ShopPicksEngine.recommendationDescriptor())
        let today = Calendar.current.startOfDay(for: .now)
        let start = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today
        let end = Calendar.current.date(byAdding: .day, value: 14, to: today) ?? today
        _upcomingPlans = Query(filter: #Predicate<DayPlan> { $0.date >= start && $0.date < end }, sort: \.date)
    }

    private var shown: [PurchaseScorer.Pick] {
        if mode == .browse { return browseResultKey == browseKey ? browsedPicks : [] }
        let department = ShoppingPreferences.resolvedDepartment(profile: profile, garments: garments,
            feedback: feedback, products: catalog.products).department ?? .automatic
        if personalFilters.isDefault {
            return personalPicks.filter { department.includes($0.product.audience, category: $0.product.category) }
        }
        let candidates = personalFilters.savedOnly ? savedPicks : picks
        let filtered = candidates.filter { pick in
            guard department.includes(pick.product.audience, category: pick.product.category),
                  personalFilters.includes(pick) else { return false }
            return personalFilters.savedOnly || personalFilters.category != nil || pick.product.category != .accessory
        }
        return personalFilters.savedOnly ? filtered : Array(filtered.prefix(20))
    }

    private var activeFilters: ShopResultFilters {
        mode == .personalized ? personalFilters : browseFilters
    }

    private func updateActiveFilters(_ update: (inout ShopResultFilters) -> Void) {
        if mode == .personalized { update(&personalFilters) }
        else { update(&browseFilters) }
    }

    private struct BrowseKey: Hashable {
        let catalog: Int
        let feedback: Int
        let matches: Int
        let filters: ShopResultFilters
        let preferences: ShoppingPreferences
        let query: String
        let limit: Int
        let profileID: UUID?
    }

    private struct BrowseTaskKey: Hashable {
        let isActive: Bool
        let request: BrowseKey
    }
    private var browseKey: BrowseKey {
        BrowseKey(catalog: catalog.revision, feedback: feedback.revision, matches: matchRevision,
            filters: browseFilters, preferences: effectiveBrowsePreferences, query: browseQuery, limit: browseLimit,
            profileID: profile?.id)
    }

    private var effectiveBrowsePreferences: ShoppingPreferences {
        var preferences = browsePreferences
        if preferences.department == .automatic {
            preferences.department = ShoppingPreferences.resolvedDepartment(profile: profile, garments: garments,
                feedback: feedback, products: catalog.products).department ?? .all
        }
        return preferences
    }

    @MainActor private func rebuildBrowse() async {
        guard mode == .browse else { return }
        if !hasInitializedBrowsePreferences {
            // Seed once from the saved department, then keep Explore independent of
            // later For You preference edits for the lifetime of this profile/session.
            browsePreferences = effectiveBrowsePreferences
            hasInitializedBrowsePreferences = true
        }
        let key = browseKey
        let products = key.filters.savedOnly ? savedProducts : catalog.products
        let hidden = Set(feedback.state.actions.keys.filter { feedback.isHidden($0) })
            .union(ShopPicksEngine.personalWardrobe(garments, profile: profile).compactMap(\.shopProductID))
        let reports = matches
        let task = Task.detached(priority: .userInitiated) {
            ShopPicksEngine.browse(products: products, preferences: key.preferences, hidden: hidden,
                matches: reports, category: key.filters.category, dealsOnly: key.filters.dealsOnly, query: key.query,
                limit: key.limit, itemType: key.filters.itemType, includesAccessories: key.filters.savedOnly)
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, key == browseKey else { return }
        browsedPicks = result
        browseResultKey = key
    }

    private var profile: UserProfile? {
        CurrentUser.activeProfile(from: users, userIdentifier: AuthManager.shared.userIdentifier)
    }

    private var personalGarmentCount: Int {
        ShopPicksEngine.personalWardrobe(garments, profile: profile).count
    }

    private var savedProducts: [ShopProduct] {
        let current = Dictionary(catalog.products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return feedback.savedIDs.compactMap { id in
            guard !feedback.isHidden(id) else { return nil }
            if let product = current[id] { return product }
            let kept = feedback.keptItem(id).flatMap { item in
                ShopCatalogService.map(item, storeName: storeName(for: item))
            }
            return kept
        }
    }

    /// Keep bookmarks independent of ranking, but honor the personal department and list filters.
    private var savedPicks: [PurchaseScorer.Pick] {
        let byID = Dictionary(picks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let department = ShoppingPreferences.resolvedDepartment(profile: profile, garments: garments,
            feedback: feedback, products: catalog.products).department ?? .automatic
        return savedProducts.compactMap { product in
            guard department.includes(product.audience, category: product.category) else { return nil }
            if let pick = byID[product.id] { return pick }
            // No evaluated upcoming/everyday/seasonal claim is available for an unranked bookmark.
            guard personalFilters.focus == .all else { return nil }
            return PurchaseScorer.Pick(product: product, score: 0, wearsPerMonth: nil, looks: 0,
                reasons: [.checkSize], features: [], match: matches[product.id])
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                header
                filterBar
                content
                Text(String(localized: "shop_footer"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, DS.Spacing.xs)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.sm)
            .padding(.bottom, 100)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(String(localized: isRoot ? "tab_shopping" : "shop_title"))
        .modifier(ShopNavigationStyle(isRoot: isRoot))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                preferencesMenu
            }
        }
        .sheet(item: $shoppingPreferencesProfile) { profile in
            ShoppingPreferencesView(profile: profile)
        }
        .sheet(item: $productDetails) { pick in
            ShopProductDetailsSheet(pick: pick, onOpen: { open(pick) },
                onToggleSave: { toggleSave(pick) }, onDismiss: { record(.dismissed, pick) },
                onBought: { record(.bought, pick) })
        }
        .sheet(item: $purchaseDetails) { garment in GarmentPurchaseView(garment: garment) }
        .alert(String(localized: "error_title"), isPresented: $purchaseError) {
            Button(String(localized: "action_ok"), role: .cancel) {}
        } message: { Text(String(localized: "shop_purchase_failed")) }
        .safeAreaInset(edge: .bottom) {
            if let notice = purchaseNotice {
                HStack(spacing: DS.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "shop_purchase_added")).font(.subheadline.weight(.semibold))
                        Button(String(localized: "purchase_details_receipt")) { purchaseDetails = notice.garment }
                            .font(.caption)
                    }
                    Spacer()
                    Button(String(localized: "action_undo")) { undoPurchase(notice) }
                        .frame(minHeight: 44)
                }
                .padding().background(.regularMaterial)
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled, purchaseNotice?.id == notice.id else { return }
                    purchaseNotice = nil
                }
            }
        }
        .sheet(isPresented: $showBrowseFilters) {
            ShopBrowseFiltersView(preferences: Binding(get: { effectiveBrowsePreferences }, set: { browsePreferences = $0 }),
                filters: $browseFilters)
        }
        .task {
            await catalog.refreshIfNeeded()
            ShopPurchaseImporter.shared.restoreKnownPurchases(garments: garments, profileID: profile?.id,
                feedback: feedback, products: catalog.products, context: context)
        }
        .task(id: BrowseTaskKey(isActive: mode == .browse, request: browseKey)) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await rebuildBrowse()
        }
        .task(id: "\(rankingSignature)|\(refreshGeneration)|\(scenePhase)") {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, scenePhase == .active else { return }
            await rebuild()
        }
        .refreshable {
            await catalog.refreshIfNeeded(force: true)
        }
        .onChange(of: includeNextSeasonDeals) { _, enabled in
            if !enabled, personalFilters.focus == .nextSeason { personalFilters.focus = .all }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshGeneration += 1
                Task { await catalog.refreshIfNeeded() }
            }
        }
        .onChange(of: profile?.id) { _, _ in
            picks = []; personalPicks = []; matches = [:]; browsedPicks = []; purchaseNotice = nil; productDetails = nil
            browsePreferences = ShoppingPreferences(); browseResultKey = nil; hasInitializedBrowsePreferences = false
            personalFilters = ShopResultFilters(); browseFilters = ShopResultFilters(); browseQuery = ""; browseLimit = 60
            matchRevision += 1
        }
        .onChange(of: browseFilters) { old, new in
            browseLimit = 60
            if !old.dealsOnly && new.dealsOnly { refreshOffers() }
        }
        .onChange(of: personalFilters.dealsOnly) { _, enabled in
            if enabled { refreshOffers() }
        }
        .onChange(of: mode) { _, _ in
            if activeFilters.dealsOnly { refreshOffers() }
        }
        .onChange(of: browseQuery) { _, _ in browseLimit = 60 }
        .onChange(of: browsePreferences) { _, _ in browseLimit = 60 }
    }

    private var preferencesMenu: some View {
        Menu {
            if mode == .personalized {
                Button(String(localized: "shop_preferences_title")) { shoppingPreferencesProfile = profile }
                    .disabled(profile == nil)
                Toggle(String(localized: "shop_next_season_toggle"), isOn: $includeNextSeasonDeals)
                Button(String(localized: "shop_clear_personal_filters")) { personalFilters = ShopResultFilters() }
                    .disabled(personalFilters.isDefault)
            } else {
                Button(String(localized: "shop_browse_preferences")) { showBrowseFilters = true }
                Button(String(localized: "shop_clear_browse_filters")) { clearBrowseFilters() }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .accessibilityLabel(String(localized: mode == .browse ? "shop_browse_preferences" : "shop_personal_filters_title"))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Picker(String(localized: "tab_shopping"), selection: $mode) {
                ForEach(Mode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            Text(String(localized: mode == .personalized ? "shop_subtitle" : "shop_browse_intro"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if mode == .personalized {
                let resolution = ShoppingPreferences.resolvedDepartment(profile: profile, garments: garments, feedback: feedback, products: catalog.products)
                if resolution.needsChoice {
                    Button {
                        shoppingPreferencesProfile = profile
                    } label: {
                        Label(String(localized: "shop_choose_preferences"), systemImage: "slider.horizontal.3")
                            .font(.subheadline.weight(.medium))
                    }
                    .disabled(profile == nil)
                    Text(String(localized: "shop_department_needed"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                browseControls
            }
        }
    }

    private var browseControls: some View {
        HStack(spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(String(localized: "shop_browse_search"), text: $browseQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
            }
            .dsFieldStyle()
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.xs) {
                    chip(String(localized: mode == .personalized ? "shop_filter_clothes_for_you" : "shop_browse_all_categories"),
                        selected: activeFilters.category == nil && activeFilters.focus == .all) {
                            updateActiveFilters { $0.selectCategory(nil); $0.focus = .all }
                        }
                    ForEach(Category.allCases) { category in
                        chip(category.title, selected: activeFilters.category == category, icon: category.icon) {
                            updateActiveFilters {
                                let next = $0.category == category ? nil : category
                                $0.selectCategory(next)
                            }
                        }
                    }
                    chip(String(localized: "shop_filter_deals"), selected: activeFilters.dealsOnly, icon: "tag") {
                        updateActiveFilters { $0.dealsOnly.toggle() }
                    }
                    chip(String(localized: "shop_filter_saved"), selected: activeFilters.savedOnly, icon: "heart.fill") {
                        updateActiveFilters { $0.savedOnly.toggle() }
                    }
                    if mode == .personalized {
                        focusChip(String(localized: "shop_filter_upcoming"), .upcoming, icon: "calendar")
                        focusChip(String(localized: "shop_filter_everyday"), .everyday, icon: "repeat")
                    }
                    if mode == .personalized, includeNextSeasonDeals {
                        focusChip(String(localized: "shop_filter_next_season"), .nextSeason, icon: "leaf")
                    }
                }
            }
            if let category = activeFilters.category {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.xs) {
                        browseTypeChip(String(localized: "shop_browse_all_types"), type: nil)
                        ForEach(category.itemTypes) { type in
                            browseTypeChip(type.title, type: type)
                        }
                    }
                }
            }
        }
    }

    private func browseTypeChip(_ title: String, type: ItemType?) -> some View {
        chip(title, selected: activeFilters.itemType == type) {
            updateActiveFilters { $0.itemType = type }
        }
    }

    private func focusChip(_ title: String, _ focus: ShopResultFilters.Focus, icon: String) -> some View {
        chip(title, selected: personalFilters.focus == focus, icon: icon) {
            personalFilters.focus = personalFilters.focus == focus ? .all : focus
        }
    }

    private func chip(_ title: String, selected: Bool, icon: String? = nil, action: @escaping () -> Void) -> some View {
        return Button {
            DS.haptic(0.3)
            action()
        } label: {
            HStack(spacing: DS.Spacing.xxs) {
                if let icon { Image(systemName: icon).font(.caption) }
                Text(title).font(.subheadline.weight(selected ? .semibold : .regular))
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background(
                Capsule().fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1))
            )
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        if mode == .personalized, !personalFilters.savedOnly, personalGarmentCount < ShopPicksEngine.minimumWardrobe {
            emptyState(icon: "tshirt", text: String(localized: "shop_empty_wardrobe"))
        } else if catalog.products.isEmpty && !activeFilters.savedOnly {
            if catalog.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, DS.Spacing.xl)
            } else {
                emptyState(icon: "bag", text: String(localized: "shop_empty_catalog"))
            }
        } else if mode == .browse, browseResultKey != browseKey {
            ProgressView(String(localized: "shop_loading")).frame(maxWidth: .infinity).padding()
        } else if isRanking && mode == .personalized && !personalFilters.savedOnly && shown.isEmpty {
            ProgressView(String(localized: "shop_matching")).frame(maxWidth: .infinity).padding()
        } else if shown.isEmpty, activeFilters.dealsOnly, catalog.isLoading {
            ProgressView(String(localized: "shop_loading")).frame(maxWidth: .infinity).padding()
        } else if shown.isEmpty, activeFilters.dealsOnly {
            dealsEmptyState
        } else if shown.isEmpty, activeFilters.savedOnly, feedback.savedIDs.isEmpty {
            emptyState(icon: "heart", text: String(localized: "shop_empty_saved"))
        } else if shown.isEmpty {
            emptyState(icon: "sparkle.magnifyingglass", text: String(localized: mode == .personalized ? "shop_empty_filter" : "shop_browse_empty"))
            Button(String(localized: "shop_reset_active_filters")) { resetActiveFilters() }
        } else {
            pickList
        }
    }

    private var dealsEmptyState: some View {
        let hasOffers = catalog.products.contains { $0.discountPercent != nil }
            || (activeFilters.savedOnly && savedProducts.contains { $0.discountPercent != nil })
        return VStack(spacing: DS.Spacing.sm) {
            emptyState(icon: "tag", text: String(localized: hasOffers ? "shop_deals_filtered_empty" : "shop_deals_unavailable"))
            Button(String(localized: "shop_show_without_deals")) {
                updateActiveFilters { $0.dealsOnly = false }
            }
            Button(String(localized: "shop_reset_active_filters")) { resetActiveFilters() }
            Button(String(localized: "shop_refresh_catalog")) {
                Task { await catalog.refreshIfNeeded(force: true) }
            }
        }
    }

    private var pickList: some View {
        LazyVStack(spacing: DS.Spacing.sm) {
            if mode == .browse {
                ForEach(browseSections) { section in
                    Label(section.category.title, systemImage: section.category.icon)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, DS.Spacing.sm)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.picks) { pick in pickCard(pick) }
                }
            } else {
                ForEach(shown) { pick in pickCard(pick) }
            }
            if mode == .browse, shown.count >= browseLimit {
                Button(String(localized: "shop_browse_more")) { browseLimit += 60 }
                    .font(.subheadline.weight(.semibold))
                    .padding(.vertical, DS.Spacing.sm)
            }
        }
    }

    private struct BrowseSection: Identifiable {
        let category: Category
        let picks: [PurchaseScorer.Pick]
        var id: Category { category }
    }

    private var browseSections: [BrowseSection] {
        let groups = Dictionary(grouping: shown, by: \.product.category)
        return Category.allCases.compactMap { category in
            guard let picks = groups[category], !picks.isEmpty else { return nil }
            return BrowseSection(category: category, picks: picks)
        }
    }

    private func pickCard(_ pick: PurchaseScorer.Pick) -> ShopPickCard {
        ShopPickCard(
            pick: pick,
            garments: garments,
            preferProductOnlyPhotos: mode == .browse ? browsePreferences.preferProductOnlyPhotos : (profile?.shoppingPreferences.preferProductOnlyPhotos ?? true),
            isSaved: feedback.has(.saved, pick.id),
            onOpen: { open(pick) },
            onToggleSave: { toggleSave(pick) },
            onDismiss: { record(.dismissed, pick) },
            onBought: { record(.bought, pick) },
            onOpenCompanion: { open($0) },
            onToggleSaveCompanion: { toggleSave($0) },
            onDismissCompanion: { record(.dismissed, $0) },
            onBoughtCompanion: { record(.bought, $0) },
            isCompanionSaved: { feedback.has(.saved, $0.id) },
            onShowDetails: { productDetails = pick },
            onShowCompanionDetails: { productDetails = $0 }
        )
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xl)
    }

    // MARK: Actions

    private func open(_ pick: PurchaseScorer.Pick) {
        DS.haptic(0.3)
        feedback.record(.opened, pick: pick)
        openURL(pick.product.url)
    }

    private func toggleSave(_ pick: PurchaseScorer.Pick) {
        DS.haptic(0.4)
        if feedback.has(.saved, pick.id) {
            feedback.unsave(pick.id)
        } else {
            feedback.record(.saved, pick: pick)
        }
    }

    private func clearBrowseFilters() {
        browseFilters = ShopResultFilters()
        browseQuery = ""
        var cleared = ShoppingPreferences()
        cleared.department = browsePreferences.department
        cleared.preferProductOnlyPhotos = browsePreferences.preferProductOnlyPhotos
        browsePreferences = cleared
        browseLimit = 60
    }

    private func resetActiveFilters() {
        if mode == .personalized { personalFilters = ShopResultFilters() }
        else { clearBrowseFilters() }
    }

    private func refreshOffers() {
        // An explicit offer request must see newly published prices, even within the
        // normal six-hour catalog interval. ETag and the in-flight guard still apply.
        Task { await catalog.refreshIfNeeded(force: true) }
    }

    private func record(_ kind: ShopFeedbackKind, _ pick: PurchaseScorer.Pick) {
        DS.haptic(0.4)
        if kind == .bought {
            guard !feedback.has(.bought, pick.id) else { return }
            do {
                let imported = try ShopPurchaseImporter.shared.add(pick.product, profile: profile, context: context)
                let undo = feedback.recordPurchase(pick)
                purchaseNotice = PurchaseNotice(imported: imported, profile: profile, undo: undo)
            } catch { purchaseError = true; return }
        } else {
            feedback.record(kind, pick: pick)
            if kind == .dismissed {
                ShopPersonalSelection.dismiss(pick.id, profileID: profile?.id,
                    preferences: profile?.shoppingPreferences ?? ShoppingPreferences())
            }
        }
        withAnimation(.snappy) {
            // A companion can replace an owned core piece. Remove that whole preview
            // until the debounced rebuild supplies a complete look without this product.
            browsedPicks.removeAll { $0.id == pick.id }
            picks.removeAll { candidate in
                candidate.id == pick.id || candidate.preview?.companions.contains(where: { $0.id == pick.id }) == true
            }
            personalPicks.removeAll { candidate in
                candidate.id == pick.id || candidate.preview?.companions.contains(where: { $0.id == pick.id }) == true
            }
        }
    }

    private func undoPurchase(_ notice: PurchaseNotice) {
        do {
            try ShopPurchaseImporter.shared.undo(notice.imported, profile: notice.profile, context: context)
            feedback.undoPurchase(notice.undo)
            purchaseNotice = nil
        } catch { purchaseError = true }
    }

    @MainActor private func rebuild() async {
        let signature = rankingSignature
        let profileID = profile?.id
        isRanking = true
        defer { if !Task.isCancelled { isRanking = false } }
        let result = await ShopPicksEngine.picks(
            products: catalog.products,
            garments: garments,
            wearEvents: wearEvents,
            recommendationEvents: recommendationEvents,
            forecasts: weather.forecasts,
            profile: profile,
            feedback: feedback,
            context: context,
            upcomingPlans: upcomingPlans,
            includeNextSeasonDeals: includeNextSeasonDeals,
            contentSignature: signature
        )
        guard !Task.isCancelled else { return }
        guard signature == rankingSignature, profileID == profile?.id else {
            refreshGeneration += 1
            return
        }
        picks = result.picks.filter { !feedback.isHidden($0.id) }
        let owned = Set(ShopPicksEngine.personalWardrobe(garments, profile: profile).compactMap(\.shopProductID))
        personalPicks = ShopPersonalSelection.select(from: picks, profileID: profileID,
            preferences: profile?.shoppingPreferences ?? ShoppingPreferences(),
            isOwned: { feedback.has(.bought, $0) || owned.contains($0) })
        matches = result.matches
        matchRevision += 1
    }

    private var rankingSignature: Int {
        let base = ShopPicksEngine.signature(
            catalogRevision: catalog.revision, garments: garments, wearEvents: wearEvents,
            recommendationEvents: recommendationEvents, forecasts: weather.forecasts,
            users: users, plans: upcomingPlans, feedback: feedback,
            includeNextSeasonDeals: includeNextSeasonDeals
        )
        var hash = Hasher()
        hash.combine(base)
        hash.combine(personalSelection.revision)
        for state in recommendationStates where state.profileID == profile?.id {
            hash.combine(state.lookWeights); hash.combine(state.lookBias); hash.combine(state.lookInteractionCount)
        }
        return hash.finalize()
    }

    private func storeName(for item: ShopCatalogItem) -> String {
        catalog.products.first { $0.item.store == item.store }?.storeName ?? item.store
    }
}

private struct ShopNavigationStyle: ViewModifier {
    let isRoot: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isRoot { content.minimalCollapsingNavBar() }
        else { content.compactNavBar() }
    }
}

/// Observe save changes while the details sheet is open, independently of its presenting row.
private struct ShopProductDetailsSheet: View {
    let pick: PurchaseScorer.Pick
    var onOpen: () -> Void
    var onToggleSave: () -> Void
    var onDismiss: () -> Void
    var onBought: () -> Void
    @ObservedObject private var feedback = ShopFeedbackStore.shared

    var body: some View {
        ShopProductDetailsView(pick: pick, isSaved: feedback.has(.saved, pick.id),
            onOpen: onOpen, onToggleSave: onToggleSave, onDismiss: onDismiss, onBought: onBought)
    }
}

// MARK: - Saved preferences and temporary browsing choices

struct ShoppingPreferencesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let profile: UserProfile
    @State private var draft: ShoppingPreferences
    @State private var brands: String
    @State private var saveFailed = false

    init(profile: UserProfile) {
        self.profile = profile
        var preferences = profile.shoppingPreferences
        if profile.shoppingPreferencesRaw == nil,
           let previous = UserDefaults.standard.string(forKey: "shop.gender"),
           let department = ShopDepartment(rawValue: previous), department == .men || department == .women {
            preferences.department = department
        }
        _draft = State(initialValue: preferences)
        _brands = State(initialValue: preferences.preferredBrands.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                ShopPreferenceFields(preferences: $draft, brands: $brands, isManual: false)
                Section {
                    NavigationLink {
                        MySizesView(profile: profile).withLocalAppBackdrop()
                    } label: {
                        Label(String(localized: "my_sizes_title"), systemImage: "ruler")
                    }
                } footer: {
                    Text(String(localized: "shop_preferences_sizes_detail"))
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(String(localized: "shop_preferences_title"))
            .compactNavBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action_save")) { save() }
                }
            }
            .alert(String(localized: "shop_preferences_save_failed"), isPresented: $saveFailed) {
                Button(String(localized: "action_ok"), role: .cancel) {}
            }
        }
        .withLocalAppBackdropPainted()
    }

    private func save() {
        draft.preferredBrands = ShopPreferenceFields.brandValues(brands)
        let previous = profile.shoppingPreferencesRaw
        profile.shoppingPreferences = draft
        do {
            try context.save()
            DS.haptic(0.4)
            dismiss()
        } catch {
            profile.shoppingPreferencesRaw = previous
            saveFailed = true
        }
    }
}

private struct ShopBrowseFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var preferences: ShoppingPreferences
    @Binding var filters: ShopResultFilters
    @State private var draft: ShoppingPreferences
    @State private var draftFilters: ShopResultFilters
    @State private var brands: String

    init(preferences: Binding<ShoppingPreferences>, filters: Binding<ShopResultFilters>) {
        _preferences = preferences
        _filters = filters
        _draft = State(initialValue: preferences.wrappedValue)
        _draftFilters = State(initialValue: filters.wrappedValue)
        _brands = State(initialValue: preferences.wrappedValue.preferredBrands.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "shop_filter_category"), selection: Binding(
                        get: { draftFilters.category }, set: { draftFilters.selectCategory($0) })) {
                        Text(String(localized: "shop_browse_all_categories")).tag(Optional<Category>.none)
                        ForEach(Category.allCases) { category in
                            Text(category.title).tag(Optional(category))
                        }
                    }
                    if let category = draftFilters.category {
                        Picker(String(localized: "shop_filter_item_type"), selection: $draftFilters.itemType) {
                            Text(String(localized: "shop_browse_all_types")).tag(Optional<ItemType>.none)
                            ForEach(category.itemTypes) { type in
                                Text(type.title).tag(Optional(type))
                            }
                        }
                    }
                    Toggle(String(localized: "shop_filter_deals"), isOn: $draftFilters.dealsOnly)
                    Toggle(String(localized: "shop_filter_saved"), isOn: $draftFilters.savedOnly)
                }
                ShopPreferenceFields(preferences: $draft, brands: $brands, isManual: true)
                Section {
                    Button(String(localized: "shop_browse_reset")) {
                        let department = draft.department
                        draft = ShoppingPreferences()
                        draft.department = department
                        draftFilters = ShopResultFilters()
                        brands = ""
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(String(localized: "shop_browse_preferences"))
            .compactNavBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "shop_browse_apply")) {
                        draft.preferredBrands = ShopPreferenceFields.brandValues(brands)
                        preferences = draft
                        filters = draftFilters
                        dismiss()
                    }
                }
            }
        }
        .withLocalAppBackdropPainted()
    }
}

private struct ShopPreferenceFields: View {
    @Binding var preferences: ShoppingPreferences
    @Binding var brands: String
    let isManual: Bool

    var body: some View {
        Section {
            Picker(String(localized: "shop_department_label"), selection: $preferences.department) {
                ForEach(ShopDepartment.allCases.filter { !isManual || $0 != .automatic }) { department in
                    Text(department.title).tag(department)
                }
            }
            .pickerStyle(.menu)
        } footer: {
            Text(String(localized: isManual ? "shop_browse_filters_detail" : "shop_department_detail"))
        }
        Section {
            DisclosureGroup {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: DS.Spacing.xs)], alignment: .leading, spacing: DS.Spacing.xs) {
                    ForEach(ColorTag.allCases) { color in colorChoice(color) }
                }
                .padding(.vertical, DS.Spacing.xs)
            } label: {
                selectionLabel(String(localized: "shop_preferences_colors"), count: preferences.preferredColors.count)
            }
            DisclosureGroup {
                ForEach(StyleTag.allCases) { style in styleChoice(style) }
            } label: {
                selectionLabel(String(localized: "shop_preferences_styles"), count: preferences.preferredStyles.count)
            }
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(String(localized: "shop_preferences_brands"))
                TextField(String(localized: "shop_preferences_brands_placeholder"), text: $brands, axis: .vertical)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .lineLimit(1...3)
            }
        } footer: {
            Text(String(localized: isManual ? "shop_browse_selected_detail" : "shop_preferences_optional_detail"))
        }
        Section {
            Toggle(String(localized: "shop_preferences_product_photos"), isOn: $preferences.preferProductOnlyPhotos)
        } footer: {
            Text(String(localized: "shop_preferences_product_photos_detail"))
        }
    }

    private func selectionLabel(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(count == 0 ? String(localized: isManual ? "shop_preferences_automatic" : "shop_preferences_from_wardrobe") : String(format: String(localized: "shop_preferences_selected_format"), count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func colorChoice(_ color: ColorTag) -> some View {
        let selected = preferences.preferredColors.contains(color)
        return Button {
            if selected { preferences.preferredColors.removeAll { $0 == color } }
            else { preferences.preferredColors.append(color) }
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Circle().fill(color.color).frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                Text(color.title).font(.subheadline)
                if selected { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DS.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func styleChoice(_ style: StyleTag) -> some View {
        let selected = preferences.preferredStyles.contains(style)
        return Button {
            if selected { preferences.preferredStyles.removeAll { $0 == style } }
            else { preferences.preferredStyles.append(style) }
        } label: {
            HStack {
                Text(Self.styleTitle(style))
                Spacer()
                if selected { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func brandValues(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: ",\n،"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(BrandStore.normalizeBrandKey($0)).inserted }
    }

    private static func styleTitle(_ style: StyleTag) -> String {
        switch style {
        case .casual: return String(localized: "shop_style_casual")
        case .smart_casual: return String(localized: "shop_style_smart_casual")
        case .business: return String(localized: "shop_style_business")
        case .formal: return String(localized: "shop_style_formal")
        case .sporty: return String(localized: "shop_style_sporty")
        case .streetwear: return String(localized: "shop_style_streetwear")
        case .bohemian: return String(localized: "shop_style_bohemian")
        case .minimalist: return String(localized: "shop_style_minimalist")
        case .vintage: return String(localized: "shop_style_vintage")
        }
    }
}

// MARK: - Card

struct ShopPickCard: View {
    let pick: PurchaseScorer.Pick
    let garments: [Garment]
    let preferProductOnlyPhotos: Bool
    let isSaved: Bool
    var onOpen: () -> Void
    var onToggleSave: () -> Void
    var onDismiss: () -> Void
    var onBought: () -> Void
    var onOpenCompanion: (PurchaseScorer.Pick) -> Void
    var onToggleSaveCompanion: (PurchaseScorer.Pick) -> Void
    var onDismissCompanion: (PurchaseScorer.Pick) -> Void
    var onBoughtCompanion: (PurchaseScorer.Pick) -> Void
    var isCompanionSaved: (PurchaseScorer.Pick) -> Bool
    var onShowDetails: () -> Void
    var onShowCompanionDetails: (PurchaseScorer.Pick) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                Button(action: onShowDetails) {
                    ShopProductImage(product: pick.product, preferProductOnly: preferProductOnlyPhotos, canRetry: false)
                        .frame(width: 104, height: 138)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pick.product.title + ", " + String(localized: "shop_details_title"))

                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    if pick.intent == .nextSeason {
                        Text(String(localized: "shop_filter_next_season"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(sourceLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(pick.product.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    priceRow
                    ShopMatchBadge(match: pick.match)
                    if let wears = ShopPicksEngine.wearsText(pick) {
                        Label(wears, systemImage: "repeat")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    ForEach(pick.reasons.filter { $0 != .checkSize }.prefix(2), id: \.self) { reason in
                        Text(ShopPicksEngine.reasonText(reason))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if pick.reasons.contains(.checkSize) {
                        Text(String(localized: "shop_reason_check_size"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let preview = pick.preview, preview.ownedGarmentIDs.allSatisfy({ id in garments.contains { $0.id == id } }) {
                ShopLookPreview(
                    pick: pick, preview: preview, garments: garments,
                    preferProductOnlyPhotos: preferProductOnlyPhotos,
                    onOpenCompanion: onOpenCompanion,
                    onToggleSaveCompanion: onToggleSaveCompanion,
                    onDismissCompanion: onDismissCompanion,
                    onBoughtCompanion: onBoughtCompanion,
                    isCompanionSaved: isCompanionSaved,
                    onShowCompanionDetails: onShowCompanionDetails
                )
            }
            actions
        }
        .dsCard(padding: DS.Spacing.sm)
        .contextMenu {
            Button(action: onShowDetails) { Label(String(localized: "shop_details_title"), systemImage: "photo.on.rectangle") }
            Button(action: onOpen) { Label(String(localized: "shop_action_open"), systemImage: "arrow.up.right.square") }
            Button(action: onBought) { Label(String(localized: "shop_action_bought"), systemImage: "bag.badge.plus") }
            Button(role: .destructive, action: onDismiss) { Label(String(localized: "shop_action_dismiss"), systemImage: "hand.thumbsdown") }
        }
    }

    /// "Terminal X · Nike", or just the store when the brand is the store.
    private var sourceLine: String {
        let store = pick.product.storeName
        guard let brand = pick.product.item.brand, !brand.isEmpty,
              brand.lowercased() != store.lowercased() else { return store }
        return "\(store) · \(brand)"
    }

    private var priceRow: some View {
        HStack(spacing: DS.Spacing.xxs) {
            if let price = pick.product.priceText {
                Text(price).font(.subheadline.weight(.semibold))
            }
            if let percent = pick.product.discountPercent, let original = pick.product.originalPriceText {
                Text(original)
                    .font(.caption)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                Text("-\(percent)%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Button(action: onShowDetails) {
                let count = photoCount
                Label(count > 1 ? String(format: String(localized: "shop_details_all_photos_format"), count) : String(localized: "shop_details_title"),
                    systemImage: "photo.on.rectangle")
                    .font(.caption.weight(.medium))
                    .frame(minHeight: 44)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Spacing.md) {
                    openButton.fixedSize(horizontal: true, vertical: true)
                    Spacer(minLength: DS.Spacing.xs)
                    purchaseButton.fixedSize(horizontal: true, vertical: true)
                }
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    openButton
                    purchaseButton
                }
            }
            HStack(spacing: DS.Spacing.md) {
                Button(action: onToggleSave) {
                    Label(String(localized: isSaved ? "shop_action_unsave" : "shop_action_save"), systemImage: isSaved ? "heart.fill" : "heart")
                        .font(.caption)
                        .foregroundStyle(isSaved ? Color.pink : Color.secondary)
                        .frame(minHeight: 44)
                }
                Spacer(minLength: DS.Spacing.xs)
                Button(action: onDismiss) {
                    Text(String(localized: "shop_action_dismiss"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                }
            }
        }
        .buttonStyle(.borderless)
    }

    private var openButton: some View {
        Button(action: onOpen) {
            Label(String(localized: "shop_action_open"), systemImage: "arrow.up.right.square")
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44)
        }
    }

    private var photoCount: Int {
        let raw = (pick.product.item.images ?? []) + [pick.product.imageURL?.absoluteString].compactMap { $0 }
        return Set(raw.compactMap { value -> URL? in
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { return nil }
            return url
        }).count
    }

    private var purchaseButton: some View {
        Button(action: onBought) {
            Label(String(localized: "shop_action_bought"), systemImage: "bag.badge.plus")
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44)
        }
    }
}

/// A concrete outfit: one or two shop pieces alongside the user's own clothes.
private struct ShopLookPreview: View {
    let pick: PurchaseScorer.Pick
    let preview: PurchaseScorer.LookPreview
    let garments: [Garment]
    let preferProductOnlyPhotos: Bool
    let onOpenCompanion: (PurchaseScorer.Pick) -> Void
    let onToggleSaveCompanion: (PurchaseScorer.Pick) -> Void
    let onDismissCompanion: (PurchaseScorer.Pick) -> Void
    let onBoughtCompanion: (PurchaseScorer.Pick) -> Void
    let isCompanionSaved: (PurchaseScorer.Pick) -> Bool
    let onShowCompanionDetails: (PurchaseScorer.Pick) -> Void

    private var owned: [Garment] {
        let byID = Dictionary(garments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return preview.ownedGarmentIDs.compactMap { byID[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Label(title, systemImage: "square.grid.2x2")
                .font(.caption.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: DS.Spacing.xs) {
                    productTile(pick.product)
                    ForEach(owned) { garment in
                        VStack(spacing: DS.Spacing.xxs) {
                            DSGarmentThumbnail(garment, size: .small)
                            Text(String(localized: "shop_preview_owned"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(garment.displayTitle + ", " + String(localized: "shop_preview_owned"))
                    }
                    ForEach(preview.companions) { companion in
                        productTile(companion.product)
                        .accessibilityLabel(companion.product.title)
                    }
                }
            }
            ForEach(preview.companions) { companion in
                companionRow(companion)
            }
        }
        .padding(DS.Spacing.xs)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.Radius.sm))
    }

    private var title: String {
        guard let date = preview.date else { return String(localized: "shop_preview_title") }
        return ShopPicksEngine.reasonText(.upcomingLook(date, preview.isEvening))
    }

    private func productTile(_ product: ShopProduct) -> some View {
        VStack(spacing: DS.Spacing.xxs) {
            ShopProductImage(product: product, preferProductOnly: preferProductOnlyPhotos)
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.sm)
                        .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                }
            Text(String(localized: "shop_preview_new"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.accentColor)
        }
    }

    private func companionRow(_ companion: PurchaseScorer.Pick) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Button { onShowCompanionDetails(companion) } label: {
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        Text(String(localized: "shop_preview_optional_extra"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(companion.product.title)
                            .font(.caption.weight(.medium))
                            .lineLimit(2)
                        if let price = companion.product.priceText {
                            HStack(spacing: DS.Spacing.xxs) {
                                Text(price).font(.caption)
                                if let discount = companion.product.discountPercent {
                                    Text("-\(discount)%")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                    .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                ShopMatchBadge(match: companion.match)
                if companion.reasons.contains(.checkSize) {
                    Text(String(localized: "shop_reason_check_size"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: DS.Spacing.xxs) {
                Button { onToggleSaveCompanion(companion) } label: {
                    Image(systemName: isCompanionSaved(companion) ? "heart.fill" : "heart")
                        .foregroundStyle(isCompanionSaved(companion) ? Color.pink : Color.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(isCompanionSaved(companion) ? String(localized: "shop_action_unsave") : String(localized: "shop_action_save"))
                Button { onBoughtCompanion(companion) } label: {
                    Label(String(localized: "shop_action_bought"), systemImage: "bag.badge.plus")
                        .font(.caption.weight(.medium))
                        .frame(minHeight: 44)
                }
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            Button { onOpenCompanion(companion) } label: {
                Label(String(localized: "shop_action_open"), systemImage: "arrow.up.right.square")
            }
            Button { onBoughtCompanion(companion) } label: {
                Label(String(localized: "shop_action_bought"), systemImage: "bag.badge.plus")
            }
            Button(role: .destructive) { onDismissCompanion(companion) } label: {
                Label(String(localized: "shop_action_dismiss"), systemImage: "hand.thumbsdown")
            }
        }
    }
}

/// Stable URL-based identity shares decoded photos between card and outfit preview.
struct ShopProductImage: View {
    let product: ShopProduct
    var preferProductOnly = true
    var canRetry = true
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var retry = 0

    private var taskID: String {
        [product.id, product.imageURL?.absoluteString ?? "", product.item.images?.joined(separator: "|") ?? "", String(preferProductOnly), String(retry)].joined(separator: "|")
    }
    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(4)
            } else if isLoading {
                ProgressView().accessibilityLabel(String(localized: "shop_loading"))
            } else {
                VStack(spacing: 4) {
                    Image(systemName: product.category.icon).foregroundStyle(.secondary)
                    if canRetry {
                        Button { retry += 1 } label: { Image(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(String(localized: "shop_photo_retry"))
                    }
                }
            }
        }
        .task(id: taskID) {
            image = nil; isLoading = true
            defer { if !Task.isCancelled { isLoading = false } }
            for attempt in 0..<2 {
                let stream = await ShopProductPhotoService.shared.images(for: product, preferProductOnly: preferProductOnly)
                for await photo in stream {
                    guard !Task.isCancelled else { return }
                    image = photo
                }
                if image != nil || Task.isCancelled { return }
                if attempt == 0 { try? await Task.sleep(for: .seconds(3)) }
            }
        }
    }
}

// MARK: - Stats section

/// The top three picks, shown in Stats under the wardrobe gaps.
struct ShopPicksSection: View {
    let garments: [Garment]
    @Query private var wearEvents: [WearEvent]
    @Query private var recommendationEvents: [RecommendationEvent]

    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var weather: WeatherCenter
    @ObservedObject private var catalog = ShopCatalogService.shared
    @ObservedObject private var feedback = ShopFeedbackStore.shared
    @ObservedObject private var personalSelection = ShopPersonalSelection.shared
    @Query private var users: [UserProfile]
    @Query private var recommendationStates: [RecoState]
    @Query private var upcomingPlans: [DayPlan]
    @AppStorage("shop.includeNextSeasonDeals") private var includeNextSeasonDeals = false
    @State private var picks: [PurchaseScorer.Pick] = []
    @State private var refreshGeneration = 0

    init(garments: [Garment]) {
        self.garments = garments
        _wearEvents = Query(ShopPicksEngine.wearDescriptor())
        _recommendationEvents = Query(ShopPicksEngine.recommendationDescriptor())
        let today = Calendar.current.startOfDay(for: .now)
        let start = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today
        let end = Calendar.current.date(byAdding: .day, value: 14, to: today) ?? today
        _upcomingPlans = Query(filter: #Predicate<DayPlan> { $0.date >= start && $0.date < end }, sort: \.date)
    }

    private var profile: UserProfile? {
        CurrentUser.activeProfile(from: users, userIdentifier: AuthManager.shared.userIdentifier)
    }

    private var personalGarmentCount: Int {
        ShopPicksEngine.personalWardrobe(garments, profile: profile).count
    }

    var body: some View {
        Group {
            if personalGarmentCount >= ShopPicksEngine.minimumWardrobe {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    DSSectionHeader(String(localized: "shop_title"), icon: "bag")
                    Text(String(localized: "shop_section_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if picks.isEmpty {
                        Text(emptyMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                                ForEach(picks.prefix(3)) { pick in
                                    miniCard(pick)
                                }
                            }
                        }
                    }
                    NavigationLink {
                        ShopPicksView()
                            .withLocalAppBackdrop()
                    } label: {
                        Label(String(localized: "shop_see_all"), systemImage: "chevron.forward")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .dsCard()
            }
        }
        .task {
            await catalog.refreshIfNeeded()
        }
        .task(id: "\(rankingSignature)|\(refreshGeneration)|\(scenePhase)") {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, scenePhase == .active else { return }
            await rebuild()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshGeneration += 1 }
        }
    }

    private func miniCard(_ pick: PurchaseScorer.Pick) -> some View {
        Button {
            DS.haptic(0.3)
            feedback.record(.opened, pick: pick)
            openURL(pick.product.url)
        } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                ShopProductImage(product: pick.product, preferProductOnly: profile?.shoppingPreferences.preferProductOnlyPhotos ?? true, canRetry: false)
                    .frame(width: 120, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                Text(pick.product.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let price = pick.product.priceText {
                    HStack(spacing: DS.Spacing.xxs) {
                        Text(price).font(.caption)
                        if let discount = pick.product.discountPercent {
                            Text("-\(discount)%")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                if pick.intent == .nextSeason {
                    Text(String(localized: "shop_filter_next_season"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                if let match = pick.match {
                    Text(String(format: String(localized: "shop_match_percent_format"), match.percent))
                        .font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
                if let reason = pick.reasons.first {
                    Text(ShopPicksEngine.reasonText(reason))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(width: 120, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var emptyMessage: String {
        if catalog.isLoading { return String(localized: "shop_loading") }
        if catalog.products.isEmpty { return String(localized: "shop_empty_catalog") }
        return String(localized: "shop_empty_filter")
    }

    @MainActor private func rebuild() async {
        let signature = rankingSignature
        let result = await ShopPicksEngine.picks(
            products: catalog.products,
            garments: garments,
            wearEvents: wearEvents,
            recommendationEvents: recommendationEvents,
            forecasts: weather.forecasts,
            profile: profile,
            feedback: feedback,
            context: context,
            upcomingPlans: upcomingPlans,
            includeNextSeasonDeals: includeNextSeasonDeals,
            contentSignature: signature
        )
        guard !Task.isCancelled else { return }
        guard signature == rankingSignature else {
            refreshGeneration += 1
            return
        }
        let owned = Set(ShopPicksEngine.personalWardrobe(garments, profile: profile).compactMap(\.shopProductID))
        picks = Array(ShopPersonalSelection.select(from: result.picks.filter { !feedback.isHidden($0.id) },
            profileID: profile?.id, preferences: profile?.shoppingPreferences ?? ShoppingPreferences(),
            isOwned: { feedback.has(.bought, $0) || owned.contains($0) }).prefix(3))
    }

    private var rankingSignature: Int {
        let base = ShopPicksEngine.signature(
            catalogRevision: catalog.revision, garments: garments, wearEvents: wearEvents,
            recommendationEvents: recommendationEvents, forecasts: weather.forecasts,
            users: users, plans: upcomingPlans, feedback: feedback,
            includeNextSeasonDeals: includeNextSeasonDeals
        )
        var hash = Hasher()
        hash.combine(base)
        hash.combine(personalSelection.revision)
        for state in recommendationStates where state.profileID == profile?.id {
            hash.combine(state.lookWeights); hash.combine(state.lookBias); hash.combine(state.lookInteractionCount)
        }
        return hash.finalize()
    }
}
