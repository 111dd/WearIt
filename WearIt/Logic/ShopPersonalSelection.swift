import Foundation
import Combine

/// Keep the user's For You selection across refreshes and launches. Ranking can update
/// prices and explanations, but only a deliberate dismissal releases an occupied slot.
@MainActor
final class ShopPersonalSelection: ObservableObject {
    static let shared = ShopPersonalSelection()
    static let limit = 20
    @Published private(set) var revision = 0
    private init() {}

    private struct State: Codable, Equatable {
        var preferences: ShoppingPreferences
        var slots: [String?]
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

    static func select(from ranked: [PurchaseScorer.Pick], profileID: UUID?, preferences: ShoppingPreferences) -> [PurchaseScorer.Pick] {
        var state = load(profileID: profileID, preferences: preferences)
        let candidates = ranked.filter { $0.product.category != .accessory && $0.intent != .nextSeason }
        let occupied = Set(state.slots.compactMap { $0 })
        var replacements = candidates.filter { !occupied.contains($0.id) }.makeIterator()
        for index in state.slots.indices where state.slots[index] == nil {
            guard let next = replacements.next() else { break }
            state.slots[index] = next.id
        }
        persist(state, profileID: profileID)
        // Unavailable or no-longer-suitable products are hidden, with their slots retained.
        // They cannot cause an unrelated product to appear during an ordinary refresh.
        let selectedIDs = Set(state.slots.compactMap { $0 })
        // Keep the same products, while letting a newly useful offer among them move up.
        return candidates.filter { selectedIDs.contains($0.id) }
    }

    static func dismiss(_ productID: String, profileID: UUID?, preferences: ShoppingPreferences) {
        var state = load(profileID: profileID, preferences: preferences)
        for index in state.slots.indices where state.slots[index] == productID {
            state.slots[index] = nil
        }
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
