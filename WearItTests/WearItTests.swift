//
//  WearItTests.swift
//  WearItTests
//
//  Created by Dor David on 05/09/2025.
//

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

}
