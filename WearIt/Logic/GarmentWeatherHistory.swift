import Foundation

/// Independent wear-days, not repeated taps. Overall love is never evidence of thermal comfort.
struct GarmentWeatherHistory: Sendable {
    struct Sample: Sendable {
        let temperature: Double
        let raining: Bool
        let comfort: Double
        let weight: Double
        let feedback: RecommendationFeedbackKind

        func supports(temperature query: Double) -> Bool {
            guard abs(temperature - query) <= 6 else { return false }
            switch feedback {
            case .tooWarm: return query >= temperature
            case .tooCold: return query <= temperature
            default: return true
            }
        }
    }
    var byGarment: [UUID: [Sample]] = [:]
    var byType: [ItemType: [Sample]] = [:]

    @MainActor
    init(events: [RecommendationEvent], garments: [Garment], profileID: UUID?) {
        let types = Dictionary(garments.compactMap { garment in garment.itemType.map { (garment.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let relevant = events.filter {
            ($0.profileID == nil || $0.profileID == profileID) && $0.temperatureC.isFinite
                && $0.kind.map { [RecommendationFeedbackKind.worn, .justRight, .tooCold, .tooWarm].contains($0) } == true
        }
        let groups = Dictionary(grouping: relevant) { event in
            // RecommendationEvent uses the DayPlan ID even when feedback arrives later.
            let day = event.dayPlanID?.uuidString ?? String(event.deduplicationKey.split(separator: "|").dropFirst().first ?? "")
            return day + "|" + event.lookTimeRaw
        }
        func isEarlier(_ lhs: RecommendationEvent, _ rhs: RecommendationEvent) -> Bool {
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        for key in groups.keys.sorted() {
            guard let events = groups[key] else { continue }
            let ids = Set(events.flatMap(\.selectedGarmentIDs))
            var typeSamples: [ItemType: (sample: Sample, event: RecommendationEvent)] = [:]
            for id in ids {
                let itemEvents = events.filter { $0.selectedGarmentIDs.contains(id) }
                // The latest explicit comfort response supersedes a wear confirmation.
                let explicit = itemEvents.filter { $0.kind != .worn }.max(by: isEarlier)
                guard let event = explicit ?? itemEvents.max(by: isEarlier), let feedback = event.kind else { continue }
                let sample = Sample(temperature: event.temperatureC, raining: event.wasRaining,
                    comfort: feedback == .tooCold || feedback == .tooWarm ? 0 : 1,
                    weight: feedback == .worn ? 0.4 : 1, feedback: feedback)
                byGarment[id, default: []].append(sample)
                if let type = types[id] {
                    // Several same-type pieces still contribute only one day/look sample.
                    // Prefer explicit feedback, then the latest event, independent of Set order.
                    if let existing = typeSamples[type] {
                        let existingExplicit = existing.sample.feedback != .worn
                        let isExplicit = feedback != .worn
                        let shouldReplace = existingExplicit == isExplicit
                            ? isEarlier(existing.event, event) : isExplicit
                        if shouldReplace { typeSamples[type] = (sample, event) }
                    } else {
                        typeSamples[type] = (sample, event)
                    }
                }
            }
            for (type, value) in typeSamples { byType[type, default: []].append(value.sample) }
        }
    }

    init() {}

    func estimate(for garment: Garment, temperature: Double, raining: Bool) -> (score: Double, confidence: Double)? {
        guard temperature.isFinite else { return nil }
        // A "too warm" response says nothing about a colder day, and vice versa.
        // Filter before choosing exact/type evidence so unsupported responses do not hide type history.
        let exact = (byGarment[garment.id] ?? []).filter { $0.supports(temperature: temperature) }
        let samples = exact.count >= 2 ? exact
            : (garment.itemType.flatMap { byType[$0] } ?? []).filter { $0.supports(temperature: temperature) }
        var total = 0.0, positive = 0.0
        for sample in samples {
            let distance = abs(sample.temperature - temperature)
            let weight = sample.weight * exp(-distance * distance / 18) * (sample.raining == raining ? 1 : 0.4)
            total += weight; positive += sample.comfort * weight
        }
        guard total > 0 else { return nil }
        // Several distinct days are needed; type evidence transfers more cautiously.
        let prior = exact.count >= 2 ? 2.0 : 4.0
        return (positive / total, min(0.8, total / (total + prior)))
    }
}
