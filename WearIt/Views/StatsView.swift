import SwiftUI
import SwiftData

struct StatsView: View {
    @Query private var garments: [Garment]
    @Query private var wearEvents: [WearEvent]

    init() {
        _garments = Query(sort: [SortDescriptor(\Garment.createdAt, order: .reverse)])
        _wearEvents = Query(sort: [SortDescriptor(\WearEvent.date, order: .reverse)])
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidGlassBackdrop()
                
                ScrollView {
                    VStack(spacing: DS.Spacing.md) {
                        // Quick Stats
                        statsCards
                        
                        // Category Breakdown
                        categoryBreakdown
                        
                        // Stale Items
                        staleItemsSection
                    }
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.top, DS.Spacing.sm)
                    .padding(.bottom, 100)
                }
            }
            .navigationTitle("Stats")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    // MARK: - Stats Cards
    
    private var statsCards: some View {
        HStack(spacing: DS.Spacing.sm) {
            StatCard(
                icon: "tshirt.fill",
                iconColor: .accentColor,
                title: "Items",
                value: "\(garments.count)"
            )
            
            StatCard(
                icon: "heart.fill",
                iconColor: .pink,
                title: "Avg Love",
                value: String(format: "%.0f", averageLove)
            )
            
            StatCard(
                icon: "arrow.clockwise",
                iconColor: .orange,
                title: "Active",
                value: "\(recentlyWorn)"
            )
        }
    }
    
    // MARK: - Category Breakdown
    
    private var categoryBreakdown: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader("By Category", icon: "square.grid.2x2")
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DS.Spacing.xs) {
                ForEach(Category.allCases) { category in
                    let count = garments.filter { $0.category == category }.count
                    if count > 0 {
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
        }
        .dsCard()
    }
    
    // MARK: - Stale Items
    
    private var staleItemsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader("Haven't worn lately", icon: "clock.fill")
            
            if stale.isEmpty {
                Text("All items worn recently!")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DS.Spacing.lg)
            } else {
                ForEach(stale.prefix(8)) { garment in
                    StaleItemRow(garment: garment, daysText: daysText(for: garment))
                }
            }
        }
        .dsCard()
    }

    // MARK: - Computed

    private var averageLove: Double {
        guard !garments.isEmpty else { return 0 }
        let sum = garments.reduce(0) { $0 + $1.loveScore }
        return Double(sum) / Double(garments.count)
    }
    
    private var lastWornByGarment: [UUID: Date] {
        var map: [UUID: Date] = [:]
        for event in wearEvents where event.source != .calendarBlock {
            for id in event.garmentIDs {
                if let existing = map[id] {
                    if event.date > existing { map[id] = event.date }
                } else {
                    map[id] = event.date
                }
            }
        }
        return map
    }

    private var recentlyWorn: Int {
        let recentCutoff = Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .now
        let recentIDs = lastWornByGarment.filter { $0.value >= recentCutoff }.map { $0.key }
        return Set(recentIDs).count
    }

    private var stale: [Garment] {
        garments.sorted { a, b in
            let da = daysSinceLastWorn(lastWornByGarment[a.id])
            let db = daysSinceLastWorn(lastWornByGarment[b.id])
            if da != db { return da > db }
            return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
        }
    }

    private func daysSinceLastWorn(_ date: Date?) -> Int {
        guard let date else { return Int.max }
        return Calendar.current.dateComponents([.day], from: date, to: .now).day ?? 0
    }

    private func daysText(for g: Garment) -> String {
        guard let date = lastWornByGarment[g.id] else { return "Never" }
        let days = daysSinceLastWorn(date)
        if days == 0 { return "Today" }
        if days == 1 { return "1d ago" }
        return "\(days)d ago"
    }
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
