import Foundation
import SwiftData

/// A targeted “change this piece” suggestion for an outfit slot.
struct OutfitChangeSuggestion: Identifiable, Equatable {
    let slot: OutfitSlot
    let lookTime: LookTime
    let reason: String
    let currentGarmentID: UUID
    let betterGarmentID: UUID
    let scoreDelta: Double

    var id: String { "\(lookTime.rawValue)-\(slot.rawValue)-\(betterGarmentID.uuidString)" }
}

enum OutfitChangeAdvisor {
    /// Finds slots where a better alternative clearly beats the current pick.
    static func suggestions(
        day: PlannerDayState,
        lookTime: LookTime,
        garments: [Garment],
        pool: [Garment],
        ctx: RecoContext,
        modelContext: ModelContext,
        excludedIDs: Set<UUID>,
        minDelta: Double = 0.08
    ) -> [OutfitChangeSuggestion] {
        let assignedIDs: [UUID]
        if lookTime == .evening {
            assignedIDs = day.eveningAssignedGarmentIDs
        } else {
            assignedIDs = day.assignedGarmentIDs
        }
        let assigned = assignedIDs.compactMap { id in garments.first { $0.id == id } }
        guard !assigned.isEmpty else { return [] }

        var results: [OutfitChangeSuggestion] = []

        for slot in OutfitSlot.allCases {
            if lookTime == .day, day.isLocked(slot) { continue }
            if lookTime == .evening, day.isEveningLocked(slot) { continue }
            if lookTime == .evening, day.eveningLinkedSlots.contains(slot) { continue }

            let currentID = lookTime == .evening
                ? day.eveningGarmentID(for: slot)
                : day.garmentID(for: slot)
            guard let currentID,
                  let current = garments.first(where: { $0.id == currentID }) else { continue }

            let others = assigned.filter { $0.id != currentID }
            var excluded = excludedIDs
            excluded.insert(currentID)

            let slotPool = pool.filter { slot.allowedCategories.contains($0.category) }
            let alts = AIRecommender.shared.suggest(
                from: slotPool,
                k: 3,
                ctx: ctx,
                modelContext: modelContext,
                excludedIDs: excluded,
                pairedWith: others
            )
            guard let best = alts.first else { continue }

            let currentScore = AIRecommender.shared.score(current, ctx: ctx, modelContext: modelContext)
            let bestScore = AIRecommender.shared.score(best, ctx: ctx, modelContext: modelContext)
            let pairBoost = ctx.combination.affinity(of: best, with: others) * 0.12
            let adjustedBest = bestScore + pairBoost
            let delta = adjustedBest - currentScore
            guard delta >= minDelta else { continue }

            results.append(
                OutfitChangeSuggestion(
                    slot: slot,
                    lookTime: lookTime,
                    reason: reason(
                        current: current,
                        better: best,
                        ctx: ctx,
                        delta: delta
                    ),
                    currentGarmentID: currentID,
                    betterGarmentID: best.id,
                    scoreDelta: delta
                )
            )
        }

        return results.sorted { $0.scoreDelta > $1.scoreDelta }
    }

    private static func reason(
        current: Garment,
        better: Garment,
        ctx: RecoContext,
        delta: Double
    ) -> String {
        if better.formality > current.formality, ctx.desiredFormality >= 4 {
            return String(localized: "planner_change_reason_more_formal")
        }
        if better.formality < current.formality, ctx.desiredFormality <= 2 {
            return String(localized: "planner_change_reason_more_casual")
        }
        if abs(Double(better.warmth) - (ctx.temperatureC < 15 ? 4 : ctx.temperatureC > 26 ? 2 : 3))
            < abs(Double(current.warmth) - (ctx.temperatureC < 15 ? 4 : ctx.temperatureC > 26 ? 2 : 3)) {
            return String(localized: "planner_change_reason_weather")
        }
        if (better.lastWorn == nil && current.lastWorn != nil)
            || ((better.lastWorn ?? .distantFuture) < (current.lastWorn ?? .distantPast)) {
            return String(localized: "planner_change_reason_unworn")
        }
        if ctx.taste.colorScore(for: better) > ctx.taste.colorScore(for: current) + 0.15 {
            return String(localized: "planner_change_reason_taste")
        }
        if delta >= 0.15 {
            return String(localized: "planner_change_reason_better_match")
        }
        return String(
            format: NSLocalizedString("planner_change_reason_slot_format", comment: ""),
            current.category.title
        )
    }
}
