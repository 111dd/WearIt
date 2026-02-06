import Foundation
import SwiftData

enum WearEventStore {
    static func normalizedDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    static func markWorn(
        date: Date,
        slot: OutfitSlot? = nil,
        outfitID: UUID? = nil,
        garmentIDs: [UUID],
        source: WearEventSource,
        context: ModelContext
    ) {
        let day = normalizedDay(date)
        if let existing = findEvent(date: day, slot: slot, source: source, context: context) {
            existing.garmentIDs = garmentIDs
            existing.outfitID = outfitID
        } else {
            let event = WearEvent(
                date: day,
                garmentIDs: garmentIDs,
                source: source,
                slot: slot,
                outfitID: outfitID
            )
            context.insert(event)
        }
        try? context.save()
    }

    static func unmarkWorn(
        date: Date,
        slot: OutfitSlot? = nil,
        source: WearEventSource,
        context: ModelContext
    ) {
        let day = normalizedDay(date)
        if let existing = findEvent(date: day, slot: slot, source: source, context: context) {
            context.delete(existing)
            try? context.save()
        }
    }

    static func events(in range: DateInterval, context: ModelContext) -> [WearEvent] {
        let events = (try? context.fetch(FetchDescriptor<WearEvent>())) ?? []
        return events.filter { range.contains($0.date) }
    }

    static func events(on date: Date, context: ModelContext) -> [WearEvent] {
        let day = normalizedDay(date)
        let events = (try? context.fetch(FetchDescriptor<WearEvent>())) ?? []
        return events.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
    }

    private static func findEvent(
        date: Date,
        slot: OutfitSlot?,
        source: WearEventSource,
        context: ModelContext
    ) -> WearEvent? {
        let day = normalizedDay(date)
        let events = (try? context.fetch(FetchDescriptor<WearEvent>())) ?? []
        return events.first { event in
            Calendar.current.isDate(event.date, inSameDayAs: day) &&
            event.source == source &&
            event.slot?.rawValue == slot?.rawValue
        }
    }
}
