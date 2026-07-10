//
//  WearItTests.swift
//  WearItTests
//
//  Created by Dor David on 05/09/2025.
//

import Foundation
import SwiftData
import Testing
@testable import WearIt

struct WearItTests {

    @Test func recommendedItemsExcludeWornAndUnavailable() async throws {
        let date = Date()
        let ctx = RecoContext(desiredFormality: 3, temperatureC: 20, isRaining: false, now: date)

        let worn = Garment()
        worn.category = .top

        let unavailable = Garment()
        unavailable.category = .top
        unavailable.isBlocked = true

        let available = Garment()
        available.category = .top

        let items = AvailabilityService.recommendedItemsForSlot(
            .top,
            garments: [worn, unavailable, available],
            date: date,
            ctx: ctx,
            latestWearMap: [worn.id: date]
        )

        #expect(items.contains(where: { $0.id == available.id }))
        #expect(!items.contains(where: { $0.id == worn.id }))
        #expect(!items.contains(where: { $0.id == unavailable.id }))
    }

    @Test func allItemsIncludeStatuses() async throws {
        let calendar = Calendar.current
        let date = calendar.startOfDay(for: Date())
        let ctx = RecoContext(desiredFormality: 3, temperatureC: 20, isRaining: false, now: date)

        let worn = Garment()
        worn.category = .top

        let unavailable = Garment()
        unavailable.category = .top
        unavailable.unavailableUntil = calendar.date(byAdding: .day, value: 1, to: date)

        let cooldown = Garment()
        cooldown.category = .top

        let available = Garment()
        available.category = .top

        let latestWearMap = [
            worn.id: date,
            cooldown.id: calendar.date(byAdding: .day, value: -1, to: date) ?? date
        ]

        let items = AvailabilityService.allItemsForSlot(
            .top,
            garments: [worn, unavailable, cooldown, available],
            date: date,
            ctx: ctx,
            latestWearMap: latestWearMap
        )

        let statusById = Dictionary(uniqueKeysWithValues: items.map { ($0.garment.id, $0.status) })
        #expect(statusById[worn.id] == .worn)
        #expect(statusById[unavailable.id] == .unavailable)
        #expect(statusById[cooldown.id] == .cooldown(daysRemaining: 1))
        #expect(statusById[available.id] == .available)
    }

    @Test
    func legacyIsWornFlagDoesNotAffectAvailability() {
        let date = Date()
        let ctx = RecoContext(desiredFormality: 3, temperatureC: 20, isRaining: false, now: date)

        let garment = Garment()
        garment.category = .top
        garment.isWorn = true

        let status = AvailabilityService.availabilityStatus(
            for: garment,
            on: date,
            ctx: ctx,
            latestWearMap: [:]
        )
        #expect(status == .available)
    }

    @Test
    func tasteAffinityBoostsPreferredColorAndBrand() {
        let lovedNavy = Garment()
        lovedNavy.category = .top
        lovedNavy.colorTags = [.navy]
        lovedNavy.brand = "Acne"
        lovedNavy.loveScore = 95
        lovedNavy.timesWorn = 8
        lovedNavy.isFavorite = true

        let other = Garment()
        other.category = .top
        other.colorTags = [.orange]
        other.brand = "Unknown Co"
        other.loveScore = 20

        let taste = TasteAffinityBuilder.build(from: [lovedNavy, other])
        #expect((taste.colorAffinity[.navy] ?? 0) > (taste.colorAffinity[.orange] ?? 0))
        #expect(
            (taste.brandAffinity[BrandStore.normalizeBrandKey("Acne")] ?? 0) >
            (taste.brandAffinity[BrandStore.normalizeBrandKey("Unknown Co")] ?? 0)
        )

        let candidateNavy = Garment()
        candidateNavy.category = .bottom
        candidateNavy.colorTags = [.navy]
        candidateNavy.brand = "Acne"

        let candidateOrange = Garment()
        candidateOrange.category = .bottom
        candidateOrange.colorTags = [.orange]

        #expect(taste.colorScore(for: candidateNavy) > taste.colorScore(for: candidateOrange))
        #expect(taste.brandScore(for: candidateNavy) > taste.brandScore(for: candidateOrange))
    }

    @Test
    func tasteStatsSharesPreferCommonColorsOverRareHighLove() {
        // Many black items with solid love should outrank one yellow item at 98.
        var wardrobe: [Garment] = []
        for _ in 0..<8 {
            let black = Garment()
            black.category = .top
            black.colorTags = [.black]
            black.loveScore = 80
            black.timesWorn = 3
            wardrobe.append(black)
        }

        let yellow = Garment()
        yellow.category = .top
        yellow.colorTags = [.yellow]
        yellow.loveScore = 98
        yellow.timesWorn = 1
        yellow.isFavorite = true
        wardrobe.append(yellow)

        let taste = TasteAffinityBuilder.build(from: wardrobe)
        let shares = taste.colorShares(limit: 5)
        #expect(shares.first?.tag == .black)
        #expect((shares.first?.share ?? 0) > (taste.colorShares(limit: 10).first(where: { $0.tag == .yellow })?.share ?? 0))
        // Shares are fractions of total mass — not near-100% averages.
        #expect((shares.first?.share ?? 1) < 0.95)
    }

    @Test
    @MainActor
    func learningWithShownAlternativesUpdatesWeights() throws {
        let schema = Schema([RecoState.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        let profileID = UUID()

        let selected = Garment()
        selected.category = .top
        selected.colorTags = [.black]
        selected.loveScore = 80

        let shown = Garment()
        shown.category = .top
        shown.colorTags = [.yellow]
        shown.loveScore = 40

        let taste = TasteAffinityBuilder.build(from: [selected, shown])
        let recoContext = RecoContext(
            desiredFormality: 3,
            temperatureC: 18,
            isRaining: false,
            now: Date(),
            profileID: profileID,
            taste: taste
        )

        AIRecommender.shared.learn(
            from: [selected],
            shown: [selected, shown],
            ctx: recoContext,
            reward: 0.9,
            modelContext: context
        )

        let state = AIRecommender.shared.ensureState(context: context, profileID: profileID)
        #expect(state.interactionCount == 1)
        #expect(state.weights.count == FeatureSpace.total)
        #expect(state.version == 3)
    }

    @Test
    @MainActor
    func dayPlanRoundTripPreservesAssignmentsAndLocks() throws {
        let schema = Schema([
            DayPlan.self,
            UserProfile.self
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        let date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let dayTopID = UUID()
        let dayBottomID = UUID()
        let eveningTopID = UUID()

        let plan = DayPlanService.shared.planFor(date: date, context: context)
        plan.setSlotAssignments(
            [
                .top: dayTopID,
                .bottom: dayBottomID
            ],
            lockedSlots: [.top]
        )
        plan.eveningEnabled = true
        plan.setEveningSlotAssignments(
            [.top: eveningTopID],
            lockedSlots: [.top]
        )
        plan.setEveningLinkedSlots([.bottom])
        try context.save()

        let reloaded = DayPlanService.shared.planFor(date: date, context: context)

        #expect(Calendar.current.isDate(reloaded.date, inSameDayAs: date))
        #expect(reloaded.slotAssignments[.top] == dayTopID)
        #expect(reloaded.slotAssignments[.bottom] == dayBottomID)
        #expect(reloaded.lockedSlots == [.top])
        #expect(reloaded.eveningEnabled == true)
        #expect(reloaded.eveningSlotAssignments[.top] == eveningTopID)
        #expect(reloaded.eveningLockedSlots == [.top])
        #expect(reloaded.eveningLinkedSlots == [.bottom])
    }

    @Test
    @MainActor
    func wearHistoryRecordingIsIdempotentForTheSameDay() throws {
        let schema = Schema([
            Garment.self,
            WearEvent.self
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        let garment = Garment()
        garment.category = .top
        garment.loveScore = 50
        context.insert(garment)
        try context.save()

        let today = Calendar.current.startOfDay(for: Date())
        WearHistoryService.recordWorn(
            date: today,
            garmentIDs: [garment.id, garment.id],
            source: .planner,
            context: context,
            incrementTimesWorn: true,
            loveScoreDelta: 1
        )
        WearHistoryService.recordWorn(
            date: today,
            garmentIDs: [garment.id],
            source: .planner,
            context: context,
            incrementTimesWorn: true,
            loveScoreDelta: 1
        )

        let events = try context.fetch(FetchDescriptor<WearEvent>())
        let latestWearMap = WearHistoryService.latestWearMap(events: events)

        #expect(events.count == 1)
        #expect(events.first?.garmentIDs == [garment.id])
        #expect(garment.timesWorn == 1)
        #expect(garment.loveScore == 51)
        #expect(latestWearMap[garment.id] == today)
        #expect(garment.lastWorn == today)
    }

    @Test
    @MainActor
    func recommendationEventsAreIdempotentForTheSameOutfitAndSignal() throws {
        let schema = Schema([RecommendationEvent.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        let profileID = UUID()
        let planID = UUID()
        let garmentIDs = [UUID(), UUID()]
        let recommendationContext = RecoContext(
            desiredFormality: 3,
            temperatureC: 18,
            isRaining: false,
            now: Date(),
            profileID: profileID,
            warmthSensitivity: 4,
            rainTolerance: 3
        )

        let firstInsert = RecommendationEventStore.record(
            kind: .tooCold,
            selectedGarmentIDs: garmentIDs,
            shownGarmentIDs: garmentIDs,
            dayPlanID: planID,
            context: recommendationContext,
            modelContext: context
        )
        let duplicateInsert = RecommendationEventStore.record(
            kind: .tooCold,
            selectedGarmentIDs: Array(garmentIDs.reversed()),
            shownGarmentIDs: garmentIDs,
            dayPlanID: planID,
            context: recommendationContext,
            modelContext: context
        )

        let events = try context.fetch(FetchDescriptor<RecommendationEvent>())
        #expect(firstInsert)
        #expect(!duplicateInsert)
        #expect(events.count == 1)
        #expect(events.first?.profileID == profileID)
        #expect(events.first?.kind == .tooCold)
    }

    @Test
    @MainActor
    func directionalFeedbackMovesPreferenceOffsetsInExpectedDirections() throws {
        let schema = Schema([RecoState.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        let profileID = UUID()
        let recommendationContext = RecoContext(
            desiredFormality: 3,
            temperatureC: 16,
            isRaining: false,
            now: Date(),
            profileID: profileID
        )

        AIRecommender.shared.applyDirectionalFeedback(
            .tooCold,
            ctx: recommendationContext,
            modelContext: context
        )
        AIRecommender.shared.applyDirectionalFeedback(
            .tooFormal,
            ctx: recommendationContext,
            modelContext: context
        )

        let state = AIRecommender.shared.ensureState(context: context, profileID: profileID)
        let otherState = AIRecommender.shared.ensureState(context: context, profileID: UUID())
        #expect(state.learnedWarmthOffset > 0)
        #expect(state.learnedFormalityOffset < 0)
        #expect(state.interactionCount == 2)
        #expect(otherState.learnedWarmthOffset == 0)
        #expect(otherState.learnedFormalityOffset == 0)
        #expect(otherState.interactionCount == 0)
    }

    @Test
    func explicitWarmthSensitivityChangesTheWarmthMatchFeature() {
        let garment = Garment()
        garment.category = .top
        garment.warmth = 4

        let prefersWarmth = RecoContext(
            desiredFormality: 3,
            temperatureC: 20,
            isRaining: false,
            now: Date(),
            warmthSensitivity: 5
        )
        let resistsCold = RecoContext(
            desiredFormality: 3,
            temperatureC: 20,
            isRaining: false,
            now: Date(),
            warmthSensitivity: 1
        )

        let warmMatch = AIRecommender.shared.features(for: garment, ctx: prefersWarmth)[FeatureSpace.iWarmthMatch]
        let coolMatch = AIRecommender.shared.features(for: garment, ctx: resistsCold)[FeatureSpace.iWarmthMatch]

        #expect(warmMatch > coolMatch)
    }

    @Test
    @MainActor
    func currentUserPrefersSignedInProfileOverOthers() throws {
        let schema = Schema([UserProfile.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        let local = UserProfile()
        local.userIdentifier = nil
        local.displayName = "Local"
        context.insert(local)

        let apple = UserProfile()
        apple.userIdentifier = "apple.user.1"
        apple.displayName = "Apple"
        context.insert(apple)

        let other = UserProfile()
        other.userIdentifier = "apple.user.2"
        other.displayName = "Other"
        context.insert(other)
        try context.save()

        let profiles = [local, apple, other]
        let signedIn = CurrentUser.activeProfile(from: profiles, userIdentifier: "apple.user.1")
        #expect(signedIn?.id == apple.id)

        let skipped = CurrentUser.activeProfile(from: profiles, userIdentifier: nil)
        #expect(skipped?.id == local.id)

        let unknownSignedIn = CurrentUser.activeProfile(from: profiles, userIdentifier: "missing")
        #expect(unknownSignedIn == nil)
    }

    @Test
    func combinationAffinityRewardsCoWornAndPenalizesDismissedPairs() {
        let top = UUID()
        let bottom = UUID()
        let shoes = UUID()

        let worn = WearEvent(
            date: Date(),
            garmentIDs: [top, bottom],
            source: .planner
        )
        let dismissed = DismissedOutfit(
            key: [top, shoes]
                .map { $0.uuidString.lowercased() }
                .sorted()
                .joined(separator: "|")
        )

        let affinity = CombinationAffinityBuilder.build(
            wearEvents: [worn],
            dismissed: [dismissed]
        )

        #expect(affinity.score(between: top, and: bottom) > 0)
        #expect(affinity.score(between: top, and: shoes) < 0)
        #expect(affinity.topPositivePairs(limit: 3).contains(where: {
            $0.key == CombinationAffinity.pairKey(top, bottom)
        }))
    }

    @Test
    func autoFillMapperMapsClothingCategoriesAndColors() {
        let jeans = AutoFillMapper.mapClothingCategory(.jeans)
        #expect(jeans.category == .bottom)
        #expect(jeans.itemType == .jeans)

        let jacket = AutoFillMapper.mapClassifierLabel("denim_jacket")
        #expect(jacket.category == .outer)

        let colors = AutoFillMapper.colorTags(from: [
            DominantColor(hex: "#000000", name: "black", ratio: 0.6),
            DominantColor(hex: "#FFFFFF", name: "white", ratio: 0.3),
            DominantColor(hex: "#808080", name: "gray", ratio: 0.1)
        ])
        #expect(colors == [.black, .white, .gray])
        #expect(AutoFillMapper.colorTag(fromDominantName: "navy") == .navy)
        #expect(AutoFillMapper.colorTag(fromDominantName: "teal") == .blue)
    }

    @Test
    func rainReadyGarmentsReceiveContextBoost() {
        let rainReady = Garment()
        rainReady.category = .outer
        rainReady.weatherTags = [.waterproof]

        let untagged = Garment()
        untagged.category = .outer

        let recommendationContext = RecoContext(
            desiredFormality: 3,
            temperatureC: 12,
            isRaining: true,
            now: Date(),
            rainTolerance: 5
        )

        let rainReadyFeatures = AIRecommender.shared.features(for: rainReady, ctx: recommendationContext)
        let untaggedFeatures = AIRecommender.shared.features(for: untagged, ctx: recommendationContext)

        #expect(rainReadyFeatures[FeatureSpace.iRainTaste] > untaggedFeatures[FeatureSpace.iRainTaste])
        #expect(untaggedFeatures[FeatureSpace.iRainTaste] == 0)
    }

}
