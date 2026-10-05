import EventKit
import Foundation
import SwiftData

/// Tags confirmed wear events with the calendar occasion they were worn for,
/// so `OccasionStyleProfile` can learn the user's own look for work, evenings
/// out, Shabbat and so on. Looks are tagged after the fact from the calendar
/// (EventKit reads past days too), so existing history teaches it right away.
@MainActor
enum OccasionMemory {
    /// How far back to look for untagged history.
    static let lookbackDays = 180

    private static var isRunning = false

    /// Tags events that have no occasion yet. Returns how many changed.
    @discardableResult
    static func tagUntagged(context: ModelContext) async -> Int {
        guard !isRunning else { return 0 }
        isRunning = true
        defer { isRunning = false }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let cutoff = calendar.date(byAdding: .day, value: -lookbackDays, to: today),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return 0 }
        let descriptor = FetchDescriptor<WearEvent>(
            predicate: #Predicate { event in
                event.occasionRaw == nil && event.date >= cutoff && event.date < tomorrow
            }
        )
        guard let untagged = try? context.fetch(descriptor), !untagged.isEmpty else { return 0 }

        // Without calendar access only Shabbat and holidays are known; plain days
        // stay untagged so they are read again once the calendar is connected.
        let canReadEvents = CalendarContextPreferences.deviceCalendarEnabled
            && CalendarContextService.shared.authorizationStatus == .fullAccess

        var changed = 0
        for (index, event) in untagged.enumerated() {
            if event.source == .calendarBlock || event.source == .migration {
                event.occasionRaw = CalendarOccasionKind.none.rawValue
                changed += 1
                continue
            }
            let dayContext = CalendarContextService.shared.context(for: event.date)
            let occasion = event.source == .plannerEvening ? dayContext.eveningOccasion : dayContext.dayOccasion
            guard canReadEvents || occasion != .none else { continue }
            event.occasionRaw = occasion.rawValue
            changed += 1
            if index % 20 == 19 { await Task.yield() }
        }
        if changed > 0 { try? context.save() }
        return changed
    }

    /// Clears recent tags, e.g. after the user re-labelled an event, so they are read again.
    static func forgetRecentTags(context: ModelContext) {
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -lookbackDays, to: calendar.startOfDay(for: Date())) else { return }
        let descriptor = FetchDescriptor<WearEvent>(
            predicate: #Predicate { event in
                event.occasionRaw != nil && event.date >= cutoff
            }
        )
        guard let tagged = try? context.fetch(descriptor), !tagged.isEmpty else { return }
        for event in tagged { event.occasionRaw = nil }
    }
}
