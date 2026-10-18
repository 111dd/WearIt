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
        case .opened: return 0.55
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

    mutating func learn(_ x: [Double], label: Double, weight: Double = 1) {
        if weights.count < x.count { weights += Array(repeating: 0, count: x.count - weights.count) }
        let error = label - predict(x)
        for i in 0..<x.count {
            // Light L2 so one strong reaction doesn't swamp the wardrobe prior.
            weights[i] += Self.learningRate * weight * (error * x[i] - 0.01 * weights[i])
        }
        bias += Self.learningRate * weight * error
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
        /// Optional for decoding the original v1 state. Dismissals and visits also teach attributes.
        var observedItems: [String: ShopCatalogItem]?
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

    /// Attribute evidence supplements the numeric model: reacting to one brand/color/type
    /// can change similar products, rather than just learning a global preference for shopping.
    struct Signals {
        var affinity: [String: Double] = [:]
        var recentPurchases: [ShopProduct] = []
        static let empty = Signals()

        func recentPurchasePenalty(for product: ShopProduct) -> Double {
            let matches = recentPurchases.filter {
                $0.category == product.category && $0.itemType == product.itemType
                    && !Set($0.colors).isDisjoint(with: product.colors)
            }
            guard !matches.isEmpty else { return 0 }
            let brand = product.item.brand.map(BrandStore.normalizeBrandKey)
            return matches.contains { $0.item.brand.map(BrandStore.normalizeBrandKey) == brand && brand != nil } ? 0.3 : 0.15
        }

        func score(for product: ShopProduct) -> Double {
            let values = Self.keys(for: product).compactMap { affinity[$0] }
            guard !values.isEmpty else { return 0 }
            return values.reduce(0, +) / Double(values.count)
        }

        static func keys(for product: ShopProduct) -> [String] {
            var keys = product.colors.map { "color:\($0.rawValue)" }
            if let brand = product.item.brand { keys.append("brand:\(BrandStore.normalizeBrandKey(brand))") }
            if let type = product.itemType {
                keys.append("type:\(type.rawValue)")
            }
            keys += product.styleTags.map { "style:\($0.rawValue)" }
            if let fit = product.fit { keys.append("fit:\(fit.rawValue)") }
            if let pattern = product.pattern { keys.append("pattern:\(pattern.rawValue)") }
            return keys
        }
    }

    var signals: Signals {
        var mass: [String: Double] = [:]
        var exposure: [String: Double] = [:]
        var recentPurchases: [ShopProduct] = []
        let now = Date()
        for (id, actions) in state.actions {
            guard let item = state.observedItems?[id] ?? state.keptItems[id],
                  let product = ShopCatalogService.map(item, storeName: item.store) else { continue }
            let kind: ShopFeedbackKind
            if actions[.bought] != nil { kind = .bought }
            else if let dismissed = actions[.dismissed], dismissed >= (actions[.saved] ?? .distantPast) { kind = .dismissed }
            else if actions[.saved] != nil { kind = .saved }
            else { kind = .opened }
            guard let date = actions[kind] else { continue }
            let age = max(0, now.timeIntervalSince(date) / 86_400)
            if kind == .bought && age <= 90 { recentPurchases.append(product) }
            let strength: Double
            switch kind {
            case .bought: strength = 3
            case .saved: strength = 2
            case .dismissed: strength = -2
            case .opened: strength = 0.15
            }
            let value = strength * pow(0.5, age / 180)
            for key in Signals.keys(for: product) {
                mass[key, default: 0] += value
                exposure[key, default: 0] += abs(value)
            }
        }
        let affinity: [String: Double] = mass.reduce(into: [:]) { result, entry in
            result[entry.key] = entry.value / max(4, exposure[entry.key] ?? 0)
        }
        return Signals(affinity: affinity, recentPurchases: recentPurchases)
    }

    /// Records the action and trains the model on the pick's features.
    func record(_ kind: ShopFeedbackKind, pick: PurchaseScorer.Pick) {
        let id = pick.product.id
        var actions = state.actions[id] ?? [:]
        // Train once per kind, so tapping "open" five times isn't five lessons.
        let isNew = actions[kind] == nil
        actions[kind] = Date()
        if kind == .dismissed { actions[.saved] = nil }
        state.actions[id] = actions
        if state.observedItems == nil { state.observedItems = [:] }
        state.observedItems?[id] = pick.product.item
        if kind == .saved || kind == .bought {
            state.keptItems[id] = pick.product.item
        }
        if isNew && !pick.features.isEmpty {
            state.model.learn(pick.features, label: kind.label, weight: kind == .opened ? 0.2 : 1)
        }
        // Keep snapshots bounded; action dates remain for saved/bought/hidden semantics.
        if (state.observedItems?.count ?? 0) > 400 {
            let oldest = (state.observedItems ?? [:]).keys.sorted {
                (state.actions[$0]?.values.max() ?? .distantPast) < (state.actions[$1]?.values.max() ?? .distantPast)
            }
            for stale in oldest.prefix((state.observedItems?.count ?? 0) - 400) { state.observedItems?[stale] = nil }
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
