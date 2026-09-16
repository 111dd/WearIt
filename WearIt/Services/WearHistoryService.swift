#if DEBUG
import os.log
#endif
import Foundation
import SwiftData

enum WearHistoryService {
    /// Records a wear event for the given day.
    /// - Parameter outfitID: Optional `Outfit.id` only. Do not pass `DayPlan.id`.
    static func recordWorn(
        date: Date,
        garmentIDs: [UUID],
        source: WearEventSource,
        context: ModelContext,
        outfitID: UUID? = nil,
        incrementTimesWorn: Bool = true,
        loveScoreDelta: Int? = nil
    ) {
        let day = Calendar.current.startOfDay(for: date)
        let uniqueIDs = Array(Set(garmentIDs))
        guard !uniqueIDs.isEmpty else { return }

        let sourceRaw = source.rawValue
        // A failed read must not be treated as an empty history and add a
        // duplicate event/count. Snapshot value data before mutating models.
        guard var history = try? context.fetch(FetchDescriptor<WearEvent>()) else { return }
        let daysBefore = wearDays(history)
        var affectedIDs = Set(uniqueIDs)
        if let existing = history.first(where: {
            $0.date == day && $0.sourceRaw == sourceRaw && $0.slotRaw == nil
        }) {
            affectedIDs.formUnion(existing.garmentIDs)
            existing.garmentIDs = uniqueIDs
            existing.outfitID = outfitID
        } else {
            let event = WearEvent(
                date: day,
                garmentIDs: uniqueIDs,
                source: source,
                slot: nil,
                outfitID: outfitID
            )
            context.insert(event)
            history.append(event)
        }

        let daysAfter = wearDays(history)
        let targetIDs = Array(affectedIDs)
        let garmentDescriptor = FetchDescriptor<Garment>(
            predicate: #Predicate { garment in
                targetIDs.contains(garment.id)
            }
        )
        let garments = (try? context.fetch(garmentDescriptor)) ?? []
        for garment in garments {
            let before = daysBefore[garment.id] ?? []
            let after = daysAfter[garment.id] ?? []
            let change = after.count - before.count
            if incrementTimesWorn {
                // Keep legacy totals; only apply the change in distinct wear days.
                garment.timesWorn = max(0, garment.timesWorn + change)
            }
            if let latest = after.max() {
                if garment.lastWorn == nil || latest > garment.lastWorn! || before.contains(garment.lastWorn!) {
                    garment.lastWorn = latest
                }
            } else if let last = garment.lastWorn, before.contains(last) {
                garment.lastWorn = nil
            }
            if change > 0, let delta = loveScoreDelta, delta != 0 {
                garment.loveScore = max(0, min(100, garment.loveScore + delta))
            }
        }

        try? context.save()
    }

    private static func wearDays(_ events: [WearEvent]) -> [UUID: Set<Date>] {
        var result: [UUID: Set<Date>] = [:]
        for event in events where event.source != .calendarBlock {
            let day = Calendar.current.startOfDay(for: event.date)
            for id in Set(event.garmentIDs) { result[id, default: []].insert(day) }
        }
        return result
    }

    static func latestWearMap(events: [WearEvent]) -> [UUID: Date] {
        var map: [UUID: Date] = [:]
        for event in events where event.source != .calendarBlock {
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

    #if DEBUG
    static func debugCheckConsistency(
        garments: [Garment],
        events: [WearEvent],
        sampleCount: Int = 8
    ) {
        let map = latestWearMap(events: events)
        let sample = garments.prefix(sampleCount)
        for garment in sample {
            let fromMap = map[garment.id]
            if garment.lastWorn != fromMap {
                Logger(subsystem: "com.dordavid.WearIt", category: "WearHistory")
                    .debug("lastWorn mismatch id=\(garment.id.uuidString) garment=\(String(describing: garment.lastWorn)) map=\(String(describing: fromMap))")
            }
        }
    }
    #endif
}
