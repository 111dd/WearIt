import Foundation

/// What the user actually wears for each kind of calendar occasion, learned
/// from confirmed wear events that `OccasionMemory` tagged with their occasion.
/// After a few looks for an occasion this habit gradually outweighs the
/// built-in rules ("for work you wear chinos and a shirt, not a blazer").
struct OccasionStyleProfile: Equatable {
    struct Style: Equatable {
        /// Distinct looks (wear days) for this occasion.
        var looks = 0
        /// Looks each garment was part of.
        var garmentLooks: [UUID: Int] = [:]
        /// Per category, the share of worn pieces of each item type.
        var itemTypeShare: [Category: [ItemType: Double]] = [:]
        /// Share of looks that included a piece with this style.
        var styleShare: [StyleTag: Double] = [:]
        var meanFormality = 3.0
    }

    var byOccasion: [CalendarOccasionKind: Style] = [:]

    static let empty = OccasionStyleProfile()

    /// Below this many looks the rules decide alone.
    static let minimumLooks = 3
    /// At this many looks the habit has full weight.
    static let fullConfidenceLooks = 8

    /// Occasions worth learning: a plain day is already covered by general taste.
    static func learns(_ occasion: CalendarOccasionKind) -> Bool {
        occasion != .none
    }

    static func build(events: [WearEvent], garments: [Garment]) -> OccasionStyleProfile {
        let byID = Dictionary(garments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // One look per occasion, day and day/evening source.
        struct LookKey: Hashable { let occasion: CalendarOccasionKind; let day: Date; let evening: Bool }
        var looks: [LookKey: Set<UUID>] = [:]
        for event in events where event.source != .calendarBlock {
            guard let occasion = event.occasion, learns(occasion) else { continue }
            let key = LookKey(
                occasion: occasion,
                day: Calendar.current.startOfDay(for: event.date),
                evening: event.source == .plannerEvening
            )
            looks[key, default: []].formUnion(event.garmentIDs)
        }

        var result = OccasionStyleProfile()
        let grouped = Dictionary(grouping: looks, by: { $0.key.occasion })
        for (occasion, entries) in grouped {
            var style = Style()
            var typeCounts: [Category: [ItemType: Int]] = [:]
            var styleLooks: [StyleTag: Int] = [:]
            var formalityTotal = 0.0
            var formalityCount = 0
            for (_, ids) in entries {
                let pieces = ids.compactMap { byID[$0] }
                guard !pieces.isEmpty else { continue }
                style.looks += 1
                var stylesInLook = Set<StyleTag>()
                for garment in pieces {
                    style.garmentLooks[garment.id, default: 0] += 1
                    if let type = garment.itemType {
                        typeCounts[garment.category, default: [:]][type, default: 0] += 1
                    }
                    stylesInLook.formUnion(garment.styleTags ?? [])
                    if garment.category != .accessory {
                        formalityTotal += Double(garment.formality)
                        formalityCount += 1
                    }
                }
                for tag in stylesInLook { styleLooks[tag, default: 0] += 1 }
            }
            guard style.looks > 0 else { continue }
            for (category, counts) in typeCounts {
                let total = Double(counts.values.reduce(0, +))
                style.itemTypeShare[category] = counts.mapValues { Double($0) / total }
            }
            style.styleShare = styleLooks.mapValues { Double($0) / Double(style.looks) }
            if formalityCount > 0 { style.meanFormality = formalityTotal / Double(formalityCount) }
            result.byOccasion[occasion] = style
        }
        return result
    }

    /// 0 below `minimumLooks`, rising to 1 at `fullConfidenceLooks`.
    func confidence(for occasion: CalendarOccasionKind) -> Double {
        guard let looks = byOccasion[occasion]?.looks, looks >= Self.minimumLooks else { return 0 }
        let span = Double(Self.fullConfidenceLooks - Self.minimumLooks + 1)
        return min(1, Double(looks - Self.minimumLooks + 1) / span)
    }

    /// The formality the user actually dresses at for this occasion, once confident.
    func learnedFormality(for occasion: CalendarOccasionKind) -> (value: Double, confidence: Double)? {
        let confidence = confidence(for: occasion)
        guard confidence > 0, let style = byOccasion[occasion] else { return nil }
        return (style.meanFormality, confidence)
    }

    /// How well a garment matches the user's habit for the occasion, 0...1.
    /// Pieces worn for it before count most; then the same kind of item, the
    /// same style and a similar formality.
    func habitMatch(_ garment: Garment, occasion: CalendarOccasionKind) -> Double {
        guard let style = byOccasion[occasion], style.looks > 0 else { return 0 }
        let worn = min(1, 2 * Double(style.garmentLooks[garment.id] ?? 0) / Double(style.looks))
        let type = garment.itemType.flatMap { style.itemTypeShare[garment.category]?[$0] } ?? 0
        let styleMatch = (garment.styleTags ?? []).map { style.styleShare[$0] ?? 0 }.max() ?? 0
        let formality = garment.category == .accessory
            ? 0.5
            : max(0, 1 - abs(Double(garment.formality) - style.meanFormality) / 2)
        return 0.4 * worn + 0.25 * type + 0.15 * styleMatch + 0.2 * formality
    }

    /// Score nudge for the recommender, about -0.06...+0.12 at full confidence.
    func fit(_ garment: Garment, occasion: CalendarOccasionKind) -> Double {
        let confidence = confidence(for: occasion)
        guard confidence > 0 else { return 0 }
        return confidence * 0.18 * (habitMatch(garment, occasion: occasion) - 0.35)
    }

    /// True when most of a look follows the habit, for "Why this look?".
    func lookFollowsHabit(_ garments: [Garment], occasion: CalendarOccasionKind) -> Bool {
        guard confidence(for: occasion) > 0 else { return false }
        let pieces = garments.filter { $0.category != .accessory }
        guard !pieces.isEmpty else { return false }
        let matching = pieces.filter { habitMatch($0, occasion: occasion) >= 0.5 }.count
        return matching * 2 >= pieces.count
    }
}
