//
//  LoveScoreLearner.swift
//  WearIt
//
//  `Garment.loveScore` is no longer set by hand: the app learns it. Live
//  signals already move it (confirmed wear +1, look feedback, Style Swipe).
//  This pass adds the quieter ones, once per launch in deferred work:
//  - swapped out of a suggested look → a little less loved,
//  - picked as the replacement → a little more,
//  - owned for a while but untouched for weeks → slowly fades toward neutral-low.
//  Incremental since the last run, one save at the end.
//

import Foundation
import SwiftData

@MainActor
enum LoveScoreLearner {
    private static let lastRunKey = "loveScoreLearner.lastRun"
    private static let lastDecayKey = "loveScoreLearner.lastDecay"

    private static let replacedPenalty = 2, replacedCap = 6
    private static let pickedBonus = 1, pickedCap = 3
    private static let neglectDays = 60
    private static let neglectFloor = 30

    static func run(context: ModelContext, now: Date = Date()) {
        let defaults = UserDefaults.standard
        let calendar = Calendar.current
        let since = (defaults.object(forKey: lastRunKey) as? Date)
            ?? calendar.date(byAdding: .day, value: -90, to: now) ?? now

        var deltas: [UUID: Int] = [:]

        // Swaps: selected = the piece that was swapped out, shown = its replacement.
        let replacedRaw = RecommendationFeedbackKind.replaced.rawValue
        let swaps = FetchDescriptor<RecommendationEvent>(
            predicate: #Predicate { $0.kindRaw == replacedRaw && $0.createdAt > since }
        )
        var swappedOut: [UUID: Int] = [:]
        var pickedIn: [UUID: Int] = [:]
        for event in (try? context.fetch(swaps)) ?? [] {
            event.selectedGarmentIDs.forEach { swappedOut[$0, default: 0] += 1 }
            event.shownGarmentIDs.forEach { pickedIn[$0, default: 0] += 1 }
        }
        for (id, count) in swappedOut { deltas[id, default: 0] -= min(replacedCap, count * replacedPenalty) }
        for (id, count) in pickedIn { deltas[id, default: 0] += min(pickedCap, count * pickedBonus) }

        // Neglect: at most once a week, −1 for items owned and unworn for 60+ days.
        let lastDecay = defaults.object(forKey: lastDecayKey) as? Date
        let decayDue = lastDecay.map { now.timeIntervalSince($0) >= 7 * 86_400 } ?? true
        let cutoff = calendar.date(byAdding: .day, value: -neglectDays, to: now) ?? now

        guard !deltas.isEmpty || decayDue else {
            defaults.set(now, forKey: lastRunKey)
            return
        }

        let garments = (try? context.fetch(FetchDescriptor<Garment>())) ?? []
        var changed = false
        for garment in garments {
            var score = garment.loveScore + (deltas[garment.id] ?? 0)
            if decayDue, !garment.isFavorite, score > neglectFloor,
               let created = garment.createdAt, created < cutoff,
               (garment.lastWorn ?? .distantPast) < cutoff {
                score -= 1
            }
            score = max(0, min(100, score))
            if score != garment.loveScore {
                garment.loveScore = score
                changed = true
            }
        }

        if changed { try? context.save() }
        defaults.set(now, forKey: lastRunKey)
        if decayDue { defaults.set(now, forKey: lastDecayKey) }
    }
}
