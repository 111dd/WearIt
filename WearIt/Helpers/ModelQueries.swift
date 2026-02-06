import Foundation
import SwiftData

extension UserProfile {
    static func current(in context: ModelContext) -> UserProfile {
        if let existing = try? context.fetch(FetchDescriptor<UserProfile>()).first {
            return existing
        }
        let profile = UserProfile()
        context.insert(profile)
        return profile
    }
}

enum ModelQueries {
    static func fetchGarments(ids: [UUID], context: ModelContext) -> [Garment] {
        guard !ids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<Garment>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        let fetched = (try? context.fetch(descriptor)) ?? []
        let map = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        return ids.compactMap { map[$0] }
    }

    static func fetchOutfits(ids: [UUID], context: ModelContext) -> [Outfit] {
        guard !ids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<Outfit>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        let fetched = (try? context.fetch(descriptor)) ?? []
        let map = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        return ids.compactMap { map[$0] }
    }

    static func fetchPlans(ids: [UUID], context: ModelContext) -> [DayPlan] {
        guard !ids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<DayPlan>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        let fetched = (try? context.fetch(descriptor)) ?? []
        let map = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        return ids.compactMap { map[$0] }
    }

    static func fetchLooks(ids: [UUID], context: ModelContext) -> [DailyLook] {
        guard !ids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<DailyLook>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        let fetched = (try? context.fetch(descriptor)) ?? []
        let map = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        return ids.compactMap { map[$0] }
    }

    static func fetchOutfits(containing garmentID: UUID, context: ModelContext) -> [Outfit] {
        let descriptor = FetchDescriptor<Outfit>(
            predicate: #Predicate { $0.itemIDs.contains(garmentID) }
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
