import Foundation
import CoreLocation

/// A map pin on a calendar event (Apple Calendar's tagged location).
struct EventPlace: Equatable, Hashable {
    var name: String
    var latitude: Double
    var longitude: Double

    func isFar(from home: CLLocationCoordinate2D, minimumMeters: CLLocationDistance) -> Bool {
        let origin = CLLocation(latitude: home.latitude, longitude: home.longitude)
        let there = CLLocation(latitude: latitude, longitude: longitude)
        return origin.distance(from: there) >= minimumMeters
    }
}

/// Which look should dress for a tagged place instead of home.
enum EventLocationDressing {
    /// A café or the office stays on the home forecast. Tel Aviv → Jerusalem
    /// is about 54 km, so it crosses this line.
    static let differentPlaceMeters: CLLocationDistance = 40_000

    /// The pin, plus when the event happens so a timed meeting uses those hours.
    struct Pinned: Equatable {
        var place: EventPlace
        var start: Date
        var isAllDay: Bool
    }

    struct Assignment: Equatable {
        var day: Pinned?
        var evening: Pinned?

        static let none = Assignment(day: nil, evening: nil)

        func pinned(isEvening: Bool) -> Pinned? {
            isEvening ? evening : day
        }
    }

    /// A pin counts only when it is in a different place. The day's look uses
    /// the highest-priority daytime event that has such a pin. An all-day trip
    /// also covers the evening, unless the evening event has its own pin.
    static func assignment(events: [CalendarDayEvent], home: CLLocationCoordinate2D?) -> Assignment {
        guard let home else { return .none }

        func far(_ event: CalendarDayEvent) -> Bool {
            event.place?.isFar(from: home, minimumMeters: differentPlaceMeters) == true
        }

        let day = pick(events.filter { !$0.isEvening && far($0) })
        let eveningOwn = pick(events.filter { $0.isEvening && far($0) })
        let allDay = pick(events.filter { $0.isAllDay && far($0) })
        return Assignment(day: day, evening: eveningOwn ?? allDay)
    }

    /// Same ordering as the day's headline event: higher occasion, then earlier start.
    private static func pick(_ events: [CalendarDayEvent]) -> Pinned? {
        guard let event = events.max(by: { lhs, rhs in
            if lhs.occasion.priority != rhs.occasion.priority {
                return lhs.occasion.priority < rhs.occasion.priority
            }
            return lhs.start > rhs.start
        }), let place = event.place else { return nil }
        return Pinned(place: place, start: event.start, isAllDay: event.isAllDay)
    }
}
