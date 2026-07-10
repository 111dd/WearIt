import Foundation
import SwiftData

/// Durable, deal-searchable taste snapshot per user profile.
/// Built from wardrobe signals; safe to read from a future deals service
/// without recomputing affinities every time.
@Model
final class TasteProfile {
    var id: String = "global"
    var profileID: UUID?
    var updatedAt: Date = Foundation.Date()
    var sourceGarmentCount: Int = 0

    // Parallel arrays keep CloudKit / SwiftData happy (no nested dictionaries).
    var topColorRawValues: [String] = []
    var topColorShares: [Double] = []
    var topBrandKeys: [String] = []
    var topBrandShares: [Double] = []
    var topStyleRawValues: [String] = []
    var topStyleShares: [Double] = []
    var topCategoryRawValues: [String] = []
    var topCategoryShares: [Double] = []
    var topMaterialRawValues: [String] = []
    var topMaterialShares: [Double] = []
    var topFitRawValues: [String] = []
    var topFitShares: [Double] = []

    var avoidColorRawValues: [String] = []
    var avoidColorShares: [Double] = []
    var avoidBrandKeys: [String] = []
    var avoidBrandShares: [Double] = []

    var formalityMean: Double = 3
    var warmthMean: Double = 3
    var formalitySpread: Double = 0

    init(profileID: UUID? = nil) {
        self.id = profileID.map { "profile-\($0.uuidString)" } ?? "global"
        self.profileID = profileID
        self.updatedAt = Foundation.Date()
    }
}

enum TasteProfileStore {
    static func ensure(profileID: UUID?, context: ModelContext) -> TasteProfile {
        let key = profileID.map { "profile-\($0.uuidString)" } ?? "global"
        let descriptor = FetchDescriptor<TasteProfile>(
            predicate: #Predicate { $0.id == key }
        )
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let created = TasteProfile(profileID: profileID)
        context.insert(created)
        return created
    }

    /// Persist a deal-ready snapshot from the in-memory affinity profile.
    static func persist(
        _ taste: TasteAffinityBuilder.Profile,
        profileID: UUID?,
        context: ModelContext
    ) {
        let snapshot = ensure(profileID: profileID, context: context)
        snapshot.updatedAt = Date()
        snapshot.sourceGarmentCount = taste.sourceGarmentCount
        snapshot.formalityMean = taste.formalityMean
        snapshot.warmthMean = taste.warmthMean
        snapshot.formalitySpread = taste.formalitySpread

        let colors = taste.colorShares(limit: 8)
        snapshot.topColorRawValues = colors.map(\.tag.rawValue)
        snapshot.topColorShares = colors.map(\.share)

        let brands = taste.brandShares(limit: 8)
        snapshot.topBrandKeys = brands.map(\.key)
        snapshot.topBrandShares = brands.map(\.share)

        let styles = taste.styleShares(limit: 8)
        snapshot.topStyleRawValues = styles.map(\.tag.rawValue)
        snapshot.topStyleShares = styles.map(\.share)

        let categories = taste.categoryShares(limit: 8)
        snapshot.topCategoryRawValues = categories.map(\.tag.rawValue)
        snapshot.topCategoryShares = categories.map(\.share)

        let materials = taste.materialShares(limit: 8)
        snapshot.topMaterialRawValues = materials.map(\.tag.rawValue)
        snapshot.topMaterialShares = materials.map(\.share)

        let fits = taste.fitShares(limit: 5)
        snapshot.topFitRawValues = fits.map(\.tag.rawValue)
        snapshot.topFitShares = fits.map(\.share)

        let avoidColors = taste.avoidColorShares(limit: 5)
        snapshot.avoidColorRawValues = avoidColors.map(\.tag.rawValue)
        snapshot.avoidColorShares = avoidColors.map(\.share)

        let avoidBrands = taste.avoidBrandShares(limit: 5)
        snapshot.avoidBrandKeys = avoidBrands.map(\.key)
        snapshot.avoidBrandShares = avoidBrands.map(\.share)

        try? context.save()
    }
}
