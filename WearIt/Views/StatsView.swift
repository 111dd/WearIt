import SwiftUI
import SwiftData

struct StatsView: View {
    @Query private var garments: [Garment]
    @Query private var wearEvents: [WearEvent]
    @Query private var dismissedOutfits: [DismissedOutfit]

    @State private var snapshot = StatsSnapshot.empty

    init() {
        _garments = Query(sort: [SortDescriptor(\Garment.createdAt, order: .reverse)])

        var wears = FetchDescriptor<WearEvent>(
            sortBy: [SortDescriptor(\WearEvent.date, order: .reverse)]
        )
        wears.fetchLimit = 200
        _wearEvents = Query(wears)

        var dismissed = FetchDescriptor<DismissedOutfit>()
        dismissed.fetchLimit = 100
        _dismissedOutfits = Query(dismissed)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.md) {
                statsCards
                tasteColorsSection
                tasteBrandsSection
                favoriteCombosSection
                categoryBreakdown
                unwornItemsSection
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.sm)
            .padding(.bottom, 100)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(String(localized: "stats_title"))
        .minimalCollapsingNavBar()
        .onAppear { rebuildSnapshot() }
        .onChange(of: garments.count) { _, _ in rebuildSnapshot() }
        .onChange(of: wearEvents.count) { _, _ in rebuildSnapshot() }
        .onChange(of: dismissedOutfits.count) { _, _ in rebuildSnapshot() }
    }
    
    // MARK: - Stats Cards
    
    private var statsCards: some View {
        HStack(spacing: DS.Spacing.sm) {
            StatCard(
                icon: "tshirt.fill",
                iconColor: .accentColor,
                title: String(localized: "stats_total_items"),
                value: "\(garments.count)"
            )
            
            StatCard(
                icon: "heart.fill",
                iconColor: .pink,
                title: String(localized: "stats_avg_love"),
                value: String(format: "%.0f", averageLove)
            )
            
            StatCard(
                icon: "arrow.clockwise",
                iconColor: .orange,
                title: String(localized: "stats_active"),
                value: "\(recentlyWorn)"
            )
        }
    }

    // MARK: - Taste: Colors

    private var tasteColorsSection: some View {
        let rows = topColors
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    DSSectionHeader(String(localized: "stats_top_colors"), icon: "paintpalette.fill")
                    Text(String(localized: "stats_top_colors_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(rows, id: \.tag) { row in
                        HStack(spacing: DS.Spacing.sm) {
                            Circle()
                                .fill(row.tag.color)
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                            Text(row.tag.title)
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "%.0f%%", row.share * 100))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .dsCard()
            }
        }
    }

    // MARK: - Taste: Brands

    private var tasteBrandsSection: some View {
        let rows = topBrands
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    DSSectionHeader(String(localized: "stats_top_brands"), icon: "tag.fill")
                    Text(String(localized: "stats_top_brands_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(rows, id: \.name) { row in
                        HStack {
                            Text(row.name)
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "%.0f%%", row.share * 100))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .dsCard()
            }
        }
    }

    // MARK: - Favorite combinations

    private var favoriteCombosSection: some View {
        let rows = topCombos
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    DSSectionHeader(String(localized: "stats_favorite_combos"), icon: "link")
                    Text(String(localized: "stats_favorite_combos_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(rows) { row in
                        HStack(spacing: DS.Spacing.sm) {
                            DSGarmentThumbnail(row.left, size: .small)
                            Image(systemName: "plus")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tertiary)
                            DSGarmentThumbnail(row.right, size: .small)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.left.displayTitle)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Text(row.right.displayTitle)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, DS.Spacing.xxs)
                    }
                }
                .dsCard()
            }
        }
    }
    
    // MARK: - Category Breakdown
    
    private var categoryBreakdown: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "stats_by_category"), icon: "square.grid.2x2")
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DS.Spacing.xs) {
                ForEach(categoryCounts, id: \.0) { category, count in
                    HStack {
                        Image(systemName: category.icon)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        
                        Text(category.title)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        
                        Spacer()
                        
                        Text("\(count)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, DS.Spacing.xs)
                    .padding(.horizontal, DS.Spacing.sm)
                    .background(Color(.systemGray6).opacity(0.5), in: RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
                }
            }
        }
        .dsCard()
    }
    
    // MARK: - Stale Items
    
    private var unwornItemsSection: some View {
        let countText = String(
            format: NSLocalizedString("stats_unworn_count_format", comment: ""),
            unworn.count
        )
        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "stats_unworn_title"), icon: "clock.fill")
            Text(countText)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            if unworn.isEmpty {
                Text(String(localized: "stats_unworn_empty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DS.Spacing.lg)
            } else {
                ForEach(unworn.prefix(8)) { garment in
                    StaleItemRow(garment: garment, daysText: daysText(for: garment))
                }
            }
        }
        .dsCard()
    }

    // MARK: - Computed (from snapshot — rebuilt only when queries change)

    private var topColors: [(tag: ColorTag, share: Double)] { snapshot.topColors }
    private var topBrands: [(name: String, share: Double)] { snapshot.topBrands }
    private var topCombos: [ComboRow] { snapshot.topCombos }
    private var averageLove: Double { snapshot.averageLove }
    private var recentlyWorn: Int { snapshot.recentlyWorn }
    private var unworn: [Garment] { snapshot.unworn }
    private var categoryCounts: [(Category, Int)] { snapshot.categoryCounts }

    private func daysText(for g: Garment) -> String {
        guard let date = snapshot.lastWornByGarment[g.id] else {
            return String(localized: "stats_never_worn")
        }
        let days = daysSinceLastWorn(date)
        if days == 0 { return String(localized: "stats_today") }
        if days == 1 { return String(localized: "stats_1_day_ago") }
        return String(format: NSLocalizedString("stats_days_ago", comment: ""), days)
    }

    private func daysSinceLastWorn(_ date: Date?) -> Int {
        guard let date else { return Int.max }
        return Calendar.current.dateComponents([.day], from: date, to: .now).day ?? 0
    }

    private func rebuildSnapshot() {
        snapshot = StatsSnapshot.build(
            garments: garments,
            wearEvents: wearEvents,
            dismissed: dismissedOutfits
        )
    }
}

private struct StatsSnapshot {
    var topColors: [(tag: ColorTag, share: Double)]
    var topBrands: [(name: String, share: Double)]
    var topCombos: [ComboRow]
    var averageLove: Double
    var recentlyWorn: Int
    var unworn: [Garment]
    var categoryCounts: [(Category, Int)]
    var lastWornByGarment: [UUID: Date]

    static let empty = StatsSnapshot(
        topColors: [],
        topBrands: [],
        topCombos: [],
        averageLove: 0,
        recentlyWorn: 0,
        unworn: [],
        categoryCounts: [],
        lastWornByGarment: [:]
    )

    static func build(
        garments: [Garment],
        wearEvents: [WearEvent],
        dismissed: [DismissedOutfit]
    ) -> StatsSnapshot {
        let taste = TasteAffinityBuilder.build(from: garments)
        let combination = CombinationAffinityBuilder.build(
            wearEvents: wearEvents,
            dismissed: dismissed
        )
        let byID = Dictionary(uniqueKeysWithValues: garments.map { ($0.id, $0) })

        let keyToName: [String: String] = {
            var map: [String: String] = [:]
            for garment in garments {
                guard let brand = garment.brand?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !brand.isEmpty else { continue }
                let key = BrandStore.normalizeBrandKey(brand)
                if map[key] == nil { map[key] = brand }
            }
            return map
        }()

        let topColors = taste.colorShares(limit: 5)
        let topBrands = taste.brandShares(limit: 5).compactMap { row -> (name: String, share: Double)? in
            guard let name = keyToName[row.key] else { return nil }
            return (name: name, share: row.share)
        }
        let topCombos = combination.topPositivePairs(limit: 5).compactMap { pair -> ComboRow? in
            guard let parsed = CombinationAffinity.parsePairKey(pair.key),
                  let left = byID[parsed.0],
                  let right = byID[parsed.1] else { return nil }
            return ComboRow(id: pair.key, left: left, right: right, score: pair.score)
        }

        let averageLove: Double = {
            guard !garments.isEmpty else { return 0 }
            let sum = garments.reduce(0) { $0 + $1.loveScore }
            return Double(sum) / Double(garments.count)
        }()

        var lastWorn: [UUID: Date] = [:]
        for event in wearEvents where event.source != .calendarBlock {
            for id in event.garmentIDs {
                if let existing = lastWorn[id] {
                    if event.date > existing { lastWorn[id] = event.date }
                } else {
                    lastWorn[id] = event.date
                }
            }
        }

        let recentCutoff = Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .now
        let recentlyWorn = Set(lastWorn.filter { $0.value >= recentCutoff }.map(\.key)).count

        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        let unworn = garments.filter { garment in
            guard let last = lastWorn[garment.id] else { return true }
            return last < cutoff
        }
        .sorted { a, b in
            let da = daysSince(lastWorn[a.id])
            let db = daysSince(lastWorn[b.id])
            if da != db { return da > db }
            return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
        }

        var counts: [Category: Int] = [:]
        for garment in garments {
            counts[garment.category, default: 0] += 1
        }
        let categoryCounts = Category.allCases.compactMap { category -> (Category, Int)? in
            let count = counts[category] ?? 0
            return count > 0 ? (category, count) : nil
        }

        return StatsSnapshot(
            topColors: topColors,
            topBrands: topBrands,
            topCombos: topCombos,
            averageLove: averageLove,
            recentlyWorn: recentlyWorn,
            unworn: unworn,
            categoryCounts: categoryCounts,
            lastWornByGarment: lastWorn
        )
    }

    private static func daysSince(_ date: Date?) -> Int {
        guard let date else { return Int.max }
        return Calendar.current.dateComponents([.day], from: date, to: .now).day ?? 0
    }
}

private struct ComboRow: Identifiable {
    let id: String
    let left: Garment
    let right: Garment
    let score: Double
}

// MARK: - Stat Card

private struct StatCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String
    
    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: DS.IconSize.lg))
                .foregroundStyle(iconColor)
            
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
            
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .dsCard(padding: DS.Spacing.sm)
    }
}

// MARK: - Stale Item Row

private struct StaleItemRow: View {
    let garment: Garment
    let daysText: String
    
    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            DSGarmentThumbnail(garment, size: .small)
            
            Text(garment.displayTitle)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
                .foregroundStyle(.primary)
            
            Spacer()
            
            Text(daysText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.xxs)
                .background(Color(.systemGray6), in: Capsule())
        }
        .padding(.vertical, DS.Spacing.xxs)
    }
}
