import Foundation

/// The user's go-to outfit formulas ("white tee + dark jeans + sneakers"),
/// found by grouping worn looks by piece type per slot and color palette.
enum LookFormulas {
    struct Formula: Identifiable, Equatable {
        /// Item type (or category) title per core slot, top → bottom → shoes.
        let parts: [String]
        let palette: LookDNA.Palette
        let timesWorn: Int

        var id: String { parts.joined(separator: "+") + "|" + palette.rawValue }
    }

    static func compute(
        wearEvents: [WearEvent],
        garmentsByID: [UUID: Garment],
        now: Date = Date(),
        windowDays: Double = 180,
        limit: Int = 3
    ) -> [Formula] {
        let cutoff = now.addingTimeInterval(-windowDays * 86_400)
        var counts: [String: (parts: [String], palette: LookDNA.Palette, count: Int)] = [:]
        var seenLooks: Set<String> = []

        for event in wearEvents where event.date >= cutoff
            && event.source != .calendarBlock && event.source != .migration {
            let pieces = Array(Set(event.garmentIDs)).compactMap { garmentsByID[$0] }
            let core = [Category.top, .bottom, .shoes].compactMap { category in
                pieces.first { $0.category == category }
            }
            guard core.count >= 2 else { continue }
            // One look worn on the same day can be logged by several sources.
            let lookKey = "\(Calendar.current.startOfDay(for: event.date).timeIntervalSince1970)|"
                + core.map(\.id.uuidString).sorted().joined(separator: ",")
            guard seenLooks.insert(lookKey).inserted else { continue }

            let parts = core.map { $0.itemType?.title ?? $0.category.title }
            let palette = LookDNA(garments: pieces).scheme
            let key = parts.joined(separator: "+") + "|" + palette.rawValue
            counts[key, default: (parts, palette, 0)].count += 1
        }

        return counts.values
            .filter { $0.count >= 2 }
            .sorted { lhs, rhs in
                lhs.count != rhs.count ? lhs.count > rhs.count : lhs.parts.joined() < rhs.parts.joined()
            }
            .prefix(limit)
            .map { Formula(parts: $0.parts, palette: $0.palette, timesWorn: $0.count) }
    }
}
