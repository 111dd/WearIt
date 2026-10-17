//
//  ShopFeedback.swift
//  WearIt
//
//  What the user did with shop picks (saved, opened in the shop, not for me, bought) and the small
//  logistic model that learns from it on top of `PurchaseScorer`'s wardrobe-based prior.
//  UserDefaults only: nothing here syncs or leaves the device ("Delete all my data" wipes it).
//

import Foundation

enum ShopFeedbackKind: String, Codable {
    case saved, opened, dismissed, bought

    /// Training label for the preference model.
    var label: Double {
        switch self {
        case .dismissed: return 0
        case .opened: return 0.8
        case .saved: return 1
        case .bought: return 1
        }
    }
}

/// Learned on-device: which kinds of picks this user actually acts on.
struct ShopPreferenceModel: Codable {
    var weights: [Double] = []
    var bias: Double = 0
    var interactions: Int = 0

    static let learningRate = 0.15

    func predict(_ x: [Double]) -> Double {
        var s = bias
        for i in 0..<min(weights.count, x.count) { s += weights[i] * x[i] }
        return 1 / (1 + exp(-s))
    }

    mutating func learn(_ x: [Double], label: Double) {
        if weights.count < x.count { weights += Array(repeating: 0, count: x.count - weights.count) }
        let error = label - predict(x)
        for i in 0..<x.count {
            // Light L2 so one strong reaction doesn't swamp the wardrobe prior.
            weights[i] += Self.learningRate * (error * x[i] - 0.01 * weights[i])
        }
        bias += Self.learningRate * error
        interactions += 1
    }
}

@MainActor
final class ShopFeedbackStore: ObservableObject {
    static let shared = ShopFeedbackStore()

    struct State: Codable {
        /// Product id → kind → when.
        var actions: [String: [ShopFeedbackKind: Date]] = [:]
        var model = ShopPreferenceModel()
        /// Saved / bought products, kept so they still show after they leave the catalog.
        var keptItems: [String: ShopCatalogItem] = [:]
    }

    @Published private(set) var state: State

    private static let key = "shop.feedback.v1"
    /// "Not for me" hides a product for this long.
    private static let dismissDays: Double = 120

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            state = decoded
        } else {
            state = State()
        }
    }

    func has(_ kind: ShopFeedbackKind, _ productID: String) -> Bool {
        state.actions[productID]?[kind] != nil
    }

    func isHidden(_ productID: String, now: Date = Date()) -> Bool {
        if has(.bought, productID) { return true }
        guard let dismissed = state.actions[productID]?[.dismissed] else { return false }
        return now.timeIntervalSince(dismissed) < Self.dismissDays * 86_400
    }

    var savedIDs: [String] {
        state.actions.filter { $0.value[.saved] != nil && $0.value[.bought] == nil }
            .sorted { ($0.value[.saved] ?? .distantPast) > ($1.value[.saved] ?? .distantPast) }
            .map(\.key)
    }

    func keptItem(_ id: String) -> ShopCatalogItem? { state.keptItems[id] }

    /// Records the action and trains the model on the pick's features.
    func record(_ kind: ShopFeedbackKind, pick: PurchaseScorer.Pick) {
        let id = pick.product.id
        var actions = state.actions[id] ?? [:]
        // Train once per kind, so tapping "open" five times isn't five lessons.
        let isNew = actions[kind] == nil
        actions[kind] = Date()
        if kind == .dismissed { actions[.saved] = nil }
        state.actions[id] = actions
        if kind == .saved || kind == .bought {
            state.keptItems[id] = pick.product.item
        }
        if isNew {
            state.model.learn(pick.features, label: kind.label)
        }
        persist()
    }

    func unsave(_ productID: String) {
        state.actions[productID]?[.saved] = nil
        if state.actions[productID]?[.bought] == nil { state.keptItems[productID] = nil }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
