import Foundation
import EventKit

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
    case work
    case sport
    case travel
    case outdoor
}

struct DayCalendarContext: Equatable {
    var suggestEveningLook: Bool
    /// Added to daytime formality (-1...2).
    var dayFormalityBoost: Int
    /// Added to evening formality (0...2). Evening looks always get at least +1 unless sport.
    var eveningFormalityBoost: Int
    /// Shift effective temperature for scoring (°C). Positive = dress cooler.
    var temperatureBiasC: Double
    var occasionKind: CalendarOccasionKind
    var hints: [PlannerHint]
    var primaryReason: String?

    static let empty = DayCalendarContext(
        suggestEveningLook: false,
        dayFormalityBoost: 0,
        eveningFormalityBoost: 0,
        temperatureBiasC: 0,
        occasionKind: .none,
        hints: [],
        primaryReason: nil
    )

    func formalityBump(isEvening: Bool) -> Int {
        if isEvening {
            if occasionKind == .sport { return eveningFormalityBoost }
            return max(1, eveningFormalityBoost)
        }
        return dayFormalityBoost
    }
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

    func context(for date: Date) -> DayCalendarContext {
        let day = Calendar.current.startOfDay(for: date)
        let key = day.timeIntervalSince1970
        if let cached = cache[key] { return cached }

        var suggestEvening = false
        var dayBoost = 0
        var eveningBoost = 0
        var tempBias = 0.0
        var occasion: CalendarOccasionKind = .none
        var hints: [PlannerHint] = []
        var reason: String?

        if CalendarContextPreferences.hebrewEnabled {
            let hebrew = HebrewCalendarRules.signals(for: day)
            if hebrew.suggestEvening {
                suggestEvening = true
                eveningBoost = max(eveningBoost, hebrew.eveningFormalityBoost)
                dayBoost = max(dayBoost, hebrew.dayFormalityBoost)
                occasion = hebrew.occasionKind
                if let title = hebrew.hintTitle {
                    hints.append(
                        PlannerHint(text: title, iconName: hebrew.iconName, style: .calendar)
                    )
                    reason = title
                }
            }
        }

        if CalendarContextPreferences.deviceCalendarEnabled {
            let events = deviceEventSignals(for: day)
            if events.suggestEvening {
                suggestEvening = true
            }
            dayBoost = max(dayBoost, events.dayFormalityBoost)
            // Allow sport to pull formality down
            if events.dayFormalityBoost < 0 {
                dayBoost = min(dayBoost, events.dayFormalityBoost)
            }
            eveningBoost = max(eveningBoost, events.eveningFormalityBoost)
            tempBias += events.temperatureBiasC
            if events.occasionKind != .none,
               occasion == .none || events.occasionKind.priority >= occasion.priority {
                occasion = events.occasionKind
            }
            hints.append(contentsOf: events.hints)
            if reason == nil {
                reason = events.hints.first?.text
            }
        }

        let result = DayCalendarContext(
            suggestEveningLook: suggestEvening,
            dayFormalityBoost: min(2, max(-1, dayBoost)),
            eveningFormalityBoost: min(2, max(0, eveningBoost)),
            temperatureBiasC: max(-4, min(6, tempBias)),
            occasionKind: occasion,
            hints: Array(hints.prefix(4)),
            primaryReason: reason
        )
        cache[key] = result
        return result
    }

    func requestDeviceCalendarAccessIfNeeded() async -> Bool {
        guard CalendarContextPreferences.deviceCalendarEnabled else { return false }
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .authorized:
            return true
        case .notDetermined:
            do {
                if #available(iOS 17.0, *) {
                    return try await store.requestFullAccessToEvents()
                } else {
                    return try await store.requestAccess(to: .event)
                }
            } catch {
                return false
            }
        default:
            return false
        }
    }

    private func deviceEventSignals(for day: Date) -> (
        suggestEvening: Bool,
        dayFormalityBoost: Int,
        eveningFormalityBoost: Int,
        temperatureBiasC: Double,
        occasionKind: CalendarOccasionKind,
        hints: [PlannerHint]
    ) {
        let status = EKEventStore.authorizationStatus(for: .event)
        let allowed: Bool
        if #available(iOS 17.0, *) {
            allowed = status == .fullAccess || status == .authorized
        } else {
            allowed = status == .authorized
        }
        guard allowed else {
            return (false, 0, 0, 0, .none, [])
        }

        let cal = Calendar.current
        guard let end = cal.date(byAdding: .day, value: 1, to: day) else {
            return (false, 0, 0, 0, .none, [])
        }

        let predicate = store.predicateForEvents(withStart: day, end: end, calendars: nil)
        let events = store.events(matching: predicate)

        var suggestEvening = false
        var dayBoost = 0
        var eveningBoost = 0
        var tempBias = 0.0
        var occasion: CalendarOccasionKind = .none
        var hints: [PlannerHint] = []

        let ranked = events
            .map { ($0, CalendarEventClassifier.classify($0)) }
            .filter { $0.1.relevance != .none }
            .sorted { $0.1.relevance.rank > $1.1.relevance.rank }

        for (event, signal) in ranked.prefix(5) {
            if signal.suggestEvening { suggestEvening = true }
            dayBoost = signal.dayFormalityBoost < 0
                ? min(dayBoost, signal.dayFormalityBoost)
                : max(dayBoost, signal.dayFormalityBoost)
            eveningBoost = max(eveningBoost, signal.eveningFormalityBoost)
            tempBias += signal.temperatureBiasC
            if signal.occasionKind.priority >= occasion.priority {
                occasion = signal.occasionKind
            }

            let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label: String
            if let title, !title.isEmpty {
                label = String(
                    format: NSLocalizedString("calendar_hint_event_format", comment: ""),
                    title
                )
            } else {
                label = signal.hintFallback
            }
            hints.append(
                PlannerHint(
                    text: label,
                    iconName: signal.iconName,
                    style: .calendar
                )
            )
        }

        return (suggestEvening, dayBoost, eveningBoost, tempBias, occasion, Array(hints.prefix(3)))
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

    /// Foundation Hebrew calendar months (Nisan = 1 … Tishrei = 7).
    static func signals(for date: Date) -> Signals {
        let gregorian = Calendar.current
        let weekday = gregorian.component(.weekday, from: date) // Sunday = 1 … Friday = 6

        // Erev Shabbat — Friday always gets an evening look.
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
        // month: 1 Nisan … 7 Tishrei … 12/13 Adar
        switch (month, day) {
        case (6, 29): // Elul 29 — Erev Rosh Hashanah
            return HolidayEve(
                title: String(localized: "calendar_hint_erev_rosh_hashanah"),
                dayBoost: 1,
                eveningBoost: 2,
                icon: "sparkles"
            )
        case (7, 9): // Tishrei 9 — Erev Yom Kippur
            return HolidayEve(
                title: String(localized: "calendar_hint_erev_yom_kippur"),
                dayBoost: 1,
                eveningBoost: 2,
                icon: "moon.stars"
            )
        case (7, 14): // Tishrei 14 — Erev Sukkot
            return HolidayEve(
                title: String(localized: "calendar_hint_erev_sukkot"),
                dayBoost: 0,
                eveningBoost: 1,
                icon: "leaf"
            )
        case (7, 21): // Tishrei 21 — Erev Shemini Atzeret / Simchat Torah
            return HolidayEve(
                title: String(localized: "calendar_hint_erev_simchat_torah"),
                dayBoost: 0,
                eveningBoost: 1,
                icon: "book"
            )
        case (1, 14): // Nisan 14 — Erev Pesach (Seder night)
            return HolidayEve(
                title: String(localized: "calendar_hint_erev_pesach"),
                dayBoost: 1,
                eveningBoost: 2,
                icon: "fork.knife"
            )
        case (3, 5): // Sivan 5 — Erev Shavuot
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

// MARK: - Device event classification

extension CalendarOccasionKind {
    var priority: Int {
        switch self {
        case .none: return 0
        case .work: return 1
        case .travel: return 2
        case .outdoor: return 2
        case .sport: return 3
        case .socialEvening: return 4
        case .shabbat: return 5
        case .holiday: return 6
        case .formal: return 7
        case .blackTie: return 8
        }
    }
}

enum CalendarEventClassifier {
    enum Relevance {
        case none
        case work
        case sport
        case travel
        case outdoor
        case socialEvening
        case formal
        case blackTie

        var rank: Int {
            switch self {
            case .none: return 0
            case .work: return 1
            case .travel: return 2
            case .outdoor: return 2
            case .sport: return 3
            case .socialEvening: return 4
            case .formal: return 5
            case .blackTie: return 6
            }
        }
    }

    struct Signal {
        var relevance: Relevance
        var suggestEvening: Bool
        var dayFormalityBoost: Int
        var eveningFormalityBoost: Int
        var temperatureBiasC: Double
        var occasionKind: CalendarOccasionKind
        var iconName: String
        var hintFallback: String
    }

    static func classify(_ event: EKEvent) -> Signal {
        let title = event.title?.lowercased() ?? ""
        let notes = event.notes?.lowercased() ?? ""
        let location = event.location?.lowercased() ?? ""
        let calendarName = event.calendar?.title.lowercased() ?? ""
        let text = [title, notes, location, calendarName].joined(separator: " ")

        guard !text.isEmpty else { return .none }

        let blackTieKeys = ["black tie", "black-tie", "גאלה", "gala", "white tie"]
        let formalKeys = [
            "wedding", "חתונה", "נישואין", "נישואים",
            "בר מצווה", "בת מצווה", "bar mitzvah", "bat mitzvah",
            "ברית", "הצעת נישואין", "engagement",
            "cocktail", "reception", "אירוע רשמי", "שמלה",
            "graduation", "סיום", "premiere", "opera", "תיאטרון"
        ]
        let eveningKeys = [
            "dinner", "ארוחת ערב", "date night", "party", "מסיבה",
            "evening", "ערב", "nightlife", "show", "concert", "הופעה"
        ]
        let sportKeys = [
            "gym", "workout", "run", "ריצה", "כושר", "אימון", "yoga", "יוגה",
            "football", "כדורגל", "basketball", "tennis", "swim", "שחייה", "hiit", "crossfit"
        ]
        let workKeys = [
            "meeting", "פגישה", "interview", "ראיון", "office", "משרד",
            "standup", "1:1", "client", "לקוח", "conference", "כנס", "work"
        ]
        let travelKeys = [
            "flight", "טיסה", "airport", "נמל תעופה", "train", "רכבת",
            "travel", "נסיעה", "hotel", "מלון", "trip", "טיול"
        ]
        let outdoorKeys = [
            "park", "פארק", "beach", "חוף", "hike", "טיול רגלי", "picnic", "פיקניק",
            "outdoor", "בחוץ", "camping"
        ]

        let eveningLikely = isLikelyEveningEvent(event)
        let outdoorLocation = locationContainsOutdoor(location)

        if blackTieKeys.contains(where: { text.contains($0) }) {
            return Signal(
                relevance: .blackTie,
                suggestEvening: true,
                dayFormalityBoost: 1,
                eveningFormalityBoost: 2,
                temperatureBiasC: 0,
                occasionKind: .blackTie,
                iconName: "sparkles",
                hintFallback: String(localized: "calendar_hint_black_tie")
            )
        }

        if formalKeys.contains(where: { text.contains($0) }) {
            return Signal(
                relevance: .formal,
                suggestEvening: true,
                dayFormalityBoost: eveningLikely ? 0 : 1,
                eveningFormalityBoost: 2,
                temperatureBiasC: 0,
                occasionKind: .formal,
                iconName: "heart.circle",
                hintFallback: String(localized: "calendar_hint_formal")
            )
        }

        if sportKeys.contains(where: { text.contains($0) }) {
            return Signal(
                relevance: .sport,
                suggestEvening: false,
                dayFormalityBoost: -1,
                eveningFormalityBoost: 0,
                temperatureBiasC: outdoorLocation ? 4 : 2,
                occasionKind: .sport,
                iconName: "figure.run",
                hintFallback: String(localized: "calendar_hint_sport")
            )
        }

        if travelKeys.contains(where: { text.contains($0) }) {
            return Signal(
                relevance: .travel,
                suggestEvening: eveningLikely,
                dayFormalityBoost: 0,
                eveningFormalityBoost: eveningLikely ? 1 : 0,
                temperatureBiasC: 1,
                occasionKind: .travel,
                iconName: "airplane",
                hintFallback: String(localized: "calendar_hint_travel")
            )
        }

        if workKeys.contains(where: { text.contains($0) }) {
            return Signal(
                relevance: .work,
                suggestEvening: false,
                dayFormalityBoost: 1,
                eveningFormalityBoost: 0,
                temperatureBiasC: 0,
                occasionKind: .work,
                iconName: "briefcase",
                hintFallback: String(localized: "calendar_hint_work")
            )
        }

        if outdoorKeys.contains(where: { text.contains($0) }) || outdoorLocation {
            return Signal(
                relevance: .outdoor,
                suggestEvening: eveningLikely,
                dayFormalityBoost: 0,
                eveningFormalityBoost: eveningLikely ? 1 : 0,
                temperatureBiasC: 2,
                occasionKind: .outdoor,
                iconName: "sun.max",
                hintFallback: String(localized: "calendar_hint_outdoor")
            )
        }

        if eveningKeys.contains(where: { text.contains($0) }) || eveningLikely {
            return Signal(
                relevance: .socialEvening,
                suggestEvening: true,
                dayFormalityBoost: 0,
                eveningFormalityBoost: 1,
                temperatureBiasC: 0,
                occasionKind: .socialEvening,
                iconName: "moon.stars",
                hintFallback: String(localized: "calendar_hint_event_generic")
            )
        }

        return .none
    }

    private static func isLikelyEveningEvent(_ event: EKEvent) -> Bool {
        if event.isAllDay { return false }
        let hour = Calendar.current.component(.hour, from: event.startDate)
        return hour >= 16
    }

    private static func locationContainsOutdoor(_ location: String) -> Bool {
        let keys = ["park", "beach", "חוף", "פארק", "outdoor", "stadium", "אצטדיון"]
        return keys.contains(where: { location.contains($0) })
    }
}

private extension CalendarEventClassifier.Signal {
    static let none = CalendarEventClassifier.Signal(
        relevance: .none,
        suggestEvening: false,
        dayFormalityBoost: 0,
        eveningFormalityBoost: 0,
        temperatureBiasC: 0,
        occasionKind: .none,
        iconName: "calendar",
        hintFallback: String(localized: "calendar_hint_event_generic")
    )
}
