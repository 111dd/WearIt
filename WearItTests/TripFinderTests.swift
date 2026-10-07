import CoreLocation
import Foundation
import Testing
@testable import WearIt

struct TripFinderTests {
    private let home = CLLocationCoordinate2D(latitude: 32.0853, longitude: 34.7818)
    private let eilat = EventPlace(name: "Eilat", latitude: 29.5577, longitude: 34.9519)
    private let nearby = EventPlace(name: "Café", latitude: 32.09, longitude: 34.79)
    private let origin = Date(timeIntervalSince1970: 1_760_000_000)

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: origin))!
    }

    private func event(
        _ title: String,
        on offset: Int,
        length: Int = 1,
        kind: CalendarEventUnderstanding.Kind,
        place: EventPlace? = nil,
        allDay: Bool = false
    ) -> TripEventInput {
        let start = day(offset)
        let end: Date
        if allDay {
            end = Calendar.current.date(byAdding: .day, value: length, to: start)!
        } else if length <= 1 {
            end = start.addingTimeInterval(3_600)
        } else {
            end = Calendar.current.date(byAdding: .day, value: length - 1, to: start)!.addingTimeInterval(3_600)
        }
        return TripEventInput(title: title, start: start, end: end, isAllDay: allDay, kind: kind, place: place)
    }

    @Test func oneFarDayIsNotATrip() {
        let trips = TripFinder.trips(
            from: [event("Meetings", on: 0, kind: .work, place: eilat)],
            home: home
        )
        #expect(trips.isEmpty)
    }

    @Test func nearbyPinIsNotATrip() {
        let trips = TripFinder.trips(
            from: [
                event("Coffee", on: 0, kind: .social, place: nearby),
                event("Lunch", on: 1, kind: .social, place: nearby)
            ],
            home: home
        )
        #expect(trips.isEmpty)
    }

    @Test func consecutiveFarDaysBecomeOneTrip() {
        let trips = TripFinder.trips(
            from: [
                event("Beach", on: 0, kind: .outdoor, place: eilat),
                event("Beach", on: 1, kind: .outdoor, place: eilat),
                event("Beach", on: 2, kind: .outdoor, place: eilat)
            ],
            home: home
        )
        #expect(trips.count == 1)
        #expect(trips[0].dayCount == 3)
        #expect(trips[0].placeName == "Eilat")
    }

    @Test func aOneDayGapStillJoinsTheTrip() {
        let trips = TripFinder.trips(
            from: [
                event("Friday", on: 0, kind: .outdoor, place: eilat),
                event("Sunday", on: 2, kind: .outdoor, place: eilat)
            ],
            home: home
        )
        #expect(trips.count == 1)
        #expect(trips[0].dayCount == 3)
    }

    @Test func aLongGapDoesNotJoin() {
        let trips = TripFinder.trips(
            from: [
                event("Now", on: 0, kind: .work, place: eilat),
                event("Later", on: 6, kind: .work, place: eilat)
            ],
            home: home
        )
        #expect(trips.isEmpty)
    }

    @Test func allDayTravelSpansItsDays() {
        let trips = TripFinder.trips(
            from: [event("Eilat", on: 0, length: 4, kind: .travel, place: eilat, allDay: true)],
            home: home
        )
        #expect(trips.count == 1)
        #expect(trips[0].dayCount == 4)
    }

    @Test func aSingleFlightIsATrip() {
        let trips = TripFinder.trips(
            from: [event("Flight to Eilat", on: 3, kind: .travel, place: eilat)],
            home: home
        )
        #expect(trips.count == 1)
        #expect(trips[0].dayCount == 1)
        #expect(trips[0].title == "Flight to Eilat")
    }

    @Test func featuredPrefersTheDayYouAreLookingAt() {
        let later = TripSpan(
            id: "later",
            title: "Later",
            start: day(10),
            end: day(12),
            placeName: "Eilat"
        )
        let current = TripSpan(
            id: "now",
            title: "Now",
            start: day(0),
            end: day(2),
            placeName: "Eilat"
        )
        let picked = TripFinder.featured(in: [later, current], selectedDay: day(1), today: day(0))
        #expect(picked?.id == "now")
    }
}

struct TripPackingBuilderTests {
    @Test func hotTripAddsSwimwearNotACoat() {
        let forecast = DayForecast(
            date: Date(),
            temperatureC: 32,
            highTempC: 34,
            lowTempC: 24,
            rainProbability: 0,
            condition: .sunny
        )
        let climate = TripPackingBuilder.climate(forecasts: [forecast])
        let lines = TripPackingBuilder.quantities(dayCount: 4, climate: climate, hasCoatInCloset: false)
        #expect(climate.suggestsSwim)
        #expect(!climate.suggestsCoat)
        #expect(lines.first { $0.id == "underwear" }?.count == 5)
        #expect(lines.first { $0.id == "socks" }?.count == 5)
        #expect(lines.contains { $0.id == "swim" && $0.count == 1 })
        #expect(!lines.contains { $0.id == "coat" })
    }

    @Test func coldTripAddsACoatWhenTheClosetHasNone() {
        let forecast = DayForecast(
            date: Date(),
            temperatureC: 6,
            highTempC: 8,
            lowTempC: 2,
            rainProbability: 0.2,
            condition: .cloudy
        )
        let climate = TripPackingBuilder.climate(forecasts: [forecast])
        let lines = TripPackingBuilder.quantities(dayCount: 3, climate: climate, hasCoatInCloset: false)
        #expect(climate.suggestsCoat)
        #expect(!climate.suggestsSwim)
        #expect(lines.contains { $0.id == "coat" && $0.count == 1 })
    }

    @Test func aClosetCoatSkipsTheGenericLine() {
        let forecast = DayForecast(
            date: Date(),
            temperatureC: 6,
            highTempC: 8,
            lowTempC: 2,
            rainProbability: 0,
            condition: .cloudy
        )
        let climate = TripPackingBuilder.climate(forecasts: [forecast])
        let lines = TripPackingBuilder.quantities(dayCount: 3, climate: climate, hasCoatInCloset: true)
        #expect(!lines.contains { $0.id == "coat" })
    }

    @Test func swimwearMatchesABeachPieceOrItsName() {
        let named = Garment()
        named.userTitleOverride = "Blue swimsuit"
        let beach = Garment()
        beach.userTitleOverride = "Shorts"
        beach.occasionTags = [.beach]
        let shirt = Garment()
        shirt.userTitleOverride = "White shirt"
        #expect(TripPackingBuilder.isSwimwear(named))
        #expect(TripPackingBuilder.isSwimwear(beach))
        #expect(!TripPackingBuilder.isSwimwear(shirt))
    }
}
