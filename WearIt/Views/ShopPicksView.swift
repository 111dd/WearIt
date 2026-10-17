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
        gender: ShopGender,
        feedback: ShopFeedbackStore,
        context: ModelContext,
        limit: Int = 40
    ) -> [PurchaseScorer.Pick] {
        guard garments.count >= minimumWardrobe, !products.isEmpty else { return [] }
        let wear = WardrobeGapAnalyzer.wearSummary(events: wearEvents)
        let taste = TasteAffinityBuilder.build(
            from: garments,
            choiceSignals: TasteAffinityBuilder.choiceSignals(
                wearEvents: wearEvents,
                recommendationEvents: recommendationEvents
            )
        )
        let gaps = WardrobeGapAnalyzer.analyze(WardrobeGapAnalyzer.Input(
            garments: garments,
            wearCounts: wear.counts,
            wearDays: wear.days,
            climate: WardrobeGapAnalyzer.climate(forecasts: forecasts, pastEvents: recommendationEvents),
            pastFormalShare: WardrobeGapAnalyzer.pastFormalShare(recommendationEvents),
            taste: taste,
            checksRotation: true
        ))
        let input = PurchaseScorer.Input(
            garments: garments,
            wearCounts: wear.counts,
            taste: taste,
            gaps: gaps,
            profile: profile,
            gender: gender,
            model: feedback.state.model,
            modelContext: context
        )
        return PurchaseScorer.rank(products, input: input, isHidden: { feedback.isHidden($0) }, limit: limit)
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
        }
    }

    static func wearsText(_ pick: PurchaseScorer.Pick) -> String? {
        guard let wears = pick.wearsPerMonth, wears >= 0.5 else { return nil }
        let rounded = max(1, Int(wears.rounded()))
        return String(format: NSLocalizedString("shop_wears_per_month_format", comment: ""), rounded)
    }
}

// MARK: - Full screen

struct ShopPicksView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var weather: WeatherCenter
    @ObservedObject private var catalog = ShopCatalogService.shared
    @ObservedObject private var feedback = ShopFeedbackStore.shared

    @Query private var garments: [Garment]
    @Query private var wearEvents: [WearEvent]
    @Query private var recommendationEvents: [RecommendationEvent]
    @Query private var users: [UserProfile]

    @AppStorage("shop.gender") private var genderRaw = ShopGender.all.rawValue
    @State private var filter: Filter = .all
    @State private var picks: [PurchaseScorer.Pick] = []

    enum Filter: Hashable {
        case all, saved
        case category(Category)
    }

    init() {
        var wears = FetchDescriptor<WearEvent>(sortBy: [SortDescriptor(\WearEvent.date, order: .reverse)])
        wears.fetchLimit = 400
        _wearEvents = Query(wears)
        var events = FetchDescriptor<RecommendationEvent>(sortBy: [SortDescriptor(\RecommendationEvent.createdAt, order: .reverse)])
        events.fetchLimit = 300
        _recommendationEvents = Query(events)
    }

    private var gender: ShopGender { ShopGender(rawValue: genderRaw) ?? .all }

    private var shown: [PurchaseScorer.Pick] {
        switch filter {
        case .all: return picks
        case .category(let category): return picks.filter { $0.product.category == category }
        case .saved: return savedPicks
        }
    }

    /// Saved products, scored like the rest when still in the catalog.
    private var savedPicks: [PurchaseScorer.Pick] {
        let byID = Dictionary(picks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return feedback.savedIDs.compactMap { id in
            if let pick = byID[id] { return pick }
            let item = catalog.products.first { $0.id == id }?.item ?? feedback.keptItem(id)
            guard let item, let product = ShopCatalogService.map(item, storeName: storeName(for: item)) else { return nil }
            return PurchaseScorer.Pick(product: product, score: 0, wearsPerMonth: nil, looks: 0, reasons: [], features: [])
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
        .navigationTitle(String(localized: "shop_title"))
        .compactNavBar()
        .task {
            await catalog.refreshIfNeeded()
            rebuild()
        }
        .refreshable {
            await catalog.refreshIfNeeded(force: true)
            rebuild()
        }
        .onChange(of: catalog.products.count) { _, _ in rebuild() }
        .onChange(of: genderRaw) { _, _ in rebuild() }
        .onChange(of: garments.count) { _, _ in rebuild() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(String(localized: "shop_subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(String(localized: "shop_gender_label"), selection: $genderRaw) {
                ForEach(ShopGender.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                chip(String(localized: "shop_filter_all"), .all)
                ForEach([Category.top, .bottom, .shoes, .outer], id: \.self) { category in
                    chip(category.title, .category(category))
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
    }

    @ViewBuilder
    private var content: some View {
        if garments.count < ShopPicksEngine.minimumWardrobe {
            emptyState(icon: "tshirt", text: String(localized: "shop_empty_wardrobe"))
        } else if catalog.products.isEmpty {
            if catalog.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, DS.Spacing.xl)
            } else {
                emptyState(icon: "bag", text: String(localized: "shop_empty_catalog"))
            }
        } else if shown.isEmpty {
            emptyState(
                icon: filter == .saved ? "heart" : "sparkle.magnifyingglass",
                text: filter == .saved ? String(localized: "shop_empty_saved") : String(localized: "shop_empty_filter")
            )
        } else {
            LazyVStack(spacing: DS.Spacing.sm) {
                ForEach(shown) { pick in
                    ShopPickCard(
                        pick: pick,
                        isSaved: feedback.has(.saved, pick.id),
                        onOpen: { open(pick) },
                        onToggleSave: { toggleSave(pick) },
                        onDismiss: { record(.dismissed, pick) },
                        onBought: { record(.bought, pick) }
                    )
                }
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
        if !pick.features.isEmpty { feedback.record(.opened, pick: pick) }
        openURL(pick.product.url)
    }

    private func toggleSave(_ pick: PurchaseScorer.Pick) {
        DS.haptic(0.4)
        if feedback.has(.saved, pick.id) {
            feedback.unsave(pick.id)
        } else if !pick.features.isEmpty {
            feedback.record(.saved, pick: pick)
        }
    }

    private func record(_ kind: ShopFeedbackKind, _ pick: PurchaseScorer.Pick) {
        DS.haptic(0.4)
        guard !pick.features.isEmpty else {
            if kind == .dismissed { feedback.unsave(pick.id) }
            return
        }
        feedback.record(kind, pick: pick)
        withAnimation(.snappy) {
            picks.removeAll { $0.id == pick.id }
        }
    }

    private func rebuild() {
        picks = ShopPicksEngine.picks(
            products: catalog.products,
            garments: garments,
            wearEvents: wearEvents,
            recommendationEvents: recommendationEvents,
            forecasts: weather.forecasts,
            profile: CurrentUser.activeProfile(from: users, userIdentifier: AuthManager.shared.userIdentifier),
            gender: gender,
            feedback: feedback,
            context: context
        )
    }

    private func storeName(for item: ShopCatalogItem) -> String {
        catalog.products.first { $0.item.store == item.store }?.storeName ?? item.store
    }
}

// MARK: - Card

struct ShopPickCard: View {
    let pick: PurchaseScorer.Pick
    let isSaved: Bool
    var onOpen: () -> Void
    var onToggleSave: () -> Void
    var onDismiss: () -> Void
    var onBought: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            ShopProductImage(url: pick.product.imageURL)
                .frame(width: 104, height: 138)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                .onTapGesture(perform: onOpen)

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
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
                ForEach(pick.reasons.prefix(2), id: \.self) { reason in
                    Text(ShopPicksEngine.reasonText(reason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                actions
            }
            Spacer(minLength: 0)
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
            if let percent = pick.product.discountPercent, let original = pick.product.originalPrice {
                Text(original, format: .number.precision(.fractionLength(0)))
                    .font(.caption)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                Text("-\(percent)%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: DS.Spacing.md) {
            Button(action: onOpen) {
                Label(String(localized: "shop_action_open"), systemImage: "arrow.up.right.square")
                    .font(.caption.weight(.semibold))
            }
            Button(action: onToggleSave) {
                Image(systemName: isSaved ? "heart.fill" : "heart")
                    .foregroundStyle(isSaved ? Color.pink : Color.secondary)
            }
            .accessibilityLabel(isSaved ? String(localized: "shop_action_unsave") : String(localized: "shop_action_save"))
            Button(action: onDismiss) {
                Text(String(localized: "shop_action_dismiss"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
    }
}

/// Remote product photo with a quiet placeholder.
struct ShopProductImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
            }
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
    @EnvironmentObject private var weather: WeatherCenter
    @ObservedObject private var catalog = ShopCatalogService.shared
    @ObservedObject private var feedback = ShopFeedbackStore.shared
    @Query private var users: [UserProfile]
    @AppStorage("shop.gender") private var genderRaw = ShopGender.all.rawValue
    @State private var picks: [PurchaseScorer.Pick] = []

    var body: some View {
        Group {
            if garments.count >= ShopPicksEngine.minimumWardrobe {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    DSSectionHeader(String(localized: "shop_title"), icon: "bag")
                    Text(String(localized: "shop_section_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if picks.isEmpty {
                        Text(catalog.isLoading ? String(localized: "shop_loading") : String(localized: "shop_empty_catalog"))
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
            rebuild()
        }
        .onChange(of: catalog.products.count) { _, _ in rebuild() }
        .onChange(of: garments.count) { _, _ in rebuild() }
    }

    private func miniCard(_ pick: PurchaseScorer.Pick) -> some View {
        Button {
            DS.haptic(0.3)
            feedback.record(.opened, pick: pick)
            openURL(pick.product.url)
        } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                ShopProductImage(url: pick.product.imageURL)
                    .frame(width: 120, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                Text(pick.product.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let price = pick.product.priceText {
                    Text(price).font(.caption)
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

    private func rebuild() {
        picks = ShopPicksEngine.picks(
            products: catalog.products,
            garments: garments,
            wearEvents: wearEvents,
            recommendationEvents: recommendationEvents,
            forecasts: weather.forecasts,
            profile: CurrentUser.activeProfile(from: users, userIdentifier: AuthManager.shared.userIdentifier),
            gender: ShopGender(rawValue: genderRaw) ?? .all,
            feedback: feedback,
            context: context,
            limit: 3
        )
    }
}
