import CoreLocation
import Foundation
import Testing
@testable import WearIt

struct EventLocationDressingTests {
    /// Tel Aviv.
    private let home = CLLocationCoordinate2D(latitude: 32.0853, longitude: 34.7818)
    private let jerusalem = EventPlace(name: "Jerusalem", latitude: 31.7683, longitude: 35.2137)
    private let nearby = EventPlace(name: "Café", latitude: 32.09, longitude: 34.79)
    private let eilat = EventPlace(name: "Eilat", latitude: 29.5577, longitude: 34.9519)
    private let morning = Date(timeIntervalSince1970: 1_760_000_000)

    private func event(
        _ title: String,
        kind: CalendarEventUnderstanding.Kind,
        evening: Bool = false,
        allDay: Bool = false,
        place: EventPlace? = nil,
        start: Date? = nil
    ) -> CalendarDayEvent {
        CalendarDayEvent(
            title: title,
            start: start ?? morning,
            isAllDay: allDay,
            kind: kind,
            isEvening: evening,
            place: place
        )
    }

    @Test func nearbyPinKeepsHomeWeather() {
        let result = EventLocationDressing.assignment(
            events: [event("Coffee", kind: .social, place: nearby)],
            home: home
        )
        #expect(result.day == nil)
        #expect(result.evening == nil)
    }

    @Test func farDaytimePinDressesTheDayLook() {
        let result = EventLocationDressing.assignment(
            events: [event("Meetings", kind: .work, place: jerusalem)],
            home: home
        )
        #expect(result.day?.place == jerusalem)
        #expect(result.evening == nil)
    }

    @Test func eveningPinDressesOnlyTheEveningLook() {
        let result = EventLocationDressing.assignment(
            events: [event("Dinner", kind: .social, evening: true, place: eilat)],
            home: home
        )
        #expect(result.day == nil)
        #expect(result.evening?.place == eilat)
    }

    @Test func allDayTripCoversTheEveningToo() {
        let result = EventLocationDressing.assignment(
            events: [event("Trip", kind: .travel, allDay: true, place: eilat)],
            home: home
        )
        #expect(result.day?.place == eilat)
        #expect(result.evening?.place == eilat)
        #expect(result.day?.isAllDay == true)
    }

    @Test func eveningPinOverridesTheAllDayPlace() {
        let result = EventLocationDressing.assignment(
            events: [
                event("Trip", kind: .travel, allDay: true, place: eilat),
                event("Dinner", kind: .formal, evening: true, place: jerusalem)
            ],
            home: home
        )
        #expect(result.day?.place == eilat)
        #expect(result.evening?.place == jerusalem)
    }

    @Test func higherPriorityPlaceWins() {
        let result = EventLocationDressing.assignment(
            events: [
                event("Office", kind: .work, place: jerusalem),
                event("Wedding", kind: .formal, place: eilat, start: morning.addingTimeInterval(3600))
            ],
            home: home
        )
        #expect(result.day?.place == eilat)
    }

    @Test func noHomeCoordinateSkipsRemoteWeather() {
        let result = EventLocationDressing.assignment(
            events: [event("Trip", kind: .travel, place: eilat)],
            home: nil
        )
        #expect(result == .none)
    }
}
