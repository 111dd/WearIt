import Foundation
import SwiftData

@Model
final class DailyLook {
    var id: UUID = Foundation.UUID()
    var date: Date = Foundation.Date()
    var photoPaths: [String] = []
    var note: String?
    var ownerID: UUID? = nil

    init(
        id: UUID? = nil,
        date: Date? = nil,
        photoPaths: [String] = [],
        note: String? = nil,
        ownerID: UUID? = nil
    ) {
        self.id = id ?? Foundation.UUID()
        self.date = Calendar.current.startOfDay(for: date ?? Foundation.Date())
        self.photoPaths = photoPaths
        self.note = note
        self.ownerID = ownerID
    }
}
