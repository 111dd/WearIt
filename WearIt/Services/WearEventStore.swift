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
        // DateInterval.contains includes its end, so widen the fetch by a second.
        fetch(from: range.start, before: range.end.addingTimeInterval(1), context: context)
            .filter { range.contains($0.date) }
    }

    static func events(on date: Date, context: ModelContext) -> [WearEvent] {
        let day = normalizedDay(date)
        return fetch(from: day, before: dayAfter(day), context: context)
    }

    private static func findEvent(
        date: Date,
        slot: OutfitSlot?,
        source: WearEventSource,
        context: ModelContext
    ) -> WearEvent? {
        let day = normalizedDay(date)
        let sourceRaw = source.rawValue
        let slotRaw = slot?.rawValue
        return fetch(from: day, before: dayAfter(day), context: context)
            .first { $0.sourceRaw == sourceRaw && $0.slotRaw == slotRaw }
    }

    /// Fetch one day (or range) with a predicate instead of loading the whole
    /// table and filtering in memory — the planner asks this on every redraw.
    /// `date` is written as a start-of-day, so a half-open range also catches
    /// legacy rows that kept their time of day.
    private static func fetch(
        from start: Date,
        before end: Date,
        context: ModelContext
    ) -> [WearEvent] {
        var descriptor = FetchDescriptor<WearEvent>(
            predicate: #Predicate { $0.date >= start && $0.date < end }
        )
        descriptor.sortBy = [SortDescriptor(\WearEvent.date, order: .reverse)]
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func dayAfter(_ day: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
    }
}
