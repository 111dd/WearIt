#if DEBUG
import os.log
#endif
import Foundation
import SwiftData

enum WearHistoryService {
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

        let events = (try? context.fetch(FetchDescriptor<WearEvent>())) ?? []
        if let existing = events.first(where: { event in
            Calendar.current.isDate(event.date, inSameDayAs: day) &&
            event.source == source &&
            event.slot == nil
        }) {
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

        let garments = (try? context.fetch(FetchDescriptor<Garment>())) ?? []
        let garmentsByID = Dictionary(uniqueKeysWithValues: garments.map { ($0.id, $0) })
        for id in uniqueIDs {
            guard let garment = garmentsByID[id] else { continue }
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
            let cached = garment.lastWorn.map { Calendar.current.startOfDay(for: $0) }
            let latest = map[garment.id]
            if cached != latest {
                let cachedString = cached?.description ?? "nil"
                let latestString = latest?.description ?? "nil"
                print("WEAR_HISTORY_MISMATCH,id=\(garment.id.uuidString),cached=\(cachedString),latest=\(latestString)")
            }
        }
    }
    #endif
}
