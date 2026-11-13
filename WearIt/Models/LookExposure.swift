import Foundation

/// Value snapshot only. Creating this value does not record a display.
struct LookExposure: Codable, Sendable, Equatable, Identifiable {
    enum Origin: String, Codable, Sendable {
        case generated, refreshed, slotSwap, manual, restored, unknown
    }
    enum Surface: String, Codable, Sendable { case planner, calendar }
    enum Evidence: String, Codable, Sendable {
        case visibleDwell
        /// An action before the dwell threshold is evidence of interaction, not timed visibility.
        case explicitInteraction
    }

    let id: UUID
    private(set) var firstShownAt: Date
    private(set) var observedDay: String
    let timeZoneIdentifier: String
    let profileID: UUID
    let dayPlanID: UUID?
    let plannedDay: String
    let lookTime: String
    let slots: [String: UUID]
    var origin: Origin
    let surface: Surface
    private(set) var evidence: Evidence
    let temperatureC: Double?
    let wasRaining: Bool?
    let desiredFormality: Int?
    let modelVersion: Int

    init(profileID: UUID, dayPlanID: UUID?, plannedDate: Date, lookTime: String,
         slots: [String: UUID], origin: Origin, surface: Surface,
         evidence: Evidence = .visibleDwell, temperatureC: Double? = nil,
         wasRaining: Bool? = nil, desiredFormality: Int? = nil,
         modelVersion: Int, shownAt: Date = Date(), timeZone: TimeZone = .current) {
        id = UUID()
        firstShownAt = shownAt
        observedDay = Self.dayKey(shownAt, timeZone: timeZone)
        timeZoneIdentifier = timeZone.identifier
        self.profileID = profileID
        self.dayPlanID = dayPlanID
        plannedDay = Self.dayKey(plannedDate, timeZone: timeZone)
        self.lookTime = lookTime
        self.slots = slots
        self.origin = origin
        self.surface = surface
        self.evidence = evidence
        self.temperatureC = temperatureC.flatMap { $0.isFinite ? $0 : nil }
        self.wasRaining = wasRaining
        self.desiredFormality = desiredFormality
        self.modelVersion = modelVersion
    }

    /// Stable across redraws; context changes invalidate a pending dwell without recording a display.
    var observationIdentity: String {
        "\(provenanceKey)|\(dayPlanID?.uuidString ?? "")|\(surface.rawValue)|\(temperatureC.map { String($0) } ?? "")|\(wasRaining.map { String($0) } ?? "")|\(desiredFormality ?? 0)|\(modelVersion)"
    }

    var provenanceKey: String {
        "\(profileID.uuidString)|\(plannedDay)|\(lookTime)|\(assignmentKey)"
    }

    func observed(at date: Date, evidence: Evidence = .visibleDwell) -> Self {
        var copy = self
        copy.firstShownAt = date
        copy.observedDay = Self.dayKey(date, timeZone: TimeZone(identifier: timeZoneIdentifier) ?? .current)
        copy.evidence = evidence
        return copy
    }

    /// Includes accessories and slot identities; never use the core key for display deduplication.
    var assignmentKey: String { Self.key(slots) }

    /// Outerwear is tracked as an item, not allowed to disguise a repeated core outfit.
    var coreLookKey: String {
        let names: Set<String> = slots["onePiece"] == nil
            ? ["top", "bottom", "shoes"] : ["onePiece", "shoes"]
        return Self.key(slots.filter { names.contains($0.key) })
    }

    var clothingPairKey: String? {
        guard let top = slots["top"], let bottom = slots["bottom"], slots["onePiece"] == nil else { return nil }
        return "top=\(top.uuidString)|bottom=\(bottom.uuidString)"
    }

    /// Separate surfaces/evidence remain inspectable; repeated appearances on the same day do not multiply rows.
    var deduplicationKey: String {
        "\(decisionKey)|\(surface.rawValue)|\(evidence.rawValue)"
    }

    /// Used for cross-surface summaries; observation day and planned day have different meanings.
    var decisionKey: String {
        "\(profileID.uuidString)|\(observedDay)|\(timeZoneIdentifier)|\(plannedDay)|\(lookTime)|\(assignmentKey)"
    }

    private static func key(_ slots: [String: UUID]) -> String {
        slots.keys.sorted().map { "\($0)=\(slots[$0]!.uuidString)" }.joined(separator: "|")
    }

    static func dayKey(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

enum ExposureSummary {
    struct Window: Sendable {
        let days: Int
        let decisionCount: Int
        let itemCounts: [UUID: Int]
        let pairCounts: [String: Int]
        let coreLookCounts: [String: Int]
        let manualDecisionCount: Int
        let unknownOriginCount: Int
        let isPartial: Bool
    }

    /// Display summaries exclude quick actions; wear history remains a separate input to rotation.
    /// Pass this profile's coverage start from Snapshot.trackingStartedAtByProfile, never the global start.
    static func build(records: [LookExposure], profileID: UUID, now: Date = Date(),
                      trackingStartedAt: Date?, historyTruncatedBefore: Date? = nil,
                      timeZone: TimeZone = .current) -> [Window] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return [3, 7, 14].map { days in
            let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) ?? now
            let eligible = records.filter {
                $0.profileID == profileID && $0.evidence == .visibleDwell &&
                $0.firstShownAt >= start && $0.firstShownAt <= now
            }.sorted {
                if $0.firstShownAt != $1.firstShownAt { return $0.firstShownAt < $1.firstShownAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            var seen = Set<String>()
            var items: [UUID: Int] = [:], pairs: [String: Int] = [:], looks: [String: Int] = [:]
            var manual = 0, unknown = 0
            for record in eligible where seen.insert(record.decisionKey).inserted {
                for id in Set(record.slots.values) { items[id, default: 0] += 1 }
                if let pair = record.clothingPairKey { pairs[pair, default: 0] += 1 }
                if !record.coreLookKey.isEmpty { looks[record.coreLookKey, default: 0] += 1 }
                if record.origin == .manual { manual += 1 }
                if record.origin == .unknown || record.origin == .restored { unknown += 1 }
            }
            let startedLate = trackingStartedAt.map { $0 > start } ?? true
            let truncated = historyTruncatedBefore.map { $0 >= start } ?? false
            return Window(days: days, decisionCount: seen.count, itemCounts: items,
                          pairCounts: pairs, coreLookCounts: looks, manualDecisionCount: manual,
                          unknownOriginCount: unknown,
                          isPartial: startedLate || truncated)
        }
    }
}
