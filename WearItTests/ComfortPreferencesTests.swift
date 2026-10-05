import Foundation
import Testing
@testable import WearIt

struct ComfortPreferencesTests {
    private typealias Sample = ComfortPreferences.Sample

    @Test func asksOnInBetweenDaysBeforeAnythingIsLearned() {
        #expect(ComfortPreferences.isBorderline(temperatureC: 20, low: 17, high: 23, samples: []))
        #expect(ComfortPreferences.isBorderline(temperatureC: 25, low: 14, high: 27, samples: []))   // big swing
        #expect(!ComfortPreferences.isBorderline(temperatureC: 30, low: 25, high: 32, samples: []))
        #expect(!ComfortPreferences.isBorderline(temperatureC: 9, low: 6, high: 12, samples: []))
    }

    @Test func learnsTheShortSleeveTemperature() {
        let samples = [
            Sample(temperatureC: 17, choice: .long), Sample(temperatureC: 18, choice: .long),
            Sample(temperatureC: 22, choice: .shortNoLayer), Sample(temperatureC: 23, choice: .shortWithLayer)
        ]
        let threshold = ComfortPreferences.shortSleeveFromC(samples)
        #expect(threshold != nil)
        #expect(abs((threshold ?? 0) - 20) < 0.01)
        // Close to the learned temperature it still asks; far from it, it doesn't.
        #expect(ComfortPreferences.isBorderline(temperatureC: 20.5, low: 18, high: 22, samples: samples))
        #expect(!ComfortPreferences.isBorderline(temperatureC: 23, low: 21, high: 24, samples: samples))
    }

    @Test func needsAnswersOnBothSides() {
        let samples = [Sample(temperatureC: 22, choice: .shortNoLayer), Sample(temperatureC: 24, choice: .shortNoLayer)]
        #expect(ComfortPreferences.shortSleeveFromC(samples) == nil)
    }

    @Test func dayAnswerOverridesTheJacketCall() {
        #expect(ComfortPreferences.adjusted(.suppress, choice: .shortWithLayer, isRaining: false) == .lightOnly)
        #expect(ComfortPreferences.adjusted(.prefer, choice: .shortNoLayer, isRaining: false) == .suppress)
        #expect(ComfortPreferences.adjusted(.prefer, choice: .shortNoLayer, isRaining: true) == .prefer)
        #expect(ComfortPreferences.adjusted(.lightOnly, choice: nil, isRaining: false) == .lightOnly)
    }

    @Test func storesTheDayAnswerAndASample() {
        let defaults = UserDefaults(suiteName: "ComfortPreferencesTests")!
        defaults.removePersistentDomain(forName: "ComfortPreferencesTests")
        let day = Date()
        ComfortPreferences.setAnswer(.shortWithLayer, for: day, temperatureC: 19, defaults: defaults)
        #expect(ComfortPreferences.answer(for: day, defaults: defaults) == .shortWithLayer)
        #expect(ComfortPreferences.samples(defaults: defaults) == [Sample(temperatureC: 19, choice: .shortWithLayer)])
    }

    @Test func sleeveComesFromTheItemTypeUnlessTheUserSaid() {
        let tee = Garment()
        tee.category = .top
        tee.itemType = .tshirt
        #expect(tee.sleeveLength == .short)

        let shirt = Garment()
        shirt.category = .top
        shirt.itemType = .shirt
        #expect(shirt.sleeveLength == nil)
        #expect(shirt.needsSleeveAnswer)
        shirt.sleeveLength = .long
        #expect(shirt.sleeveLength == .long)
        #expect(!shirt.needsSleeveAnswer)
    }
}
