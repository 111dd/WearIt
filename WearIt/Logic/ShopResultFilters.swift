import Foundation

/// Each shopping mode owns its own value. These narrow a list without changing taste.
struct ShopResultFilters: Hashable, Sendable {
    enum Focus: Hashable, Sendable {
        case all, upcoming, everyday, nextSeason
    }

    var category: Category? = nil
    var itemType: ItemType? = nil
    var dealsOnly = false
    var savedOnly = false
    var focus: Focus = .all
    /// Empty means every store. Store IDs come from the catalog, never display names.
    var storeIDs: Set<String> = []

    var isDefault: Bool {
        category == nil && itemType == nil && !dealsOnly && !savedOnly && focus == .all && storeIDs.isEmpty
    }

    mutating func selectCategory(_ category: Category?) {
        guard self.category != category else { return }
        self.category = category
        itemType = nil
    }

    func includes(_ pick: PurchaseScorer.Pick) -> Bool {
        if !storeIDs.isEmpty && !storeIDs.contains(pick.product.item.store) { return false }
        if let category, pick.product.category != category { return false }
        if let itemType, pick.product.itemType != itemType { return false }
        if dealsOnly && pick.product.discountPercent == nil { return false }
        switch focus {
        case .all: return true
        case .upcoming: return pick.intent == .upcoming
        case .everyday: return pick.intent == .everyday
        case .nextSeason: return pick.intent == .nextSeason
        }
    }
}
