import Foundation
import SwiftData

enum RecommendationFeedbackKind: String, Codable, Sendable {
    case loved
    case notMyStyle
    case tooWarm
    case tooCold
    case justRight
    case tooFormal
    case tooCasual
    case worn
}

@Model
final class RecommendationEvent {
    var id: UUID = UUID()
    var deduplicationKey: String = ""
    var createdAt: Date = Date()
    var profileID: UUID?
    var dayPlanID: UUID?
    var kindRaw: String = RecommendationFeedbackKind.loved.rawValue
    var selectedGarmentIDs: [UUID] = []
    var shownGarmentIDs: [UUID] = []
    var temperatureC: Double = 20
    var wasRaining: Bool = false
    var desiredFormality: Int = 3
    var warmthSensitivity: Int = 3
    var rainTolerance: Int = 3
    var lookTimeRaw: String = LookTime.day.rawValue
    var modelVersion: Int = 2

    init(
        deduplicationKey: String,
        profileID: UUID?,
        dayPlanID: UUID?,
        kind: RecommendationFeedbackKind,
        selectedGarmentIDs: [UUID],
        shownGarmentIDs: [UUID],
        context: RecoContext
    ) {
        self.id = UUID()
        self.deduplicationKey = deduplicationKey
        self.createdAt = Date()
        self.profileID = profileID
        self.dayPlanID = dayPlanID
        self.kindRaw = kind.rawValue
        self.selectedGarmentIDs = selectedGarmentIDs
        self.shownGarmentIDs = shownGarmentIDs
        self.temperatureC = context.temperatureC
        self.wasRaining = context.isRaining
        self.desiredFormality = context.desiredFormality
        self.warmthSensitivity = context.warmthSensitivity
        self.rainTolerance = context.rainTolerance
        self.lookTimeRaw = context.lookTime.rawValue
        self.modelVersion = 2
    }

    @Transient
    var kind: RecommendationFeedbackKind? {
        RecommendationFeedbackKind(rawValue: kindRaw)
    }
}

@MainActor
enum RecommendationEventStore {
    @discardableResult
    static func record(
        kind: RecommendationFeedbackKind,
        selectedGarmentIDs: [UUID],
        shownGarmentIDs: [UUID],
        dayPlanID: UUID?,
        context: RecoContext,
        modelContext: ModelContext
    ) -> Bool {
        let selectedIDs = Array(Set(selectedGarmentIDs)).sorted { $0.uuidString < $1.uuidString }
        let shownIDs = Array(Set(shownGarmentIDs)).sorted { $0.uuidString < $1.uuidString }
        let key = deduplicationKey(
            kind: kind,
            selectedGarmentIDs: selectedIDs,
            dayPlanID: dayPlanID,
            date: context.now
        )

        let descriptor = FetchDescriptor<RecommendationEvent>(
            predicate: #Predicate { event in
                event.deduplicationKey == key
            }
        )
        if (try? modelContext.fetchCount(descriptor)) ?? 0 > 0 {
            return false
        }

        modelContext.insert(
            RecommendationEvent(
                deduplicationKey: key,
                profileID: context.profileID,
                dayPlanID: dayPlanID,
                kind: kind,
                selectedGarmentIDs: selectedIDs,
                shownGarmentIDs: shownIDs,
                context: context
            )
        )
        try? modelContext.save()
        return true
    }

    static func removeAll(profileID: UUID?, modelContext: ModelContext) {
        let events = (try? modelContext.fetch(FetchDescriptor<RecommendationEvent>())) ?? []
        for event in events where event.profileID == profileID {
            modelContext.delete(event)
        }
        try? modelContext.save()
    }

    private static func deduplicationKey(
        kind: RecommendationFeedbackKind,
        selectedGarmentIDs: [UUID],
        dayPlanID: UUID?,
        date: Date
    ) -> String {
        let planPart = dayPlanID?.uuidString ?? Self.dayFormatter.string(from: date)
        let garmentPart = selectedGarmentIDs.map(\.uuidString).joined(separator: ",")
        return "v2|\(planPart)|\(kind.rawValue)|\(garmentPart)"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
