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
        overridePreferences: ShoppingPreferences? = nil,
        limit: Int = 40
    ) -> [PurchaseScorer.Pick] {
        let wardrobe = personalWardrobe(garments, profile: profile)
        guard wardrobe.count >= minimumWardrobe, !products.isEmpty else { return [] }
        let wardrobeIDs = Set(wardrobe.map(\.id))
        let wears = wearEvents.filter { event in event.garmentIDs.contains { wardrobeIDs.contains($0) } }
        let recommendations = recommendationEvents.filter { $0.profileID == nil || $0.profileID == profile?.id }
        let wear = WardrobeGapAnalyzer.wearSummary(events: wears)
        let taste = TasteAffinityBuilder.build(
            from: wardrobe,
            choiceSignals: TasteAffinityBuilder.choiceSignals(
                wearEvents: wears,
                recommendationEvents: recommendations
            )
        )
        let gaps = WardrobeGapAnalyzer.analyze(WardrobeGapAnalyzer.Input(
            garments: wardrobe,
            wearCounts: wear.counts,
            wearDays: wear.days,
            climate: WardrobeGapAnalyzer.climate(forecasts: forecasts, pastEvents: recommendations),
            pastFormalShare: WardrobeGapAnalyzer.pastFormalShare(recommendations),
            taste: taste,
            checksRotation: true
        ))
        let preferences = overridePreferences ?? profile?.shoppingPreferences ?? ShoppingPreferences()
        let resolution = ShoppingPreferences.resolvedDepartment(profile: profile, garments: wardrobe, feedback: feedback, products: products)
        let input = PurchaseScorer.Input(
            garments: wardrobe,
            wearCounts: wear.counts,
            taste: taste,
            gaps: gaps,
            profile: profile,
            model: feedback.state.model,
            modelContext: context,
            forecasts: forecasts,
            upcomingPlans: upcomingPlans,
            includeNextSeasonDeals: includeNextSeasonDeals,
            feedbackSignals: feedback.signals,
            preferences: preferences,
            department: preferences.department == .automatic ? resolution.department : preferences.department
        )
        return PurchaseScorer.rank(products, input: input, isHidden: { feedback.isHidden($0) }, limit: limit)
    }

    static func personalWardrobe(_ garments: [Garment], profile: UserProfile?) -> [Garment] {
        garments.filter { !$0.isBlocked && ($0.ownerID == nil || $0.ownerID == profile?.id) }
    }

    static func browse(
        products: [ShopProduct], preferences: ShoppingPreferences, feedback: ShopFeedbackStore,
        query: String = "", limit: Int = 100
    ) -> [PurchaseScorer.Pick] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = products.lazy.filter { product in
            guard product.item.available != false, !feedback.isHidden(product.id),
                  preferences.allows(product: product) else { return false }
            if product.hasKnownSizeAvailability, let sizes = product.item.inStockSizes, sizes.isEmpty { return false }
            guard !search.isEmpty else { return true }
            let searchable = [product.title, product.item.brand ?? "", product.storeName].joined(separator: " ")
            return searchable.localizedStandardContains(search)
        }
        .prefix(max(0, limit))
        return Array(matching).map { product in
            PurchaseScorer.Pick(product: product, score: 0, wearsPerMonth: nil, looks: 0, reasons: [.checkSize], features: [])
        }
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
        for garment in garments {
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
            hash.combine(garment.thumbnailPath)
            hash.combine(garment.imagePath)
            hash.combine(garment.photoMetadataRaw)
        }
        for event in wearEvents {
            hash.combine(event.id)
            hash.combine(event.date)
            hash.combine(event.garmentIDs)
            hash.combine(event.occasionRaw)
        }
        for event in recommendationEvents {
            hash.combine(event.id)
            hash.combine(event.profileID)
            hash.combine(event.createdAt)
            hash.combine(event.kindRaw)
            hash.combine(event.selectedGarmentIDs)
            hash.combine(event.shownGarmentIDs)
            hash.combine(event.temperatureC)
            hash.combine(event.wasRaining)
            hash.combine(event.desiredFormality)
            hash.combine(event.warmthSensitivity)
            hash.combine(event.rainTolerance)
            hash.combine(event.lookTimeRaw)
        }
        for forecast in forecasts {
            hash.combine(forecast.date)
            hash.combine(forecast.temperatureC)
            hash.combine(forecast.highTempC)
            hash.combine(forecast.lowTempC)
            hash.combine(forecast.rainProbability)
        }
        for user in users {
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
        for plan in plans {
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

    @Query private var garments: [Garment]
    @Query private var wearEvents: [WearEvent]
    @Query private var recommendationEvents: [RecommendationEvent]
    @Query private var users: [UserProfile]
    @Query private var upcomingPlans: [DayPlan]

    @AppStorage("shop.includeNextSeasonDeals") private var includeNextSeasonDeals = false
    @State private var filter: Filter = .all
    @State private var picks: [PurchaseScorer.Pick] = []
    @State private var mode: Mode = .personalized
    @State private var shoppingPreferencesProfile: UserProfile?
    @State private var showBrowseFilters = false
    @State private var browseQuery = ""
    @State private var browseLimit = 60
    @State private var browsePreferences: ShoppingPreferences = {
        var preferences = ShoppingPreferences()
        preferences.department = .all
        return preferences
    }()

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

    enum Filter: Hashable {
        case all, deals, upcoming, everyday, nextSeason, saved
        case category(Category)
    }

    init(isRoot: Bool = false) {
        self.isRoot = isRoot
        var wears = FetchDescriptor<WearEvent>(sortBy: [SortDescriptor(\WearEvent.date, order: .reverse)])
        wears.fetchLimit = 400
        _wearEvents = Query(wears)
        var events = FetchDescriptor<RecommendationEvent>(sortBy: [SortDescriptor(\RecommendationEvent.createdAt, order: .reverse)])
        events.fetchLimit = 300
        _recommendationEvents = Query(events)
        let today = Calendar.current.startOfDay(for: .now)
        let start = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today
        let end = Calendar.current.date(byAdding: .day, value: 14, to: today) ?? today
        _upcomingPlans = Query(filter: #Predicate<DayPlan> { $0.date >= start && $0.date < end }, sort: \.date)
    }

    private var shown: [PurchaseScorer.Pick] {
        if filter == .saved { return savedPicks }
        if mode == .browse { return browsedPicks }
        switch filter {
        case .all: return picks
        case .deals: return picks.filter { $0.product.discountPercent != nil }
        case .upcoming: return picks.filter { $0.intent == .upcoming }
        case .everyday: return picks.filter { $0.intent == .everyday }
        case .nextSeason: return picks.filter { $0.intent == .nextSeason }
        case .category(let category): return picks.filter { $0.product.category == category }
        case .saved: return savedPicks
        }
    }

    private var browsedPicks: [PurchaseScorer.Pick] {
        let products = catalog.products.filter { product in
            switch filter {
            case .category(let category): return product.category == category
            case .deals: return product.discountPercent != nil
            default: return true
            }
        }
        return ShopPicksEngine.browse(
            products: products, preferences: browsePreferences, feedback: feedback,
            query: browseQuery, limit: browseLimit
        )
    }

    private var profile: UserProfile? {
        CurrentUser.activeProfile(from: users, userIdentifier: AuthManager.shared.userIdentifier)
    }

    private var personalGarmentCount: Int {
        ShopPicksEngine.personalWardrobe(garments, profile: profile).count
    }

    /// Saved products, scored like the rest when still in the catalog.
    private var savedPicks: [PurchaseScorer.Pick] {
        let ranked = mode == .personalized ? picks : []
        let byID = Dictionary(ranked.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return feedback.savedIDs.compactMap { id in
            if let pick = byID[id] { return pick }
            let current = catalog.products.first { $0.id == id }
            let kept = feedback.keptItem(id).flatMap { item in
                ShopCatalogService.map(item, storeName: storeName(for: item))
            }
            guard let product = current ?? kept else { return nil }
            return PurchaseScorer.Pick(product: product, score: 0, wearsPerMonth: nil, looks: 0, reasons: [.checkSize], features: [])
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
                Button {
                    shoppingPreferencesProfile = profile
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel(String(localized: "shop_preferences_title"))
                .disabled(profile == nil)
            }
        }
        .sheet(item: $shoppingPreferencesProfile) { profile in
            ShoppingPreferencesView(profile: profile)
        }
        .sheet(isPresented: $showBrowseFilters) {
            ShopBrowseFiltersView(preferences: $browsePreferences)
        }
        .task {
            await catalog.refreshIfNeeded()
        }
        .task(id: rankingSignature) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            rebuild()
        }
        .refreshable {
            await catalog.refreshIfNeeded(force: true)
        }
        .onChange(of: includeNextSeasonDeals) { _, enabled in
            if !enabled, filter == .nextSeason { filter = .all }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { rebuild() }
        }
        .onChange(of: mode) { _, _ in
            filter = .all
            browseLimit = 60
        }
        .onChange(of: browseQuery) { _, _ in browseLimit = 60 }
        .onChange(of: browsePreferences) { _, _ in browseLimit = 60 }
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
                } else if let department = resolution.department {
                    Button {
                        shoppingPreferencesProfile = profile
                    } label: {
                        Text(String(format: String(localized: "shop_preferences_summary_format"), department.title))
                            .font(.caption)
                    }
                }
                Toggle(isOn: $includeNextSeasonDeals) {
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        Text(String(localized: "shop_next_season_toggle"))
                            .font(.subheadline.weight(.medium))
                        Text(String(localized: "shop_next_season_detail"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.accentColor)
                .padding(.top, DS.Spacing.xs)
            } else {
                browseControls
                Text(browsePreferences.department.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Button { showBrowseFilters = true } label: {
                Label(String(localized: "shop_browse_filters"), systemImage: "line.3.horizontal.decrease")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.plain)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                chip(String(localized: mode == .personalized ? "shop_filter_all" : "shop_browse_all"), .all)
                chip(String(localized: "shop_filter_deals"), .deals, icon: "tag")
                if mode == .personalized {
                    chip(String(localized: "shop_filter_upcoming"), .upcoming, icon: "calendar")
                    chip(String(localized: "shop_filter_everyday"), .everyday, icon: "repeat")
                }
                ForEach(Category.allCases) { category in
                    chip(category.title, .category(category))
                }
                if mode == .personalized, includeNextSeasonDeals {
                    chip(String(localized: "shop_filter_next_season"), .nextSeason, icon: "leaf")
                }
                chip(String(localized: "shop_filter_saved"), .saved, icon: "heart.fill")
            }
        }
    }

    private func chip(_ title: String, _ value: Filter, icon: String? = nil) -> some View {
        let selected = filter == value
        return Button {
            DS.haptic(0.3)
            filter = value
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
        if filter == .saved {
            if shown.isEmpty {
                emptyState(icon: "heart", text: String(localized: "shop_empty_saved"))
            } else {
                pickList
            }
        } else if mode == .personalized, personalGarmentCount < ShopPicksEngine.minimumWardrobe {
            emptyState(icon: "tshirt", text: String(localized: "shop_empty_wardrobe"))
        } else if catalog.products.isEmpty {
            if catalog.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, DS.Spacing.xl)
            } else {
                emptyState(icon: "bag", text: String(localized: "shop_empty_catalog"))
            }
        } else if shown.isEmpty {
            emptyState(icon: "sparkle.magnifyingglass", text: String(localized: mode == .personalized ? "shop_empty_filter" : "shop_browse_empty"))
        } else {
            pickList
        }
    }

    private var pickList: some View {
        LazyVStack(spacing: DS.Spacing.sm) {
            ForEach(shown) { pick in
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
                    isCompanionSaved: { feedback.has(.saved, $0.id) }
                )
            }
            if mode == .browse, filter != .saved, shown.count >= browseLimit {
                Button(String(localized: "shop_browse_more")) { browseLimit += 60 }
                    .font(.subheadline.weight(.semibold))
                    .padding(.vertical, DS.Spacing.sm)
            }
        }
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

    private func record(_ kind: ShopFeedbackKind, _ pick: PurchaseScorer.Pick) {
        DS.haptic(0.4)
        feedback.record(kind, pick: pick)
        withAnimation(.snappy) {
            // A companion can replace an owned core piece. Remove that whole preview
            // until the debounced rebuild supplies a complete look without this product.
            picks.removeAll { candidate in
                candidate.id == pick.id || candidate.preview?.companions.contains(where: { $0.id == pick.id }) == true
            }
        }
    }

    private func rebuild() {
        picks = ShopPicksEngine.picks(
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
            limit: 60
        )
    }

    private var rankingSignature: Int {
        ShopPicksEngine.signature(
            catalogRevision: catalog.revision, garments: garments, wearEvents: wearEvents,
            recommendationEvents: recommendationEvents, forecasts: weather.forecasts,
            users: users, plans: upcomingPlans, feedback: feedback,
            includeNextSeasonDeals: includeNextSeasonDeals
        )
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
    @State private var draft: ShoppingPreferences
    @State private var brands: String

    init(preferences: Binding<ShoppingPreferences>) {
        _preferences = preferences
        _draft = State(initialValue: preferences.wrappedValue)
        _brands = State(initialValue: preferences.wrappedValue.preferredBrands.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                ShopPreferenceFields(preferences: $draft, brands: $brands, isManual: true)
                Section {
                    Button(String(localized: "shop_browse_reset")) {
                        draft = ShoppingPreferences()
                        draft.department = .all
                        brands = ""
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(String(localized: "shop_browse_filters"))
            .compactNavBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "shop_browse_apply")) {
                        draft.preferredBrands = ShopPreferenceFields.brandValues(brands)
                        preferences = draft
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

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                Button(action: onOpen) {
                    ShopProductImage(product: pick.product, preferProductOnly: preferProductOnlyPhotos)
                        .frame(width: 104, height: 138)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pick.product.title)

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
            if let preview = pick.preview {
                ShopLookPreview(
                    pick: pick, preview: preview, garments: garments,
                    preferProductOnlyPhotos: preferProductOnlyPhotos,
                    onOpenCompanion: onOpenCompanion,
                    onToggleSaveCompanion: onToggleSaveCompanion,
                    onDismissCompanion: onDismissCompanion,
                    onBoughtCompanion: onBoughtCompanion,
                    isCompanionSaved: isCompanionSaved
                )
            }
            actions
        }
        .dsCard(padding: DS.Spacing.sm)
        .contextMenu {
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
                        Button { onOpenCompanion(companion) } label: {
                            productTile(companion.product)
                        }
                        .buttonStyle(.plain)
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
            Button { onOpenCompanion(companion) } label: {
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
                    if companion.reasons.contains(.checkSize) {
                        Text(String(localized: "shop_reason_check_size"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
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

/// Remote product photo with a quiet placeholder.
struct ShopProductImage: View {
    let product: ShopProduct
    var preferProductOnly = true
    @State private var image: UIImage?

    private var taskID: String {
        [product.id, product.imageURL?.absoluteString ?? "", product.item.images?.joined(separator: "|") ?? "", product.item.fetchedAt ?? "", String(preferProductOnly)].joined(separator: "|")
    }

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(4)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .overlay(Image(systemName: preferProductOnly ? product.category.icon : "photo").foregroundStyle(.secondary))
            }
        }
        .task(id: taskID) {
            image = nil
            let loaded = await ShopProductPhotoService.shared.image(for: product, preferProductOnly: preferProductOnly)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

// MARK: - Stats section

/// The top three picks, shown in Stats under the wardrobe gaps.
struct ShopPicksSection: View {
    let garments: [Garment]
    let wearEvents: [WearEvent]
    let recommendationEvents: [RecommendationEvent]

    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var weather: WeatherCenter
    @ObservedObject private var catalog = ShopCatalogService.shared
    @ObservedObject private var feedback = ShopFeedbackStore.shared
    @Query private var users: [UserProfile]
    @Query private var upcomingPlans: [DayPlan]
    @AppStorage("shop.includeNextSeasonDeals") private var includeNextSeasonDeals = false
    @State private var picks: [PurchaseScorer.Pick] = []

    init(garments: [Garment], wearEvents: [WearEvent], recommendationEvents: [RecommendationEvent]) {
        self.garments = garments
        self.wearEvents = wearEvents
        self.recommendationEvents = recommendationEvents
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
        .task(id: rankingSignature) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            rebuild()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { rebuild() }
        }
    }

    private func miniCard(_ pick: PurchaseScorer.Pick) -> some View {
        Button {
            DS.haptic(0.3)
            feedback.record(.opened, pick: pick)
            openURL(pick.product.url)
        } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                ShopProductImage(product: pick.product, preferProductOnly: profile?.shoppingPreferences.preferProductOnlyPhotos ?? true)
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

    private func rebuild() {
        picks = ShopPicksEngine.picks(
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
            limit: 3
        )
    }

    private var rankingSignature: Int {
        ShopPicksEngine.signature(
            catalogRevision: catalog.revision, garments: garments, wearEvents: wearEvents,
            recommendationEvents: recommendationEvents, forecasts: weather.forecasts,
            users: users, plans: upcomingPlans, feedback: feedback,
            includeNextSeasonDeals: includeNextSeasonDeals
        )
    }
}
