import Foundation
import Testing
@testable import WearIt

struct WardrobeGapAnalyzerTests {

    private func garment(
        _ category: Category,
        _ itemType: ItemType? = nil,
        warmth: Int = 3,
        formality: Int = 3,
        weatherTags: [WeatherSuitability]? = nil
    ) -> Garment {
        let g = Garment()
        g.category = category
        g.itemType = itemType
        g.warmth = warmth
        g.formality = formality
        g.weatherTags = weatherTags
        return g
    }

    /// Two tops, one bottom, one sneaker, one light jacket: a basic everyday wardrobe.
    private func basicWardrobe() -> [Garment] {
        [
            garment(.top, .tshirt, warmth: 2),
            garment(.top, .tshirt, warmth: 2),
            garment(.bottom, .jeans),
            garment(.shoes, .sneakers),
            garment(.outer, .jacket, warmth: 3)
        ]
    }

    @Test func smallWardrobeHasNoGaps() {
        let input = WardrobeGapAnalyzer.Input(garments: [garment(.top)])
        #expect(WardrobeGapAnalyzer.analyze(input).isEmpty)
    }

    @Test func quietWeatherRaisesNoWeatherGaps() {
        let gaps = WardrobeGapAnalyzer.analyze(.init(garments: basicWardrobe()))
        #expect(gaps.isEmpty)
    }

    @Test func upcomingRainWithoutRainShoesRaisesGap() {
        var input = WardrobeGapAnalyzer.Input(garments: basicWardrobe())
        input.climate.upcomingRainyDays = 2
        let kinds = WardrobeGapAnalyzer.analyze(input).map(\.kind)
        #expect(kinds.contains(.rainShoes))
        #expect(kinds.contains(.rainOuter))
    }

    @Test func waterproofShoesCoverRain() {
        var wardrobe = basicWardrobe()
        wardrobe.append(garment(.shoes, .sneakers, weatherTags: [.waterproof]))
        var input = WardrobeGapAnalyzer.Input(garments: wardrobe)
        input.climate.upcomingRainyDays = 2
        let kinds = WardrobeGapAnalyzer.analyze(input).map(\.kind)
        #expect(!kinds.contains(.rainShoes))
    }

    @Test func thinRainHistoryIsIgnored() {
        var input = WardrobeGapAnalyzer.Input(garments: basicWardrobe())
        input.climate.pastSamples = 3
        input.climate.pastRainyShare = 1
        #expect(WardrobeGapAnalyzer.analyze(input).isEmpty)
    }

    @Test func coldForecastWithoutWarmOuterRaisesGap() {
        var input = WardrobeGapAnalyzer.Input(garments: basicWardrobe())
        input.climate.upcomingColdDays = 1
        #expect(WardrobeGapAnalyzer.analyze(input).map(\.kind) == [.warmOuter])
    }

    @Test func formalEventFlagsOnlyMissingFormalSlots() {
        var wardrobe = basicWardrobe()
        wardrobe.append(garment(.top, .shirt, formality: 4))
        var input = WardrobeGapAnalyzer.Input(garments: wardrobe)
        input.upcomingFormalDays = 1
        let kinds = Set(WardrobeGapAnalyzer.analyze(input).map(\.kind))
        #expect(kinds == [.formalBottom, .formalShoes])
    }

    @Test func heavilyWornItemWithoutAlternativeNeedsBackup() {
        let wardrobe = basicWardrobe()
        let jeans = wardrobe[2]
        var input = WardrobeGapAnalyzer.Input(garments: wardrobe)
        input.wearDays = 20
        input.wearCounts = [jeans.id: 12]
        let gaps = WardrobeGapAnalyzer.analyze(input)
        #expect(gaps.map(\.kind) == [.workhorseBackup])
        #expect(gaps.first?.suggestion.itemType == .jeans)
    }

    @Test func mildDaysWithoutLightJacketRaiseLightLayer() {
        var wardrobe = basicWardrobe().filter { $0.category != .outer }
        wardrobe.append(garment(.outer, .coat, warmth: 5))
        var input = WardrobeGapAnalyzer.Input(garments: wardrobe)
        input.climate.upcomingMildDays = 2
        #expect(WardrobeGapAnalyzer.analyze(input).map(\.kind) == [.lightLayer])
    }

    @Test func regularJacketCountsAsLightLayer() {
        var wardrobe = basicWardrobe().filter { $0.category != .outer }
        wardrobe.append(garment(.outer, .jacket, warmth: 3))
        var input = WardrobeGapAnalyzer.Input(garments: wardrobe)
        input.climate.upcomingMildDays = 2
        #expect(!WardrobeGapAnalyzer.analyze(input).map(\.kind).contains(.lightLayer))
    }

    @Test func thinRotationOnlyWhenAsked() {
        var input = WardrobeGapAnalyzer.Input(garments: basicWardrobe())
        #expect(WardrobeGapAnalyzer.analyze(input).isEmpty)
        input.checksRotation = true
        let targets = Set(WardrobeGapAnalyzer.analyze(input).filter { $0.kind == .thinRotation }.map(\.target))
        #expect(targets == [Category.top.rawValue, Category.bottom.rawValue, Category.shoes.rawValue])
    }

    @Test func missingShoesIsTopPriority() {
        var wardrobe = basicWardrobe().filter { $0.category != .shoes }
        wardrobe.append(garment(.top, .polo))
        var input = WardrobeGapAnalyzer.Input(garments: wardrobe)
        input.climate.upcomingRainyDays = 3
        let gaps = WardrobeGapAnalyzer.analyze(input)
        #expect(gaps.first?.kind == .missingCore)
        #expect(gaps.first?.suggestion.category == .shoes)
    }
}
