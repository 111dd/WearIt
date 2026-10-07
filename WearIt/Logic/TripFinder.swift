import Foundation
import CoreLocation

/// One calendar event the trip finder can see. No EventKit types, so it stays testable.
struct TripEventInput: Equatable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var kind: CalendarEventUnderstanding.Kind
    var place: EventPlace?
}

/// A vacation the suitcase is built for. `end` is the start of the last day.
struct TripSpan: Equatable, Identifiable, Codable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var placeName: String
    var latitude: Double?
    var longitude: Double?
    var isManual: Bool

    init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        placeName: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        isManual: Bool = false
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.placeName = placeName
        self.latitude = latitude
        self.longitude = longitude
        self.isManual = isManual
    }

    var place: EventPlace? {
        guard let latitude, let longitude else { return nil }
        return EventPlace(name: placeName, latitude: latitude, longitude: longitude)
    }

    func contains(_ day: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: day)
        return day >= calendar.startOfDay(for: start) && day <= calendar.startOfDay(for: end)
    }

    func days(calendar: Calendar = .current) -> [Date] {
        TripFinder.days(from: start, through: end, calendar: calendar)
    }

    var dayCount: Int { days().count }
}

enum TripFinder {
    static let maxDays = 21

    static func trips(
        from events: [TripEventInput],
        home: CLLocationCoordinate2D?,
        calendar: Calendar = .current
    ) -> [TripSpan] {
        var spans: [Draft] = []

        for event in events where event.kind == .travel {
            let covered = coveredDays(for: event, calendar: calendar)
            guard let first = covered.first, let last = covered.last else { continue }
            spans.append(Draft(
                title: cleaned(event.title, fallback: event.place?.name),
                start: first,
                end: last,
                place: event.place,
                fromTravel: true
            ))
        }

        if let home {
            let far = events.filter { event in
                guard let place = event.place else { return false }
                return place.isFar(from: home, minimumMeters: EventLocationDressing.differentPlaceMeters)
            }
            let groups = Dictionary(grouping: far) { event in
                EventLocationForecastService.placeKey(event.place!)
            }
            for group in groups.values {
                spans.append(contentsOf: runs(in: group, calendar: calendar))
            }
        }

        return merge(spans, calendar: calendar)
            .map { $0.makeSpan() }
            .sorted { $0.start < $1.start }
    }

    /// The trip that contains the selected day, otherwise the next one that
    /// starts within three weeks.
    static func featured(in trips: [TripSpan], selectedDay: Date, today: Date, calendar: Calendar = .current) -> TripSpan? {
        let day = calendar.startOfDay(for: selectedDay)
        if let containing = trips.first(where: { $0.contains(day, calendar: calendar) }) {
            return containing
        }
        let startToday = calendar.startOfDay(for: today)
        guard let horizon = calendar.date(byAdding: .day, value: 21, to: startToday) else { return nil }
        return trips
            .filter { calendar.startOfDay(for: $0.end) >= startToday && $0.start <= horizon }
            .sorted { $0.start < $1.start }
            .first
    }

    static func days(from start: Date, through end: Date, calendar: Calendar = .current) -> [Date] {
        var cursor = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        var result: [Date] = []
        while cursor <= last && result.count < maxDays {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    static func makeID(start: Date, end: Date, place: EventPlace?, calendar: Calendar = .current) -> String {
        let first = Int(calendar.startOfDay(for: start).timeIntervalSince1970)
        let last = Int(calendar.startOfDay(for: end).timeIntervalSince1970)
        let key = place.map { EventLocationForecastService.placeKey($0) } ?? "none"
        return "\(first)-\(last)-\(key)"
    }

    // MARK: - Drafts

    private struct Draft {
        var title: String
        var start: Date
        var end: Date
        var place: EventPlace?
        var fromTravel: Bool

        func makeSpan() -> TripSpan {
            let name = place?.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let placeName = (name?.isEmpty == false ? name! : title)
            return TripSpan(
                id: TripFinder.makeID(start: start, end: end, place: place),
                title: title.isEmpty ? placeName : title,
                start: start,
                end: end,
                placeName: placeName,
                latitude: place?.latitude,
                longitude: place?.longitude
            )
        }
    }

    /// All-day events end at the next midnight, so that morning is not another day.
    private static func coveredDays(for event: TripEventInput, calendar: Calendar) -> [Date] {
        let first = calendar.startOfDay(for: event.start)
        var last = calendar.startOfDay(for: event.end)
        if last > first {
            last = calendar.date(byAdding: .day, value: -1, to: last) ?? first
        }
        if last < first { last = first }
        return days(from: first, through: last, calendar: calendar)
    }

    /// Far pins become a trip only when they cover at least two days.
    /// A one-day gap (Friday and Sunday) still counts as one trip.
    private static func runs(in events: [TripEventInput], calendar: Calendar) -> [Draft] {
        let pins: [(day: Date, event: TripEventInput)] = events.flatMap { event in
            coveredDays(for: event, calendar: calendar).map { ($0, event) }
        }
        let unique = Array(Set(pins.map(\.day))).sorted()
        var drafts: [Draft] = []
        var run: [Date] = []

        func flush() {
            defer { run = [] }
            guard run.count >= 2, let first = run.first, let last = run.last else { return }
            let sample = pins.first { run.contains($0.day) }?.event
            drafts.append(Draft(
                title: cleaned(sample?.title ?? "", fallback: sample?.place?.name),
                start: first,
                end: last,
                place: sample?.place,
                fromTravel: false
            ))
        }

        for day in unique {
            if let previous = run.last,
               let gap = calendar.dateComponents([.day], from: previous, to: day).day,
               gap > 2 {
                flush()
            }
            run.append(day)
        }
        flush()
        return drafts
    }

    private static func merge(_ drafts: [Draft], calendar: Calendar) -> [Draft] {
        var pending = drafts.sorted { $0.start < $1.start }
        var merged: [Draft] = []
        while let next = pending.first {
            pending.removeFirst()
            if let index = merged.firstIndex(where: { compatible($0, next, calendar: calendar) }) {
                merged[index] = combine(merged[index], next, calendar: calendar)
            } else {
                merged.append(next)
            }
        }
        // A second pass catches a span that now overlaps after growing.
        var changed = true
        while changed {
            changed = false
            var index = 0
            while index < merged.count {
                let later = index + 1
                if later < merged.count, compatible(merged[index], merged[later], calendar: calendar) {
                    merged[index] = combine(merged[index], merged[later], calendar: calendar)
                    merged.remove(at: later)
                    changed = true
                } else {
                    index += 1
                }
            }
        }
        return merged
    }

    private static func compatible(_ lhs: Draft, _ rhs: Draft, calendar: Calendar) -> Bool {
        let leftStart = calendar.startOfDay(for: lhs.start)
        let leftEnd = calendar.startOfDay(for: lhs.end)
        let rightStart = calendar.startOfDay(for: rhs.start)
        let rightEnd = calendar.startOfDay(for: rhs.end)
        guard leftStart <= rightEnd && rightStart <= leftEnd else { return false }
        switch (lhs.place, rhs.place) {
        case let (left?, right?):
            return EventLocationForecastService.placeKey(left) == EventLocationForecastService.placeKey(right)
        default:
            return true
        }
    }

    private static func combine(_ lhs: Draft, _ rhs: Draft, calendar: Calendar) -> Draft {
        let start = min(calendar.startOfDay(for: lhs.start), calendar.startOfDay(for: rhs.start))
        let end = max(calendar.startOfDay(for: lhs.end), calendar.startOfDay(for: rhs.end))
        let travelTitle = [lhs, rhs].first { $0.fromTravel && !$0.title.isEmpty }?.title
        let place = lhs.place ?? rhs.place
        return Draft(
            title: travelTitle ?? (lhs.title.isEmpty ? rhs.title : lhs.title),
            start: start,
            end: end,
            place: place,
            fromTravel: lhs.fromTravel || rhs.fromTravel
        )
    }

    private static func cleaned(_ title: String, fallback: String?) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let place = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return place.isEmpty ? String(localized: "trip_fallback_title") : place
    }
}
