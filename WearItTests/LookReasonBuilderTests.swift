import Foundation
import Testing
@testable import WearIt

struct LookReasonBuilderTests {

    private func garment(_ category: Category, _ itemType: ItemType? = nil, warmth: Int = 3) -> Garment {
        let g = Garment()
        g.category = category
        g.itemType = itemType
        g.warmth = warmth
        return g
    }

    private func profile(low: Double, high: Double, evening: Double, rain: Double = 0) -> DayTemperatureProfile {
        DayTemperatureProfile(
            date: Date(),
            morningTemp: low + 2,
            afternoonTemp: high,
            eveningTemp: evening,
            lowTemp: low,
            highTemp: high,
            rainProbability: rain,
            condition: .cloudy
        )
    }

    @Test func emptyLookHasNoReasons() {
        #expect(LookReasonBuilder.reasons(.init(garments: [])).isEmpty)
    }

    @Test func rainyDayWithBootsIsRainReady() {
        let look = [garment(.top), garment(.bottom), garment(.shoes, .boots)]
        let input = LookReasonBuilder.Input(garments: look, profile: profile(low: 14, high: 19, evening: 16, rain: 0.7))
        #expect(LookReasonBuilder.reasons(input).first == .rainReady)
    }

    @Test func coolEveningWithOuterExplainsLayer() {
        let look = [garment(.top), garment(.bottom), garment(.outer, .jacket)]
        let input = LookReasonBuilder.Input(garments: look, profile: profile(low: 11, high: 22, evening: 13))
        #expect(LookReasonBuilder.reasons(input).contains(.eveningLayer(temp: 13)))
    }

    @Test func favoriteAndRotationAreNamed() {
        let favorite = garment(.top)
        favorite.isFavorite = true
        let rested = garment(.bottom)
        let now = Date()
        let input = LookReasonBuilder.Input(
            garments: [favorite, rested],
            lastWorn: [rested.id: now.addingTimeInterval(-20 * 86_400)],
            now: now
        )
        let reasons = LookReasonBuilder.reasons(input)
        #expect(reasons.contains(.favorite(garmentID: favorite.id)))
        #expect(reasons.contains(.rotation(garmentID: rested.id, days: 20)))
    }

    @Test func weatherRangeOnlyFillsRemainingSlots() {
        let look = [garment(.top), garment(.bottom)]
        let input = LookReasonBuilder.Input(garments: look, profile: profile(low: 16, high: 24, evening: 20))
        #expect(LookReasonBuilder.reasons(input) == [.weatherRange(low: 16, high: 24)])
    }
}
