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
        #expect(state.version == RecoState.currentVersion)
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

    @Test
    @MainActor
    func warmDryWeatherDoesNotSuggestOuterLayers() throws {
        let schema = Schema([Garment.self, RecoState.self, RecommendationEvent.self, DismissedOutfit.self, WearEvent.self, TasteProfile.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        // Build garments without naming the Category type (ambiguous with other modules).
        let top = Garment(); top.category = .top; top.warmth = 2; top.formality = 3; context.insert(top)
        let bottom = Garment(); bottom.category = .bottom; bottom.warmth = 2; bottom.formality = 3; context.insert(bottom)
        let shoes = Garment(); shoes.category = .shoes; shoes.warmth = 2; shoes.formality = 3; context.insert(shoes)
        let outer = Garment(); outer.category = .outer; outer.warmth = 4; outer.formality = 3; context.insert(outer)
        try context.save()

        let garments = try context.fetch(FetchDescriptor<Garment>())
        let warmCtx = RecoContext(desiredFormality: 3, temperatureC: 24, isRaining: false, now: Date())
        let coolCtx = RecoContext(desiredFormality: 3, temperatureC: 12, isRaining: false, now: Date())

        #expect(warmCtx.suppressesOuterLayer)
        #expect(!coolCtx.suppressesOuterLayer)
        #expect(coolCtx.outerLayerPolicy == .prefer)

        let warmOutfit = AIRecommender.shared.suggestOutfit(from: garments, ctx: warmCtx, modelContext: context)
        #expect(!warmOutfit.contains(where: { $0.category == .outer }))

        let coolOutfit = AIRecommender.shared.suggestOutfit(from: garments, ctx: coolCtx, modelContext: context)
        #expect(coolOutfit.contains(where: { $0.category == .outer }))
    }

    @Test
    @MainActor
    func coolMorningWarmAfternoonAllowsOnlyLightOuter() throws {
        let schema = Schema([Garment.self, RecoState.self, RecommendationEvent.self, DismissedOutfit.self, WearEvent.self, TasteProfile.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        let top = Garment(); top.category = .top; top.warmth = 2; top.formality = 3; context.insert(top)
        let bottom = Garment(); bottom.category = .bottom; bottom.warmth = 2; bottom.formality = 3; context.insert(bottom)
        let shoes = Garment(); shoes.category = .shoes; shoes.warmth = 2; shoes.formality = 3; context.insert(shoes)
        let lightOuter = Garment(); lightOuter.category = .outer; lightOuter.warmth = 2; lightOuter.formality = 2; context.insert(lightOuter)
        let heavyOuter = Garment(); heavyOuter.category = .outer; heavyOuter.warmth = 5; heavyOuter.formality = 3; context.insert(heavyOuter)
        try context.save()

        let diurnal = DiurnalTemps(morning: 14, afternoon: 28, evening: 20, low: 13, high: 28)
        let ctx = RecoContext(
            desiredFormality: 3,
            temperatureC: diurnal.afternoon * 0.5 + diurnal.morning * 0.25 + diurnal.evening * 0.25,
            isRaining: false,
            now: Date(),
            diurnal: diurnal
        )
        #expect(ctx.outerLayerPolicy == .lightOnly)

        let garments = try context.fetch(FetchDescriptor<Garment>())
        let outfit = AIRecommender.shared.suggestOutfit(from: garments, ctx: ctx, modelContext: context)
        let outers = outfit.filter { $0.category == .outer }
        #expect(outers.count <= 1)
        if let picked = outers.first {
            #expect(picked.warmth <= 2)
            #expect(picked.id == lightOuter.id)
        }
    }

    @Test
    func overheatingIsPenalizedMoreThanSlightChill() {
        let hot = RecoContext(desiredFormality: 3, temperatureC: 30, isRaining: false, now: Date())
        let heavy = Garment(); heavy.warmth = 5
        let light = Garment(); light.warmth = 1

        let heavyMatch = TemperatureComfort.warmthMatch(
            garmentWarmth: heavy.warmth,
            target: TemperatureComfort.targetWarmth(temperatureC: 30),
            temperatureC: 30
        )
        let lightMatch = TemperatureComfort.warmthMatch(
            garmentWarmth: light.warmth,
            target: TemperatureComfort.targetWarmth(temperatureC: 30),
            temperatureC: 30
        )
        #expect(lightMatch > heavyMatch)
        #expect(hot.suppressesOuterLayer)
    }

    @Test
    func layeringHintsRequireCoolPartOfDay() {
        let hotSwing = DayTemperatureProfile(
            date: Date(),
            morningTemp: 24,
            afternoonTemp: 34,
            eveningTemp: 28,
            lowTemp: 23,
            highTemp: 34,
            rainProbability: 0,
            condition: .sunny
        )
        #expect(!hotSwing.layeringRecommended)
        #expect(!hotSwing.eveningJacketRecommended)
        #expect(!hotSwing.lightLayeringRecommended)

        let coolMorning = DayTemperatureProfile(
            date: Date(),
            morningTemp: 14,
            afternoonTemp: 26,
            eveningTemp: 18,
            lowTemp: 13,
            highTemp: 26,
            rainProbability: 0,
            condition: .sunny
        )
        #expect(coolMorning.layeringRecommended)
        #expect(coolMorning.lightLayeringRecommended)
    }

    // MARK: - LookWearStatus / DayPlan persistence

    @Test
    func lookWearStatusRawValueMapping() {
        #expect(LookWearStatus.planned.rawValue == "planned")
        #expect(LookWearStatus.worn.rawValue == "worn")
        #expect(LookWearStatus.notWorn.rawValue == "notWorn")
        #expect(LookWearStatus(rawValue: "planned") == .planned)
        #expect(LookWearStatus(rawValue: "worn") == .worn)
        #expect(LookWearStatus(rawValue: "notWorn") == .notWorn)
        #expect(LookWearStatus(rawValue: "undecided") == nil)
        #expect(LookWearStatus(rawValue: "bogus") == nil)
    }

    @Test
    @MainActor
    func dayPlanLegacyWasWornConfirmedFallsBackToDayWorn() throws {
        let schema = Schema([DayPlan.self, UserProfile.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        let date = Calendar.current.startOfDay(for: Date())
        let plan = DayPlanService.shared.planFor(date: date, context: context)
        plan.wasWornConfirmed = true
        // No new raw fields — legacy record.
        #expect(plan.dayLookWearStatusRaw == nil)
        #expect(plan.eveningLookWearStatusRaw == nil)
        #expect(plan.dayLookWearStatus == nil)
        #expect(plan.eveningLookWearStatus == nil)
        #expect(plan.resolvedDayLookWearStatus == .worn)
        // Evening must not be inferred from wasWornConfirmed.
        #expect(plan.eveningLookWearStatus == nil)
        try context.save()
    }

    @Test
    @MainActor
    func replacedDayLookDoesNotInheritLegacyWornStatus() throws {
        let schema = Schema([DayPlan.self, UserProfile.self, WearEvent.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        let date = Calendar.current.startOfDay(for: Date())
        let plan = DayPlanService.shared.planFor(date: date, context: context)
        plan.wasWornConfirmed = true
        plan.eveningLookWearStatus = .planned
        // Simulate historical WearEvent still present for the prior outfit.
        let priorEvent = WearEvent(
            date: date,
            garmentIDs: [UUID()],
            source: .planner,
            slot: nil,
            outfitID: nil
        )
        context.insert(priorEvent)
        try context.save()

        #expect(plan.resolvedDayLookWearStatus == .worn)

        // Replace/reset day look — clears current-assignment confirmation, keeps evening + WearEvents.
        plan.applyDayLookWearStatus(nil)
        try context.save()

        let reloaded = DayPlanService.shared.planFor(date: date, context: context)
        #expect(reloaded.dayLookWearStatus == nil)
        #expect(reloaded.wasWornConfirmed == false)
        #expect(reloaded.resolvedDayLookWearStatus == nil)
        #expect(reloaded.eveningLookWearStatus == .planned)

        let events = try context.fetch(FetchDescriptor<WearEvent>())
        #expect(events.count == 1)
        #expect(events.first?.source == .planner)
    }

    @Test
    @MainActor
    func dayAndEveningLookWearStatusAreIndependent() throws {
        let schema = Schema([DayPlan.self, UserProfile.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        let date = Calendar.current.startOfDay(for: Date())
        let plan = DayPlanService.shared.planFor(date: date, context: context)
        plan.applyDayLookWearStatus(.worn)
        plan.applyEveningLookWearStatus(.notWorn)
        try context.save()

        let reloaded = DayPlanService.shared.planFor(date: date, context: context)
        #expect(reloaded.dayLookWearStatus == .worn)
        #expect(reloaded.eveningLookWearStatus == .notWorn)
        #expect(reloaded.wasWornConfirmed == true)

        reloaded.applyEveningLookWearStatus(.planned)
        try context.save()
        #expect(reloaded.dayLookWearStatus == .worn)
        #expect(reloaded.eveningLookWearStatus == .planned)
        #expect(reloaded.wasWornConfirmed == true)
    }

    @Test
    @MainActor
    func notWornPersistsAcrossReload() throws {
        let schema = Schema([DayPlan.self, UserProfile.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        let date = Calendar.current.startOfDay(for: Date())
        let plan = DayPlanService.shared.planFor(date: date, context: context)
        plan.applyDayLookWearStatus(.notWorn)
        plan.applyEveningLookWearStatus(.notWorn)
        try context.save()

        let reloaded = DayPlanService.shared.planFor(date: date, context: context)
        #expect(reloaded.dayLookWearStatusRaw == "notWorn")
        #expect(reloaded.eveningLookWearStatusRaw == "notWorn")
        #expect(reloaded.dayLookWearStatus == .notWorn)
        #expect(reloaded.eveningLookWearStatus == .notWorn)
        #expect(reloaded.wasWornConfirmed == false)
        #expect(reloaded.resolvedDayLookWearStatus == .notWorn)
    }

    @Test
    @MainActor
    func replacingOneSlotResetsOnlyThatSlotStatus() throws {
        let schema = Schema([DayPlan.self, UserProfile.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        let date = Calendar.current.startOfDay(for: Date())
        let plan = DayPlanService.shared.planFor(date: date, context: context)
        plan.applyDayLookWearStatus(.notWorn)
        plan.applyEveningLookWearStatus(.worn)
        try context.save()

        // Simulate replace on day slot only.
        plan.applyDayLookWearStatus(nil)
        try context.save()

        let reloaded = DayPlanService.shared.planFor(date: date, context: context)
        #expect(reloaded.dayLookWearStatus == nil)
        #expect(reloaded.wasWornConfirmed == false)
        #expect(reloaded.resolvedDayLookWearStatus == nil)
        #expect(reloaded.eveningLookWearStatus == .worn)
    }

    @Test
    @MainActor
    func markWornThenReplaceDayClearsWornWithoutTouchingEvening() throws {
        let schema = Schema([DayPlan.self, UserProfile.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        let date = Calendar.current.startOfDay(for: Date())
        let plan = DayPlanService.shared.planFor(date: date, context: context)
        plan.applyDayLookWearStatus(.worn)
        plan.applyEveningLookWearStatus(.planned)
        try context.save()
        #expect(plan.resolvedDayLookWearStatus == .worn)

        plan.applyDayLookWearStatus(nil)
        try context.save()

        let reloaded = DayPlanService.shared.planFor(date: date, context: context)
        #expect(reloaded.resolvedDayLookWearStatus == nil)
        #expect(reloaded.wasWornConfirmed == false)
        #expect(reloaded.eveningLookWearStatus == .planned)
    }

    @Test
    @MainActor
    func markNotWornThenReplaceDayStaysUndecided() throws {
        let schema = Schema([DayPlan.self, UserProfile.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        let date = Calendar.current.startOfDay(for: Date())
        let plan = DayPlanService.shared.planFor(date: date, context: context)
        plan.applyDayLookWearStatus(.notWorn)
        try context.save()

        plan.applyDayLookWearStatus(nil)
        try context.save()

        let reloaded = DayPlanService.shared.planFor(date: date, context: context)
        #expect(reloaded.dayLookWearStatus == nil)
        #expect(reloaded.resolvedDayLookWearStatus == nil)
        #expect(reloaded.wasWornConfirmed == false)
    }

    @Test
    @MainActor
    func replaceEveningWhileDayWornLeavesDayIntact() throws {
        let schema = Schema([DayPlan.self, UserProfile.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        let date = Calendar.current.startOfDay(for: Date())
        let plan = DayPlanService.shared.planFor(date: date, context: context)
        plan.applyDayLookWearStatus(.worn)
        plan.applyEveningLookWearStatus(.notWorn)
        try context.save()

        plan.applyEveningLookWearStatus(nil)
        try context.save()

        let reloaded = DayPlanService.shared.planFor(date: date, context: context)
        #expect(reloaded.resolvedDayLookWearStatus == .worn)
        #expect(reloaded.wasWornConfirmed == true)
        #expect(reloaded.eveningLookWearStatus == nil)
    }

    @Test
    @MainActor
    func clearDayStatusDoesNotModifyEvening() throws {
        let schema = Schema([DayPlan.self, UserProfile.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        let date = Calendar.current.startOfDay(for: Date())
        let plan = DayPlanService.shared.planFor(date: date, context: context)
        plan.applyDayLookWearStatus(.worn)
        plan.applyEveningLookWearStatus(.worn)
        try context.save()

        plan.applyDayLookWearStatus(nil)
        try context.save()

        let reloaded = DayPlanService.shared.planFor(date: date, context: context)
        #expect(reloaded.resolvedDayLookWearStatus == nil)
        #expect(reloaded.wasWornConfirmed == false)
        #expect(reloaded.eveningLookWearStatus == .worn)
    }

    // MARK: - AI look explanations (deterministic parts only — no model calls)

    private func makeExplanationRequest(
        garmentIDs: [String] = ["A", "B"],
        occasion: String? = "work",
        languageCode: String = "en"
    ) -> LookExplanationRequest {
        LookExplanationRequest(
            date: Date(timeIntervalSince1970: 1_800_000_000),
            lookTime: "day",
            garmentIDs: garmentIDs,
            garments: [
                .init(title: "White tee", category: "top", colors: ["white"], warmth: 2),
                .init(title: "Navy chinos", category: "bottom", colors: ["navy"], warmth: 3)
            ],
            weather: .init(
                morningTemp: 17.4,
                afternoonTemp: 26.2,
                eveningTemp: 19.1,
                rainProbability: 0.1,
                condition: "sunny"
            ),
            occasion: occasion,
            tastePoints: ["often wears black"],
            languageCode: languageCode
        )
    }

    @Test func lookExplanationCacheKeyIsStableAndOrderInsensitive() {
        let a = makeExplanationRequest(garmentIDs: ["A", "B"])
        let b = makeExplanationRequest(garmentIDs: ["B", "A"])
        #expect(a.cacheKey == b.cacheKey)
        #expect(a.cacheKey.hasPrefix("v\(LookExplanationRequest.promptVersion)#"))
    }

    @Test func lookExplanationCacheKeyChangesWithInputs() {
        let base = makeExplanationRequest()
        #expect(makeExplanationRequest(occasion: nil).cacheKey != base.cacheKey)
        #expect(makeExplanationRequest(languageCode: "fr").cacheKey != base.cacheKey)
        #expect(makeExplanationRequest(garmentIDs: ["A", "C"]).cacheKey != base.cacheKey)
    }

    @Test func lookExplanationPromptContainsFactsButNoIDs() {
        let request = makeExplanationRequest()
        let prompt = request.prompt
        #expect(prompt.contains("White tee"))
        #expect(prompt.contains("Navy chinos"))
        #expect(prompt.contains("sunny"))
        #expect(prompt.contains("Occasion: work."))
        #expect(prompt.contains("often wears black"))
        // Garment IDs are cache-key identity only; they must not leak into the prompt.
        #expect(!prompt.contains("#"))
        #expect(!prompt.contains("\"A\""))
    }

    @Test func garmentNamePromptIncludesOnlyMeaningfulFacts() {
        let request = GarmentNameRequest(
            category: "top",
            itemType: "shirt",
            colors: ["white"],
            material: "linen",
            pattern: "solid",
            fit: "regular",
            brand: "Zara",
            languageCode: "en"
        )
        let prompt = request.prompt
        #expect(prompt.contains("category: top"))
        #expect(prompt.contains("type: shirt"))
        #expect(prompt.contains("colors: white"))
        #expect(prompt.contains("material: linen"))
        #expect(prompt.contains("brand: Zara"))
        // Default values add noise, not signal — they must be omitted.
        #expect(!prompt.contains("pattern:"))
        #expect(!prompt.contains("fit:"))
    }

    @Test func lookExplanationResultDisplayTextJoinsTip() {
        let withTip = LookExplanationResult(summary: "Light layers.", tip: "Take a jacket.")
        #expect(withTip.displayText == "Light layers. Take a jacket.")
        let noTip = LookExplanationResult(summary: "Light layers.", tip: nil)
        #expect(noTip.displayText == "Light layers.")
    }

    // MARK: - Garment enrichment

    @Test func itemTypeDefaultsFillOnlyGenericValues() {
        let garment = Garment()
        garment.category = .top
        garment.itemType = .tshirt
        garment.warmth = 3          // generic default — should be replaced
        garment.formality = 5       // user-looking value — must survive

        let applied = ItemTypeDefaults.apply(to: garment)

        #expect(garment.warmth == 1)
        #expect(garment.formality == 5)
        #expect(garment.seasonSuitability == .summer)
        #expect(garment.layerRole == .base)
        #expect(applied.contains(ItemTypeDefaults.FieldKey.warmth))
        #expect(!applied.contains(ItemTypeDefaults.FieldKey.formality))
    }

    @Test func itemTypeDefaultsRespectUserEditedFields() {
        let garment = Garment()
        garment.category = .top
        garment.itemType = .tshirt
        garment.warmth = 3

        let applied = ItemTypeDefaults.apply(
            to: garment,
            userEditedFields: [ItemTypeDefaults.FieldKey.warmth]
        )

        #expect(garment.warmth == 3)
        #expect(!applied.contains(ItemTypeDefaults.FieldKey.warmth))
    }

    @Test func garmentProvenanceMarkAndClear() {
        let garment = Garment()
        garment.markEnriched([ItemTypeDefaults.FieldKey.warmth, ItemTypeDefaults.FieldKey.season])
        #expect(garment.aiEnrichedFields == ["season", "warmth"])

        garment.markUserEdited(ItemTypeDefaults.FieldKey.warmth)
        #expect(garment.aiEnrichedFields == ["season"])

        garment.markUserEdited(ItemTypeDefaults.FieldKey.season)
        #expect(garment.aiEnrichedFieldsRaw == nil)
    }

    @MainActor
    @Test func aiEnrichmentOnlyOverwritesOwnedOrGenericFields() {
        let garment = Garment()
        garment.category = .top
        garment.itemType = .sweater
        garment.warmth = 4          // enrichment-owned (marked below)
        garment.formality = 2       // user value, unmarked — must survive
        garment.markEnriched([ItemTypeDefaults.FieldKey.warmth])

        let result = GarmentAttributesResult(
            warmth: 5,
            formality: 4,
            season: .winter,
            styleTags: [.casual],
            occasionTags: [.work],
            material: .wool
        )
        GarmentEnrichmentService.apply(result, to: garment)

        #expect(garment.warmth == 5)              // owned → refined
        #expect(garment.formality == 2)           // user value → untouched
        #expect(garment.seasonSuitability == .winter) // was nil → filled
        #expect(garment.styleTags == [.casual])
        #expect(garment.occasionTags == [.work])
        #expect(garment.materialTags == [.wool])
        #expect(garment.aiEnrichedFields.contains(ItemTypeDefaults.FieldKey.materialTags))
        #expect(!garment.aiEnrichedFields.contains(ItemTypeDefaults.FieldKey.formality))
    }

    @Test func garmentAttributesPromptContainsFacts() {
        let request = GarmentAttributesRequest(
            category: "outer",
            itemType: "puffer",
            colors: ["black"],
            pattern: "solid",
            brand: "Uniqlo"
        )
        let prompt = request.prompt
        #expect(prompt.contains("category: outer"))
        #expect(prompt.contains("type: puffer"))
        #expect(prompt.contains("colors: black"))
        #expect(prompt.contains("brand: Uniqlo"))
        // "solid" is the default pattern — noise, not signal.
        #expect(!prompt.contains("pattern:"))
    }

    // MARK: - Label scanning

    @Test func labelScanParsesMaterialsAndSize() {
        let result = LabelScanService.parse(lines: [
            "60% COTTON 35% POLYESTER 5% ELASTANE",
            "SIZE M",
            "MACHINE WASH COLD"
        ])
        #expect(result.materials.contains(.cotton))
        #expect(result.materials.contains(.polyester))
        #expect(result.materials.contains(.spandex))
        #expect(result.size == .m)
    }

    @Test func labelScanDetectsWaistAndShoeSizes() {
        #expect(LabelScanService.parse(lines: ["W32 L34"]).size == .w32)
        #expect(LabelScanService.parse(lines: ["EU 43", "100% LEATHER"]).size == .eu43)
    }

    @Test func labelScanIgnoresEmbeddedSizeLetters() {
        // "L" inside ordinary words must not be read as a size.
        let result = LabelScanService.parse(lines: ["LAVAGE EN MACHINE INTERDIT DELICATE CYCLE ONLY"])
        #expect(result.size == nil)
    }

}