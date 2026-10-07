import Foundation
import Testing
@testable import WearIt

struct ComfortPreferencesTests {
    private typealias Sample = ComfortPreferences.Sample

    @Test func coolHourJacketTemperatureFollowsAnswers() {
        typealias Cool = ComfortPreferences.CoolHourSample
        #expect(ComfortPreferences.coolHourJacketBelowC([]) == ComfortPreferences.defaultCoolHourJacketBelowC)
        // Runs cold: wants a jacket a degree earlier.
        #expect(ComfortPreferences.coolHourJacketBelowC([], warmthSensitivity: 4) == ComfortPreferences.defaultCoolHourJacketBelowC + 1)
        // "Not needed" at 17° drops it under 17°; "yes" at 21° lifts it over 21°.
        #expect(ComfortPreferences.coolHourJacketBelowC([Cool(temperatureC: 17, tookJacket: false)]) < 17)
        #expect(ComfortPreferences.coolHourJacketBelowC([Cool(temperatureC: 21, tookJacket: true)]) > 21)
        // Enough of both settles between them.
        let both = [
            Cool(temperatureC: 15, tookJacket: true), Cool(temperatureC: 16, tookJacket: true),
            Cool(temperatureC: 19, tookJacket: false), Cool(temperatureC: 20, tookJacket: false)
        ]
        #expect(abs(ComfortPreferences.coolHourJacketBelowC(both) - 17.5) < 0.01)
    }

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
