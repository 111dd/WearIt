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
        var eventDescriptor = FetchDescriptor<WearEvent>(
            predicate: #Predicate { event in
                event.date == day &&
                event.sourceRaw == sourceRaw &&
                event.slotRaw == nil
            }
        )
        eventDescriptor.fetchLimit = 1

        if let existing = (try? context.fetch(eventDescriptor))?.first {
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
        }

        let targetIDs = uniqueIDs
        let garmentDescriptor = FetchDescriptor<Garment>(
            predicate: #Predicate { garment in
                targetIDs.contains(garment.id)
            }
        )
        let garments = (try? context.fetch(garmentDescriptor)) ?? []
        for garment in garments {
            let shouldUpdate = garment.lastWorn == nil || garment.lastWorn! < day
            if shouldUpdate {
                garment.lastWorn = day
                if incrementTimesWorn {
                    garment.timesWorn += 1
                }
                if let delta = loveScoreDelta, delta != 0 {
                    garment.loveScore = max(0, min(100, garment.loveScore + delta))
                }
            }
        }

        try? context.save()
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
