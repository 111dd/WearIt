import Foundation
import Combine

/// Keep the user's For You selection across refreshes and launches. Ranking can update
/// prices and explanations. A slot is released by a deliberate dismissal, by owning the
/// product, or after the product has stayed out of the ranking for `absenceLimit`.
@MainActor
final class ShopPersonalSelection: ObservableObject {
    static let shared = ShopPersonalSelection()
    static let limit = 20
    /// A product missing this long is treated as gone, not as briefly out of stock.
    nonisolated static let absenceLimit: TimeInterval = 14 * 86_400
    @Published private(set) var revision = 0
    private init() {}

    private struct State: Codable, Equatable {
        var preferences: ShoppingPreferences
        var slots: [String?]
        /// Whole seconds since 1970 when a held product was first seen missing from the ranking.
        /// Optional so selections saved before this field still decode.
        var missingSince: [String: Int]?
    }

    private static func key(profileID: UUID?) -> String {
        "shop.personalSelection.v1." + (profileID?.uuidString ?? "local")
    }

    private static func relevancePreferences(_ preferences: ShoppingPreferences) -> ShoppingPreferences {
        var value = preferences
        // Choosing a different photo presentation must not replace the recommendations.
        value.preferProductOnlyPhotos = true
        return value
    }

    private static func load(profileID: UUID?, preferences: ShoppingPreferences) -> State {
        let preferences = relevancePreferences(preferences)
        if let data = UserDefaults.standard.data(forKey: key(profileID: profileID)),
           let state = try? JSONDecoder().decode(State.self, from: data),
           state.preferences == preferences {
            return state
        }
        return State(preferences: preferences, slots: Array(repeating: nil, count: limit))
    }

    static func retainedIDs(profileID: UUID?, preferences: ShoppingPreferences) -> [String] {
        load(profileID: profileID, preferences: preferences).slots.compactMap { $0 }
    }

    /// `isOwned` reports products the user already bought or has in the wardrobe.
    static func select(from ranked: [PurchaseScorer.Pick], profileID: UUID?, preferences: ShoppingPreferences,
        isOwned: (String) -> Bool = { _ in false }, now: Date = Date()) -> [PurchaseScorer.Pick] {
        var state = load(profileID: profileID, preferences: preferences)
        let candidates = ranked.filter { $0.product.category != .accessory && $0.intent != .nextSeason }
        let updated = updatedSlots(state.slots, missingSince: state.missingSince ?? [:],
            candidateIDs: candidates.map(\.id), ownedIDs: Set(state.slots.compactMap { $0 }.filter(isOwned)),
            now: Int(now.timeIntervalSince1970))
        state.slots = updated.slots
        state.missingSince = updated.missingSince.isEmpty ? nil : updated.missingSince
        persist(state, profileID: profileID)
        // Briefly unavailable or unsuitable products are hidden, with their slots retained.
        // They cannot cause an unrelated product to appear during an ordinary refresh.
        let selectedIDs = Set(state.slots.compactMap { $0 })
        // Keep the same products, while letting a newly useful offer among them move up.
        return candidates.filter { selectedIDs.contains($0.id) }
    }

    /// Slot bookkeeping on IDs alone, separate from storage.
    /// An owned product frees its slot at once. A product missing from a non-empty ranking
    /// keeps its slot until it has been missing for `absenceLimit`; an empty ranking carries
    /// no information and never starts or advances that clock. Free slots then take the
    /// best candidates that do not already hold one.
    nonisolated static func updatedSlots(_ slots: [String?], missingSince: [String: Int],
        candidateIDs: [String], ownedIDs: Set<String>, now: Int) -> (slots: [String?], missingSince: [String: Int]) {
        var slots = slots
        var missing: [String: Int] = [:]
        let present = Set(candidateIDs)
        for index in slots.indices {
            guard let id = slots[index] else { continue }
            if ownedIDs.contains(id) { slots[index] = nil; continue }
            if present.contains(id) { continue }
            guard !candidateIDs.isEmpty else {
                missing[id] = missingSince[id]
                continue
            }
            let since = missingSince[id] ?? now
            if Double(now - since) >= absenceLimit { slots[index] = nil } else { missing[id] = since }
        }
        let occupied = Set(slots.compactMap { $0 })
        var replacements = candidateIDs.filter { !occupied.contains($0) && !ownedIDs.contains($0) }.makeIterator()
        for index in slots.indices where slots[index] == nil {
            guard let next = replacements.next() else { break }
            slots[index] = next
        }
        return (slots, missing)
    }

    static func dismiss(_ productID: String, profileID: UUID?, preferences: ShoppingPreferences) {
        var state = load(profileID: profileID, preferences: preferences)
        for index in state.slots.indices where state.slots[index] == productID {
            state.slots[index] = nil
        }
        state.missingSince?[productID] = nil
        if state.missingSince?.isEmpty == true { state.missingSince = nil }
        persist(state, profileID: profileID)
    }

    private static func persist(_ state: State, profileID: UUID?) {
        let key = key(profileID: profileID)
        if let data = UserDefaults.standard.data(forKey: key),
           let stored = try? JSONDecoder().decode(State.self, from: data), stored == state {
            return
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
        shared.revision += 1
    }
}
