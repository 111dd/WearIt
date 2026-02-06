import Foundation
import SwiftData

enum WearEventSource: String, Codable {
    case planner
    case manual
    case calendar
    case calendarBlock
}

@Model
final class WearEvent {
    var id: UUID = Foundation.UUID()
    var date: Date = Foundation.Date()
    var garmentIDs: [UUID] = []
    /// Legacy (migration-only): garment IDs as strings
    var garmentIDStrings: [String] = []
    var sourceRaw: String = WearEventSource.manual.rawValue
    var slotRaw: String?
    var outfitID: UUID?
    var notes: String?

    init(
        date: Date,
        garmentIDs: [UUID],
        source: WearEventSource,
        slot: OutfitSlot? = nil,
        outfitID: UUID? = nil,
        notes: String? = nil,
        id: UUID? = nil
    ) {
        self.id = id ?? Foundation.UUID()
        self.date = Calendar.current.startOfDay(for: date)
        self.garmentIDs = garmentIDs
        self.sourceRaw = source.rawValue
        self.slotRaw = slot?.rawValue
        self.outfitID = outfitID
        self.notes = notes
    }

    init() {
        self.id = Foundation.UUID()
        self.date = Foundation.Date()
        self.garmentIDs = []
        self.sourceRaw = WearEventSource.manual.rawValue
        self.slotRaw = nil
        self.outfitID = nil
        self.notes = nil
    }

    @Transient
    var source: WearEventSource {
        WearEventSource(rawValue: sourceRaw) ?? .manual
    }

    @Transient
    var slot: OutfitSlot? {
        guard let slotRaw else { return nil }
        return OutfitSlot(rawValue: slotRaw)
    }
}
