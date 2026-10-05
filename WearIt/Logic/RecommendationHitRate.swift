import Foundation

/// How often a suggested look was worn without any swap. One number to tell
/// whether recommender changes actually help. Computed from `RecommendationEvent`s.
enum RecommendationHitRate {
    struct Result: Equatable {
        let wornLooks: Int
        let wornWithoutSwap: Int

        var rate: Double? {
            wornLooks > 0 ? Double(wornWithoutSwap) / Double(wornLooks) : nil
        }
    }

    static func compute(
        events: [RecommendationEvent],
        now: Date = Date(),
        windowDays: Int = 28
    ) -> Result {
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
        var wornPlans: Set<UUID> = []
        var swappedPlans: Set<UUID> = []
        for event in events where event.createdAt >= cutoff {
            guard let planID = event.dayPlanID, let kind = event.kind else { continue }
            switch kind {
            case .worn, .loved: wornPlans.insert(planID)
            case .replaced: swappedPlans.insert(planID)
            default: continue
            }
        }
        return Result(
            wornLooks: wornPlans.count,
            wornWithoutSwap: wornPlans.subtracting(swappedPlans).count
        )
    }
}
