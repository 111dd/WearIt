import Foundation
import Testing
@testable import WearIt

struct OccasionStyleProfileTests {

    private func garment(_ category: Category, _ itemType: ItemType, formality: Int) -> Garment {
        let g = Garment()
        g.category = category
        g.itemType = itemType
        g.formality = formality
        return g
    }

    private func worn(_ garments: [Garment], daysAgo: Int, occasion: CalendarOccasionKind) -> WearEvent {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let event = WearEvent(date: date, garmentIDs: garments.map(\.id), source: .planner)
        event.occasionRaw = occasion.rawValue
        return event
    }

    @Test func learnsTheUsualWorkLookAfterAFewDays() {
        let chinos = garment(.bottom, .chinos, formality: 3)
        let shirt = garment(.top, .shirt, formality: 3)
        let blazer = garment(.outer, .blazer, formality: 5)
        let hoodie = garment(.top, .hoodie, formality: 1)
        let events = (1...4).map { worn([chinos, shirt], daysAgo: $0, occasion: .work) }
        let profile = OccasionStyleProfile.build(events: events, garments: [chinos, shirt, blazer, hoodie])

        #expect(profile.confidence(for: .work) > 0)
        #expect(profile.fit(shirt, occasion: .work) > 0)
        #expect(profile.fit(shirt, occasion: .work) > profile.fit(hoodie, occasion: .work))
        #expect(profile.fit(shirt, occasion: .work) > profile.fit(blazer, occasion: .work))
        #expect(abs((profile.learnedFormality(for: .work)?.value ?? 0) - 3) < 0.01)
        #expect(profile.lookFollowsHabit([chinos, shirt], occasion: .work))
    }

    @Test func rulesDecideUntilThereAreEnoughLooks() {
        let shirt = garment(.top, .shirt, formality: 3)
        let events = (1...2).map { worn([shirt], daysAgo: $0, occasion: .work) }
        let profile = OccasionStyleProfile.build(events: events, garments: [shirt])
        #expect(profile.confidence(for: .work) == 0)
        #expect(profile.fit(shirt, occasion: .work) == 0)
        #expect(profile.learnedFormality(for: .work) == nil)
    }

    @Test func plainDaysAndUntaggedLooksAreIgnored() {
        let shirt = garment(.top, .shirt, formality: 3)
        let plain = (1...5).map { worn([shirt], daysAgo: $0, occasion: .none) }
        let untagged = WearEvent(date: Date(), garmentIDs: [shirt.id], source: .planner)
        let profile = OccasionStyleProfile.build(events: plain + [untagged], garments: [shirt])
        #expect(profile.byOccasion.isEmpty)
    }
}
