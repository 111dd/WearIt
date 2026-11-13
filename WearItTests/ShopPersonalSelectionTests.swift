import Foundation
import Testing
@testable import WearIt

struct ShopPersonalSelectionTests {
    private let day = 86_400
    private let limit = Int(ShopPersonalSelection.absenceLimit)

    @Test func freeSlotsTakeTheBestNewCandidates() {
        let result = ShopPersonalSelection.updatedSlots(["a", nil, nil], missingSince: [:],
            candidateIDs: ["b", "a", "c", "d"], ownedIDs: [], now: 0)
        #expect(result.slots == ["a", "b", "c"])
        #expect(result.missingSince.isEmpty)
    }

    @Test func ownedProductFreesItsSlotAtOnce() {
        let result = ShopPersonalSelection.updatedSlots(["a", "b"], missingSince: [:],
            candidateIDs: ["b", "c"], ownedIDs: ["a"], now: 0)
        #expect(result.slots == ["c", "b"])
    }

    @Test func brieflyMissingProductKeepsItsSlot() {
        let first = ShopPersonalSelection.updatedSlots(["a", "b"], missingSince: [:],
            candidateIDs: ["b", "c"], ownedIDs: [], now: 100)
        #expect(first.slots == ["a", "b"])
        #expect(first.missingSince == ["a": 100])

        let later = ShopPersonalSelection.updatedSlots(first.slots, missingSince: first.missingSince,
            candidateIDs: ["b", "c"], ownedIDs: [], now: 100 + limit - day)
        #expect(later.slots == ["a", "b"])
        #expect(later.missingSince == ["a": 100])
    }

    @Test func longMissingProductIsReplaced() {
        let result = ShopPersonalSelection.updatedSlots(["a", "b"], missingSince: ["a": 100],
            candidateIDs: ["b", "c"], ownedIDs: [], now: 100 + limit)
        #expect(result.slots == ["c", "b"])
        #expect(result.missingSince.isEmpty)
    }

    @Test func returningProductResetsItsClock() {
        let result = ShopPersonalSelection.updatedSlots(["a"], missingSince: ["a": 100],
            candidateIDs: ["a"], ownedIDs: [], now: 100 + limit * 2)
        #expect(result.slots == ["a"])
        #expect(result.missingSince.isEmpty)
    }

    @Test func emptyRankingNeverStartsOrAdvancesTheClock() {
        let untouched = ShopPersonalSelection.updatedSlots(["a", "b"], missingSince: [:],
            candidateIDs: [], ownedIDs: [], now: 100)
        #expect(untouched.slots == ["a", "b"])
        #expect(untouched.missingSince.isEmpty)

        let stillHeld = ShopPersonalSelection.updatedSlots(["a"], missingSince: ["a": 100],
            candidateIDs: [], ownedIDs: [], now: 100 + limit * 2)
        #expect(stillHeld.slots == ["a"])
        #expect(stillHeld.missingSince == ["a": 100])
    }
}
