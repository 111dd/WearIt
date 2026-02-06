import Foundation
import SwiftData

@Model
final class Outfit {
    var id: UUID = Foundation.UUID()
    var date: Date = Foundation.Date()
    var itemIDs: [UUID] = []
    /// Legacy (migration-only): stored garment IDs as strings
    var legacyItemIDStrings: [String] = []
    var rating: Int?
    var isFavorite: Bool = false
    var ownerID: UUID? = nil

    init(
        id: UUID? = nil,
        date: Date? = nil,
        itemIDs: [UUID] = [],
        legacyItemIDStrings: [String] = [],
        rating: Int? = nil,
        isFavorite: Bool = false,
        ownerID: UUID? = nil
    ) {
        self.id = id ?? Foundation.UUID()
        self.date = date ?? Foundation.Date()
        self.itemIDs = itemIDs
        self.legacyItemIDStrings = legacyItemIDStrings
        self.rating = rating
        self.isFavorite = isFavorite
        self.ownerID = ownerID
    }
}
