import Foundation
import SwiftData

/// Soft pair affinities derived from wear history and dismissed outfits.
/// Positive: garments co-worn in the same WearEvent.
/// Negative: pairs that appear together in a dismissed outfit key.
struct CombinationAffinity: Equatable {
    /// Canonical pair key → score in roughly -1...1
    private(set) var pairScores: [String: Double]

    static let empty = CombinationAffinity(pairScores: [:])

    init(pairScores: [String: Double]) {
        self.pairScores = pairScores
    }

    static func pairKey(_ a: UUID, _ b: UUID) -> String {
        let left = a.uuidString.lowercased()
        let right = b.uuidString.lowercased()
        return left < right ? "\(left)|\(right)" : "\(right)|\(left)"
    }

    func score(between a: UUID, and b: UUID) -> Double {
        pairScores[Self.pairKey(a, b)] ?? 0
    }

    /// Average pair affinity of `candidate` against already selected garments.
    func affinity(of candidate: Garment, with selected: [Garment]) -> Double {
        guard !selected.isEmpty else { return 0 }
        let values = selected.map { score(between: candidate.id, and: $0.id) }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Top co-worn pairs for Stats (positive scores only).
    func topPositivePairs(limit: Int = 5) -> [(key: String, score: Double)] {
        pairScores
            .filter { $0.value > 0 }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(limit)
            .map { (key: $0.key, score: $0.value) }
    }

    static func parsePairKey(_ key: String) -> (UUID, UUID)? {
        let parts = key.split(separator: "|")
        guard parts.count == 2,
              let a = UUID(uuidString: String(parts[0])),
              let b = UUID(uuidString: String(parts[1])) else { return nil }
        return (a, b)
    }
}

enum CombinationAffinityBuilder {
    /// Builds affinities from wear events (+), dismissed outfits (−), and style rejections (−).
    static func build(
        wearEvents: [WearEvent],
        dismissed: [DismissedOutfit],
        rejectedEvents: [RecommendationEvent] = [],
        maxEvents: Int = 120
    ) -> CombinationAffinity {
        var raw: [String: Double] = [:]

        let relevantEvents = wearEvents
            .filter { $0.source != .calendarBlock && $0.source != .migration }
            .sorted { $0.date > $1.date }
            .prefix(maxEvents)

        for event in relevantEvents {
            let ids = Array(Set(event.garmentIDs))
            guard ids.count >= 2 else { continue }
            // Recency weight: newer wears count a bit more
            let daysAgo = max(0, Calendar.current.dateComponents([.day], from: event.date, to: Date()).day ?? 0)
            let recency = max(0.35, 1.0 - Double(daysAgo) / 180.0)
            addPairs(ids: ids, delta: 1.0 * recency, into: &raw)
        }

        for ban in dismissed {
            let ids = ban.key
                .split(separator: "|")
                .compactMap { UUID(uuidString: String($0)) }
            guard ids.count >= 2 else { continue }
            addPairs(ids: ids, delta: -1.2, into: &raw)
        }

        for event in rejectedEvents where event.kind == .notMyStyle {
            let ids = Array(Set(event.selectedGarmentIDs))
            guard ids.count >= 2 else { continue }
            addPairs(ids: ids, delta: -0.9, into: &raw)
        }

        // Soft-squash into -1...1
        var normalized: [String: Double] = [:]
        for (key, value) in raw {
            normalized[key] = tanh(value / 3.0)
        }
        return CombinationAffinity(pairScores: normalized)
    }

    private static func addPairs(ids: [UUID], delta: Double, into raw: inout [String: Double]) {
        for i in 0..<ids.count {
            for j in (i + 1)..<ids.count {
                let key = CombinationAffinity.pairKey(ids[i], ids[j])
                raw[key, default: 0] += delta
            }
        }
    }
}
