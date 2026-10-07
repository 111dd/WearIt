import Foundation
import EventKit
import CoreLocation

// MARK: - Preferences

enum CalendarContextKeys {
    static let hebrewEnabled = "calendarContextHebrewEnabled"
    static let deviceCalendarEnabled = "calendarContextDeviceEnabled"
    static let eveningOptOutPrefix = "calendarEveningOptOut."
}

enum CalendarContextPreferences {
    static var hebrewEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: CalendarContextKeys.hebrewEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: CalendarContextKeys.hebrewEnabled)
        }
        set { UserDefaults.standard.set(newValue, forKey: CalendarContextKeys.hebrewEnabled) }
    }

    static var deviceCalendarEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: CalendarContextKeys.deviceCalendarEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: CalendarContextKeys.deviceCalendarEnabled) }
    }

    static func isEveningOptedOut(on date: Date) -> Bool {
        UserDefaults.standard.bool(forKey: optOutKey(for: date))
    }

    static func setEveningOptedOut(_ optedOut: Bool, on date: Date) {
        UserDefaults.standard.set(optedOut, forKey: optOutKey(for: date))
    }

    private static func optOutKey(for date: Date) -> String {
        let day = Calendar.current.startOfDay(for: date)
        let stamp = Int(day.timeIntervalSince1970)
        return CalendarContextKeys.eveningOptOutPrefix + String(stamp)
    }
}

// MARK: - Context

enum CalendarOccasionKind: String, Equatable {
    case none
    case shabbat
    case holiday
    case formal
    case blackTie
    case socialEvening
    /// Brunch, a daytime birthday: no evening look, no formality change.
    case socialDay
    /// Funeral, shiva, memorial: modest and dark.
    case mourning
    case work
    case sport
    case travel
    case outdoor
}

/// One calendar event the app understood, with the part of the day it shapes.
struct CalendarDayEvent: Equatable {
    let title: String
    let start: Date
    let isAllDay: Bool
    let kind: CalendarEventUnderstanding.Kind
    /// Starts at 16:30 or later (or an all-day formal event): shapes the evening look.
    let isEvening: Bool
    /// Map pin, when the event has a tagged location. Nil for a text-only place.
    var place: EventPlace? = nil

    var occasion: CalendarOccasionKind {
        switch kind {
        case .work: return .work
        case .sport: return .sport
        case .travel: return .travel
        case .outdoor: return .outdoor
        case .social: return isEvening ? .socialEvening : .socialDay
        case .formal: return .formal
        case .blackTie: return .blackTie
        case .mourning: return .mourning
        case .none, .personal: return .none
        }
    }

    /// "Gym · 18:00", or just the title for all-day events.
    var label: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isAllDay else { return trimmed }
        let time = start.formatted(date: .omitted, time: .shortened)
        return trimmed.isEmpty ? time : "\(trimmed) · \(time)"
    }
}

struct DayCalendarContext: Equatable {
    var suggestEveningLook: Bool
    /// Added to daytime formality (-1...2), not counting work (see `formalityBump`).
    var dayFormalityBoost: Int
    /// Added to evening formality (0...2). Evening looks always get at least +1.
    var eveningFormalityBoost: Int
    /// Shift of the effective temperature for scoring (°C). Positive = dress cooler.
    var dayTemperatureBiasC: Double
    var eveningTemperatureBiasC: Double
    /// What the day look is dressed for (daytime events only).
    var dayOccasion: CalendarOccasionKind
    /// What the evening look is dressed for (events from 16:30, Shabbat, holiday eves).
    var eveningOccasion: CalendarOccasionKind
    /// The day's most important occasion, for stats and summaries.
    var occasionKind: CalendarOccasionKind
    var hints: [PlannerHint]
    /// The headline line under the day title ("Wedding · 19:30").
    var primaryReason: String?
    var headlineIcon: String
    /// Title of the calendar event behind the headline, so the user can correct it.
    var headlineEventTitle: String?
    /// A workout that doesn't decide the look: remind the user to pack gym clothes.
    var sportReminder: CalendarDayEvent?
    /// A daytime work event (the user's dress code decides what it means).
    var workEvent: CalendarDayEvent?
    var events: [CalendarDayEvent]

    static let empty = DayCalendarContext(
        suggestEveningLook: false,
        dayFormalityBoost: 0,
        eveningFormalityBoost: 0,
        dayTemperatureBiasC: 0,
        eveningTemperatureBiasC: 0,
        dayOccasion: .none,
        eveningOccasion: .none,
        occasionKind: .none,
        hints: [],
        primaryReason: nil,
        headlineIcon: "calendar",
        headlineEventTitle: nil,
        sportReminder: nil,
        workEvent: nil,
        events: []
    )

    /// The occasion a look is dressed for. A uniform or free work day leaves the look free.
    func occasion(isEvening: Bool, workDressCode: WorkDressCode?) -> CalendarOccasionKind {
        if isEvening { return eveningOccasion }
        if dayOccasion == .work, workDressCode == .uniform || workDressCode == .free { return .none }
        return dayOccasion
    }

    func formalityBump(isEvening: Bool, workDressCode: WorkDressCode?) -> Int {
        if isEvening {
            return max(1, eveningFormalityBoost)
        }
        var boost = dayFormalityBoost
        if dayOccasion == .work {
            // Not answered yet: a little more polished, as before.
            boost += workDressCode?.formalityBoost ?? 1
        }
        return min(2, max(-1, boost))
    }

    func temperatureBias(isEvening: Bool) -> Double {
        isEvening ? eveningTemperatureBiasC : dayTemperatureBiasC
    }

    /// Changes whenever the calendar would change a planned look.
    var signature: String {
        [
            dayOccasion.rawValue, eveningOccasion.rawValue,
            String(dayFormalityBoost), String(eveningFormalityBoost),
            String(dayTemperatureBiasC), String(eveningTemperatureBiasC),
            String(suggestEveningLook)
        ].joined(separator: "|")
    }
}

extension Notification.Name {
    /// Posted when calendar settings, permission or a user correction change
    /// how events are understood. The planner re-reads and re-plans.
    static let calendarUnderstandingChanged = Notification.Name("WearIt.calendarUnderstandingChanged")
}

// MARK: - Service

@MainActor
final class CalendarContextService {
    static let shared = CalendarContextService()

    private let store = EKEventStore()
    private var cache: [TimeInterval: DayCalendarContext] = [:]

    func invalidateCache() {
        cache.removeAll()
    }

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// True when the user hasn't connected the calendar and can still be asked.
    var canOfferConnection: Bool {
        !CalendarContextPreferences.deviceCalendarEnabled && authorizationStatus == .notDetermined
    }

    /// Turns calendar reading on and asks for access. Returns whether events can be read.
    func connect() async -> Bool {
        CalendarContextPreferences.deviceCalendarEnabled = true
        let granted = await requestDeviceCalendarAccessIfNeeded()
        if !granted {
            CalendarContextPreferences.deviceCalendarEnabled = false
        }
        invalidateCache()
        NotificationCenter.default.post(name: .calendarUnderstandingChanged, object: nil)
        return granted
    }

    func context(for date: Date) -> DayCalendarContext {
        let day = Calendar.current.startOfDay(for: date)
        let key = day.timeIntervalSince1970
        if let cached = cache[key] { return cached }

        let events = CalendarContextPreferences.deviceCalendarEnabled ? deviceEvents(for: day) : []
        let hebrew = CalendarContextPreferences.hebrewEnabled ? HebrewCalendarRules.signals(for: day) : nil
        let result = Self.build(events: events, hebrew: hebrew)
        cache[key] = result
        return result
    }

    /// Combines understood events (and Shabbat / holiday eves) into what each look needs.
    static func build(events: [CalendarDayEvent], hebrew: HebrewCalendarRules.Signals?) -> DayCalendarContext {
        let relevant = events.filter { $0.occasion != .none }
        func top(_ list: [CalendarDayEvent]) -> CalendarDayEvent? {
            list.max { lhs, rhs in
                lhs.occasion.priority != rhs.occasion.priority
                    ? lhs.occasion.priority < rhs.occasion.priority
                    : lhs.start > rhs.start
            }
        }

        // Daytime: a workout sets the look only when nothing else happens that day.
        let dayEvents = relevant.filter { !$0.isEvening }
        let dayNonSport = dayEvents.filter { $0.kind != .sport }
        let dayEvent = top(dayNonSport) ?? dayEvents.first { $0.kind == .sport }
        let dayOccasion = dayEvent?.occasion ?? CalendarOccasionKind.none

        // Evening: a workout never asks for an evening look.
        let eveningEvent = top(relevant.filter { $0.isEvening && $0.kind != .sport })
        var eveningOccasion = eveningEvent?.occasion ?? CalendarOccasionKind.none

        let sportReminder = events.first { event in
            event.kind == .sport && !(dayOccasion == .sport && !event.isEvening)
        }
        let workEvent = dayEvents.first { $0.kind == .work }

        var dayBoost: Int = {
            switch dayOccasion {
            case .formal, .mourning: return 1
            case .blackTie: return 2
            case .sport: return -1
            default: return 0
            }
        }()
        var eveningBoost: Int = {
            switch eveningOccasion {
            case .socialEvening, .mourning: return 1
            case .formal, .blackTie: return 2
            default: return 0
            }
        }()
        let dayTemperatureBias: Double = {
            switch dayOccasion {
            case .sport: return 2
            case .outdoor: return 1
            default: return 0
            }
        }()
        var suggestEvening = [CalendarOccasionKind.socialEvening, .formal, .blackTie, .mourning].contains(eveningOccasion)

        var hints: [PlannerHint] = []
        var headline: (text: String, icon: String, eventTitle: String?, priority: Int)?
        let headlineEvent = [eveningEvent, dayEvent].compactMap { $0 }
            .max { $0.occasion.priority < $1.occasion.priority }
        if let headlineEvent {
            let symbol = icon(for: headlineEvent.occasion)
            headline = (headlineEvent.label, symbol, headlineEvent.title, headlineEvent.occasion.priority)
            if let guidance = guidance(for: headlineEvent.occasion) {
                hints.append(PlannerHint(text: guidance, iconName: symbol, style: .calendar))
            }
        }

        if let hebrew, hebrew.suggestEvening {
            suggestEvening = true
            eveningBoost = max(eveningBoost, hebrew.eveningFormalityBoost)
            dayBoost = max(dayBoost, hebrew.dayFormalityBoost)
            if hebrew.occasionKind.priority >= eveningOccasion.priority {
                eveningOccasion = hebrew.occasionKind
            }
            if let title = hebrew.hintTitle {
                hints.insert(PlannerHint(text: title, iconName: hebrew.iconName, style: .calendar), at: 0)
                // A calendar wedding on a Friday still leads; Erev Shabbat alone shows itself.
                if headline == nil || hebrew.occasionKind.priority > (headline?.priority ?? 0) {
                    headline = (title, hebrew.iconName, nil, hebrew.occasionKind.priority)
                }
            }
        }

        let occasionKind = [dayOccasion, eveningOccasion].max { $0.priority < $1.priority } ?? CalendarOccasionKind.none

        return DayCalendarContext(
            suggestEveningLook: suggestEvening,
            dayFormalityBoost: min(2, max(-1, dayBoost)),
            eveningFormalityBoost: min(2, max(0, eveningBoost)),
            dayTemperatureBiasC: dayTemperatureBias,
            eveningTemperatureBiasC: 0,
            dayOccasion: dayOccasion,
            eveningOccasion: eveningOccasion,
            occasionKind: occasionKind,
            hints: Array(hints.prefix(3)),
            primaryReason: headline?.text,
            headlineIcon: headline?.icon ?? "calendar",
            headlineEventTitle: headline?.eventTitle,
            sportReminder: sportReminder,
            workEvent: workEvent,
            events: events
        )
    }

    nonisolated static func icon(for occasion: CalendarOccasionKind) -> String {
        switch occasion {
        case .work: return "briefcase"
        case .sport: return "figure.run"
        case .travel: return "airplane"
        case .outdoor: return "sun.max"
        case .socialEvening: return "moon.stars"
        case .socialDay: return "cup.and.saucer"
        case .formal: return "heart.circle"
        case .blackTie: return "sparkles"
        case .mourning: return "leaf"
        case .shabbat: return "flame"
        case .holiday: return "sparkles"
        case .none: return "calendar"
        }
    }

    private static func guidance(for occasion: CalendarOccasionKind) -> String? {
        switch occasion {
        case .work: return String(localized: "calendar_hint_work")
        case .sport: return String(localized: "calendar_hint_sport")
        case .travel: return String(localized: "calendar_hint_travel")
        case .outdoor: return String(localized: "calendar_hint_outdoor")
        case .socialEvening: return String(localized: "calendar_hint_event_generic")
        case .formal: return String(localized: "calendar_hint_formal")
        case .blackTie: return String(localized: "calendar_hint_black_tie")
        case .mourning: return String(localized: "calendar_hint_mourning")
        case .socialDay, .shabbat, .holiday, .none: return nil
        }
    }

    func requestDeviceCalendarAccessIfNeeded() async -> Bool {
        guard CalendarContextPreferences.deviceCalendarEnabled else { return false }
        switch authorizationStatus {
        case .fullAccess:
            return true
        case .notDetermined:
            do {
                let granted = try await store.requestFullAccessToEvents()
                if granted { store.reset() }
                return granted
            } catch {
                return false
            }
        default:
            return false
        }
    }

    /// The day's events, understood. Skips cancelled and declined events,
    /// birthday and subscribed calendars (holidays, sports fixtures).
    private func deviceEvents(for day: Date) -> [CalendarDayEvent] {
        guard authorizationStatus == .fullAccess,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: day) else {
            return []
        }
        let predicate = store.predicateForEvents(withStart: day, end: end, calendars: nil)
        let calendar = Calendar.current
        return store.events(matching: predicate).compactMap { event -> CalendarDayEvent? in
            if event.status == .canceled { return nil }
            if let me = event.attendees?.first(where: \.isCurrentUser), me.participantStatus == .declined {
                return nil
            }
            if let type = event.calendar?.type, type == .birthday || type == .subscription { return nil }

            let kind = CalendarEventUnderstanding.classify(
                CalendarEventUnderstanding.EventInput(
                    title: event.title ?? "",
                    location: event.location ?? "",
                    notes: event.notes ?? "",
                    calendarTitle: event.calendar?.title ?? ""
                )
            )
            let isEvening: Bool
            if event.isAllDay {
                // All-day entries matter only for trips, outings, celebrations (evening)
                // and mourning (daytime); birthdays, deadlines and the like don't.
                switch kind {
                case .formal, .blackTie: isEvening = true
                case .travel, .outdoor, .mourning: isEvening = false
                default: return nil
                }
            } else {
                let start = event.startDate ?? day
                // Started yesterday (multi-day): treat as daytime.
                let minutes = start < day ? 0 : calendar.component(.hour, from: start) * 60 + calendar.component(.minute, from: start)
                isEvening = minutes >= 16 * 60 + 30
            }
            return CalendarDayEvent(
                title: event.title ?? "",
                start: event.startDate ?? day,
                isAllDay: event.isAllDay,
                kind: kind,
                isEvening: isEvening,
                place: Self.place(on: event, kind: kind)
            )
        }
        .sorted { $0.start < $1.start }
    }

    /// The map pin, else (for a trip or an all-day event only) the typed
    /// location once it has been looked up. A meeting's typed "office" never counts.
    private static func place(on event: EKEvent, kind: CalendarEventUnderstanding.Kind) -> EventPlace? {
        if let pinned = taggedPlace(on: event) { return pinned }
        guard event.isAllDay || kind == .travel else { return nil }
        let typed = (event.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        return TypedEventPlaceResolver.shared.place(for: typed)
    }

    /// The place the user picked on the map. A typed note like "office" has no coordinate.
    private static func taggedPlace(on event: EKEvent) -> EventPlace? {
        guard let geo = event.structuredLocation?.geoLocation else { return nil }
        let coordinate = geo.coordinate
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return nil }
        let raw = event.structuredLocation?.title ?? event.location ?? ""
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return EventPlace(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// Events to show on the calendar day, including ones that don't change the outfit.
    /// Also the input for trip detection across a range.
    func displayEvents(from start: Date, to end: Date) -> [CalendarDisplayEvent] {
        guard CalendarContextPreferences.deviceCalendarEnabled,
              authorizationStatus == .fullAccess else { return [] }
        let rangeStart = Calendar.current.startOfDay(for: start)
        guard let rangeEnd = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)),
              rangeEnd > rangeStart else { return [] }
        let predicate = store.predicateForEvents(withStart: rangeStart, end: rangeEnd, calendars: nil)
        return store.events(matching: predicate).compactMap { event -> CalendarDisplayEvent? in
            if event.status == .canceled { return nil }
            if let me = event.attendees?.first(where: \.isCurrentUser), me.participantStatus == .declined {
                return nil
            }
            if let type = event.calendar?.type, type == .birthday || type == .subscription { return nil }
            let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let kind = CalendarEventUnderstanding.classify(
                CalendarEventUnderstanding.EventInput(
                    title: title,
                    location: event.location ?? "",
                    notes: event.notes ?? "",
                    calendarTitle: event.calendar?.title ?? ""
                )
            )
            let place = Self.place(on: event, kind: kind)
            let locationName = place?.name.isEmpty == false
                ? place!.name
                : (event.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let startDate = event.startDate ?? rangeStart
            let endDate = event.endDate ?? startDate
            return CalendarDisplayEvent(
                id: event.eventIdentifier ?? "\(title)-\(startDate.timeIntervalSince1970)",
                title: title,
                start: startDate,
                end: endDate,
                isAllDay: event.isAllDay,
                locationName: locationName,
                place: place,
                kind: kind
            )
        }
        .sorted { $0.start < $1.start }
    }
}

/// A calendar row for the journal, and the source of a trip span.
struct CalendarDisplayEvent: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var locationName: String
    var place: EventPlace?
    var kind: CalendarEventUnderstanding.Kind

    var tripInput: TripEventInput {
        TripEventInput(
            title: title,
            start: start,
            end: end,
            isAllDay: isAllDay,
            kind: kind,
            place: place
        )
    }

    var icon: String {
        CalendarContextService.icon(for: kind.occasion(isEvening: false))
    }

    /// "18:00 · Eilat", or "All day" when there is no clock time.
    var detail: String {
        var parts: [String] = []
        if isAllDay {
            parts.append(String(localized: "calendar_all_day"))
        } else {
            parts.append(start.formatted(date: .omitted, time: .shortened))
        }
        if !locationName.isEmpty { parts.append(locationName) }
        return parts.joined(separator: " · ")
    }
}

private extension CalendarEventUnderstanding.Kind {
    func occasion(isEvening: Bool) -> CalendarOccasionKind {
        switch self {
        case .work: return .work
        case .sport: return .sport
        case .travel: return .travel
        case .outdoor: return .outdoor
        case .social: return isEvening ? .socialEvening : .socialDay
        case .formal: return .formal
        case .blackTie: return .blackTie
        case .mourning: return .mourning
        case .none, .personal: return .none
        }
    }
}

// MARK: - Hebrew rules

enum HebrewCalendarRules {
    struct Signals {
        var suggestEvening: Bool
        var dayFormalityBoost: Int
        var eveningFormalityBoost: Int
        var hintTitle: String?
        var iconName: String
        var occasionKind: CalendarOccasionKind
    }

    /// Holiday eves win over Friday (Erev Rosh Hashanah on a Friday is the holiday).
    static func signals(for date: Date) -> Signals {
        let hebrew = Calendar(identifier: .hebrew)
        let month = hebrew.component(.month, from: date)
        let day = hebrew.component(.day, from: date)

        if let holiday = holidayEve(month: month, day: day) {
            return Signals(
                suggestEvening: true,
                dayFormalityBoost: holiday.dayBoost,
                eveningFormalityBoost: holiday.eveningBoost,
                hintTitle: holiday.title,
                iconName: holiday.icon,
                occasionKind: .holiday
            )
        }

        // Erev Shabbat: Friday always gets an evening look.
        let weekday = Calendar.current.component(.weekday, from: date) // Sunday = 1 … Friday = 6
        if weekday == 6 {
            return Signals(
                suggestEvening: true,
                dayFormalityBoost: 0,
                eveningFormalityBoost: 1,
                hintTitle: String(localized: "calendar_hint_erev_shabbat"),
                iconName: "flame",
                occasionKind: .shabbat
            )
        }

        return Signals(
            suggestEvening: false,
            dayFormalityBoost: 0,
            eveningFormalityBoost: 0,
            hintTitle: nil,
            iconName: "calendar",
            occasionKind: .none
        )
    }

    private struct HolidayEve {
        let title: String
        let dayBoost: Int
        let eveningBoost: Int
        let icon: String
    }

    private static func holidayEve(month: Int, day: Int) -> HolidayEve? {
        // Foundation numbering: 1 Tishrei … 6 Adar I (leap years only),
        // 7 Adar / Adar II, 8 Nisan, 9 Iyar, 10 Sivan … 13 Elul.
        switch (month, day) {
        case (13, 29): // Elul 29 — Erev Rosh Hashanah
            return HolidayEve(
                title: String(localized: "calendar_hint_erev_rosh_hashanah"),
                dayBoost: 1,
                eveningBoost: 2,
                icon: "sparkles"
            )
        case (1, 9): // Tishrei 9 — Erev Yom Kippur
            return HolidayEve(
                title: String(localized: "calendar_hint_erev_yom_kippur"),
                dayBoost: 1,
                eveningBoost: 2,
                icon: "moon.stars"
            )
        case (1, 14): // Tishrei 14 — Erev Sukkot
            return HolidayEve(
                title: String(localized: "calendar_hint_erev_sukkot"),
                dayBoost: 0,
                eveningBoost: 1,
                icon: "leaf"
            )
        case (1, 21): // Tishrei 21 — Erev Shemini Atzeret / Simchat Torah
            return HolidayEve(
                title: String(localized: "calendar_hint_erev_simchat_torah"),
                dayBoost: 0,
                eveningBoost: 1,
                icon: "book"
            )
        case (8, 14): // Nisan 14 — Erev Pesach (Seder night)
            return HolidayEve(
                title: String(localized: "calendar_hint_erev_pesach"),
                dayBoost: 1,
                eveningBoost: 2,
                icon: "fork.knife"
            )
        case (10, 5): // Sivan 5 — Erev Shavuot
            return HolidayEve(
                title: String(localized: "calendar_hint_erev_shavuot"),
                dayBoost: 0,
                eveningBoost: 2,
                icon: "leaf.fill"
            )
        default:
            return nil
        }
    }
}

// MARK: - Priority

extension CalendarOccasionKind {
    var priority: Int {
        switch self {
        case .none: return 0
        case .work: return 1
        case .socialDay: return 2
        case .travel: return 2
        case .outdoor: return 2
        case .sport: return 3
        case .socialEvening: return 4
        case .shabbat: return 5
        case .holiday: return 6
        case .mourning: return 6
        case .formal: return 7
        case .blackTie: return 8
        }
    }
}
