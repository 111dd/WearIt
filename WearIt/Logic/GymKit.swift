import Foundation

extension Garment {
    /// Workout clothes: tagged for the gym by the user (or AI), an activewear
    /// item type, or a sporty piece.
    var isActivewear: Bool {
        if occasionTags?.contains(.gym) == true { return true }
        switch itemType {
        case .leggings?, .joggers?, .sweatpants?, .tank?:
            return true
        default:
            break
        }
        guard category != .accessory, styleTags?.contains(.sporty) == true else { return false }
        // Sporty sneakers count; a sporty-styled coat or loafer does not.
        return category != .outer || itemType == .windbreaker
    }

    var isWorkwear: Bool {
        occasionTags?.contains(.work) == true
    }
}

/// What to pack for a workout: one top, one bottom and shoes from the
/// wardrobe, preferring pieces the user tagged for the gym.
enum GymKit {
    static func kit(from garments: [Garment]) -> [Garment] {
        let usable = garments.filter { !$0.isBlocked && !$0.isCurrentlyUnavailable }
        func best(_ category: Category, _ fallback: ((Garment) -> Bool)? = nil) -> Garment? {
            let pool = usable.filter { $0.category == category }
            let active = pool.filter(\.isActivewear)
            let candidates = active.isEmpty ? pool.filter { fallback?($0) ?? false } : active
            return candidates.max { lhs, rhs in
                let l = (lhs.occasionTags?.contains(.gym) == true ? 1 : 0, lhs.loveScore)
                let r = (rhs.occasionTags?.contains(.gym) == true ? 1 : 0, rhs.loveScore)
                return l < r
            }
        }
        return [
            best(.top),
            best(.bottom) { $0.itemType == .shorts },
            best(.shoes) { $0.itemType == .sneakers }
        ].compactMap { $0 }
    }
}
