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
        worn.isWorn = true

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
            latestWearMap: [:]
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
        worn.isWorn = true

        let unavailable = Garment()
        unavailable.category = .top
        unavailable.unavailableUntil = calendar.date(byAdding: .day, value: 1, to: date)

        let cooldown = Garment()
        cooldown.category = .top

        let available = Garment()
        available.category = .top

        let latestWearMap = [
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
    func rainReadyGarmentsReceiveContextBoost() throws {
        let schema = Schema([RecoState.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

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

        let rainReadyScore = AIRecommender.shared.score(
            rainReady,
            ctx: recommendationContext,
            modelContext: context
        )
        let untaggedScore = AIRecommender.shared.score(
            untagged,
            ctx: recommendationContext,
            modelContext: context
        )

        #expect(rainReadyScore > untaggedScore)
    }

}
