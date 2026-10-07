import Foundation

/// What the user wears on a work day when their dress code is a uniform:
/// only the work clothes, or their own clothes.
enum WorkDayAttire: String, CaseIterable, Identifiable {
    /// Only work clothes: no day look to plan, and nothing from the day counts in stats.
    case uniform
    /// The user's own clothes: a normal day look.
    case own

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uniform: return String(localized: "work_attire_uniform")
        case .own: return String(localized: "work_attire_own")
        }
    }

    var icon: String {
        switch self {
        case .uniform: return "lanyardcard.fill"
        case .own: return "tshirt.fill"
        }
    }
}

/// The per-day answer, kept on this device. A day with no answer follows the
/// user's last answer, so the choice is made once and then only changed.
enum WorkDayAttirePreferences {
    private static let dayPrefix = "workAttire.day."
    private static let lastKey = "workAttire.last"

    static func choice(on date: Date) -> WorkDayAttire? {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: key(for: date)) {
            return WorkDayAttire(rawValue: raw)
        }
        return defaults.string(forKey: lastKey).flatMap(WorkDayAttire.init(rawValue:))
    }

    /// True when the user picked for this exact day (not inherited from the last answer).
    static func isExplicit(on date: Date) -> Bool {
        UserDefaults.standard.string(forKey: key(for: date)) != nil
    }

    static func set(_ attire: WorkDayAttire, on date: Date) {
        let defaults = UserDefaults.standard
        defaults.set(attire.rawValue, forKey: key(for: date))
        defaults.set(attire.rawValue, forKey: lastKey)
    }

    /// A "work clothes only" day clears its planned look once; after that the
    /// user may still put a look there by hand and it stays.
    static func wasApplied(on date: Date) -> Bool {
        UserDefaults.standard.bool(forKey: appliedPrefix + stamp(date))
    }

    static func markApplied(on date: Date) {
        UserDefaults.standard.set(true, forKey: appliedPrefix + stamp(date))
    }

    private static let appliedPrefix = "workAttire.applied."

    private static func key(for date: Date) -> String {
        dayPrefix + stamp(date)
    }

    private static func stamp(_ date: Date) -> String {
        String(Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970))
    }
}

/// The work event and what the user has around it, so a uniform day knows
/// whether they need their own clothes before work or a look after it.
struct WorkDaySchedule: Equatable {
    var work: CalendarDayEvent
    /// The first timed plan that starts before work (gym, a coffee, a meeting).
    var beforeWork: CalendarDayEvent?
    /// The first timed plan that starts once work is over.
    var afterWork: CalendarDayEvent?

    /// A shift with no end time is assumed to last this long.
    static let assumedShift: TimeInterval = 8 * 3600
    /// A plan that starts a little before the end of the shift still counts as after work.
    static let afterWorkSlack: TimeInterval = 30 * 60

    var workEnd: Date {
        if let end = work.end, end > work.start { return end }
        return work.start.addingTimeInterval(Self.assumedShift)
    }

    static func make(events: [CalendarDayEvent]) -> WorkDaySchedule? {
        let timed = events.filter { !$0.isAllDay }
        guard let work = timed.filter({ $0.kind == .work }).min(by: { $0.start < $1.start }) else { return nil }
        var schedule = WorkDaySchedule(work: work)
        let others = timed.filter { $0.kind != .work }.sorted { $0.start < $1.start }
        schedule.beforeWork = others.first { $0.start < work.start }
        let end = schedule.workEnd.addingTimeInterval(-afterWorkSlack)
        schedule.afterWork = others.first { $0.start >= end }
        return schedule
    }
}
