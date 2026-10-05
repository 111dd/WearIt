import Foundation
import Testing
@testable import WearIt

struct GarmentOccasionProfileTests {

    private func garment(_ category: Category, _ itemType: ItemType, formality: Int) -> Garment {
        let g = Garment()
        g.category = category
        g.itemType = itemType
        g.formality = formality
        return g
    }

    @Test func itemsFitTheSituationsTheyImply() {
        let blazer = garment(.outer, .blazer, formality: 5)
        let joggers = garment(.bottom, .joggers, formality: 1)
        let chinos = garment(.bottom, .chinos, formality: 3)

        #expect(GarmentOccasionProfile.fits(blazer, .formal))
        #expect(!GarmentOccasionProfile.fits(blazer, .home))
        #expect(GarmentOccasionProfile.fits(joggers, .sport))
        #expect(GarmentOccasionProfile.fits(joggers, .home))
        #expect(!GarmentOccasionProfile.fits(joggers, .work))
        #expect(GarmentOccasionProfile.fits(chinos, .work))
        #expect(GarmentOccasionProfile.fits(chinos, .everyday))
    }

    @Test func wearingItForASituationMakesItFit() {
        let tee = garment(.top, .tshirt, formality: 1)
        #expect(!GarmentOccasionProfile.fits(tee, .work))
        #expect(GarmentOccasionProfile.fits(tee, .work, wornFor: 2))
    }

    @Test func theUsersAnswerWinsAndSyncsTags() {
        let hoodie = garment(.top, .hoodie, formality: 1)
        hoodie.setOccasionAnswer(true, for: .work)
        #expect(GarmentOccasionProfile.score(hoodie, for: .work) == 1)
        #expect(hoodie.isWorkwear)

        hoodie.setOccasionAnswer(false, for: .sport)
        #expect(GarmentOccasionProfile.score(hoodie, for: .sport) == 0)
        #expect(hoodie.occasionTags?.contains(.gym) != true)

        hoodie.setOccasionAnswer(nil, for: .work)
        #expect(!hoodie.isWorkwear)
        #expect(hoodie.occasionFits.isEmpty)
    }

    @Test func countsWearPerSituationFromTaggedEvents() {
        let shirt = garment(.top, .shirt, formality: 3)
        let work = WearEvent(date: Date(), garmentIDs: [shirt.id], source: .planner)
        work.occasionRaw = CalendarOccasionKind.work.rawValue
        let wedding = WearEvent(date: Date(), garmentIDs: [shirt.id], source: .plannerEvening)
        wedding.occasionRaw = CalendarOccasionKind.blackTie.rawValue
        let plain = WearEvent(date: Date(), garmentIDs: [shirt.id], source: .planner)
        plain.occasionRaw = CalendarOccasionKind.none.rawValue

        let counts = GarmentOccasionProfile.wearCounts(from: [work, wedding, plain])[shirt.id]
        #expect(counts?[.work] == 1)
        #expect(counts?[.formal] == 1)
        #expect(counts?[.everyday] == nil)
    }
}
