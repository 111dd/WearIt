import Foundation

enum AvailabilityStatus: Equatable {
    case available
    case worn
    case unavailable
    case cooldown(daysRemaining: Int)
}

enum AvailabilityService {
    struct AvailabilityItem: Identifiable {
        let garment: Garment
        let status: AvailabilityStatus

        var id: UUID { garment.id }
    }

    static func availabilityStatus(
        for garment: Garment,
        on date: Date,
        ctx: RecoContext,
        latestWearMap: [UUID: Date]
    ) -> AvailabilityStatus {
        if garment.isCurrentlyUnavailable {
            return .unavailable
        }

        // Source of truth is WearEvent / lastWorn map — not the legacy Garment.isWorn flag.
        if isWornOnDate(garmentID: garment.id, date: date, latestWearMap: latestWearMap) {
            return .worn
        }

        let cooldown = cooldownDays(for: garment.category, ctx: ctx)
        if cooldown > 0,
           let daysSince = daysSinceWorn(garmentID: garment.id, referenceDate: date, latestWearMap: latestWearMap),
           daysSince < cooldown {
            let remaining = max(0, cooldown - daysSince)
            return .cooldown(daysRemaining: remaining)
        }

        return .available
    }

    static func isRecommendedEligible(_ status: AvailabilityStatus) -> Bool {
        if case .available = status { return true }
        return false
    }

    static func cooldownDays(for category: Category, ctx: RecoContext) -> Int {
        switch category {
        case .top, .bottom, .shoes:
            return 2
        case .outer:
            if ctx.isRaining || ctx.temperatureC <= 12 {
                return 0
            }
            return 0
        case .accessory:
            return 0
        }
    }

    static func daysSinceWorn(
        garmentID: UUID,
        referenceDate: Date,
        latestWearMap: [UUID: Date]
    ) -> Int? {
        guard let lastWorn = latestWearMap[garmentID] else { return nil }
        let calendar = Calendar.current
        let startRef = calendar.startOfDay(for: referenceDate)
        let startLast = calendar.startOfDay(for: lastWorn)
        let days = calendar.dateComponents([.day], from: startLast, to: startRef).day ?? 0
        return max(0, days)
    }

    static func isWornOnDate(
        garmentID: UUID,
        date: Date,
        latestWearMap: [UUID: Date]
    ) -> Bool {
        guard let lastWorn = latestWearMap[garmentID] else { return false }
        let calendar = Calendar.current
        return calendar.isDate(lastWorn, inSameDayAs: date)
    }

    static func statusSortRank(_ status: AvailabilityStatus) -> Int {
        switch status {
        case .available: return 0
        case .cooldown: return 1
        case .worn: return 2
        case .unavailable: return 3
        }
    }

    static func lastWearDate(
        for garment: Garment,
        latestWearMap: [UUID: Date]
    ) -> Date? {
        latestWearMap[garment.id] ?? garment.lastWorn
    }

    static func recommendedItemsForSlot(
        _ slot: OutfitSlot,
        garments: [Garment],
        date: Date,
        ctx: RecoContext,
        latestWearMap: [UUID: Date]
    ) -> [Garment] {
        let allowed = Set(slot.allowedCategories)
        let available = garments.filter { garment in
            guard allowed.contains(garment.category) else { return false }
            let status = availabilityStatus(for: garment, on: date, ctx: ctx, latestWearMap: latestWearMap)
            return isRecommendedEligible(status)
        }
        return available.sorted { lhs, rhs in
            if lhs.loveScore != rhs.loveScore { return lhs.loveScore > rhs.loveScore }
            let lhsDate = lastWearDate(for: lhs, latestWearMap: latestWearMap) ?? .distantPast
            let rhsDate = lastWearDate(for: rhs, latestWearMap: latestWearMap) ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func allItemsForSlot(
        _ slot: OutfitSlot,
        garments: [Garment],
        date: Date,
        ctx: RecoContext,
        latestWearMap: [UUID: Date]
    ) -> [AvailabilityItem] {
        let allowed = Set(slot.allowedCategories)
        let items: [AvailabilityItem] = garments.compactMap { garment in
            guard allowed.contains(garment.category) else { return nil }
            let status = availabilityStatus(for: garment, on: date, ctx: ctx, latestWearMap: latestWearMap)
            return AvailabilityItem(garment: garment, status: status)
        }
        return items.sorted { lhs, rhs in
            let leftRank = statusSortRank(lhs.status)
            let rightRank = statusSortRank(rhs.status)
            if leftRank != rightRank { return leftRank < rightRank }
            if lhs.garment.loveScore != rhs.garment.loveScore {
                return lhs.garment.loveScore > rhs.garment.loveScore
            }
            let lhsDate = lastWearDate(for: lhs.garment, latestWearMap: latestWearMap) ?? .distantPast
            let rhsDate = lastWearDate(for: rhs.garment, latestWearMap: latestWearMap) ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.garment.id.uuidString < rhs.garment.id.uuidString
        }
    }
}
