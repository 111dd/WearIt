import Foundation

/// Plain-language reasons a planned look fits the day, built from the same
/// signals the recommender uses (forecast, calendar occasion, favorites, wear
/// history, proven pairs). Deterministic and instant, so "Why this look?"
/// works in every language and on devices without Apple Intelligence; the
/// on-device model only adds a nicer summary where it is available.
enum LookReasonBuilder {

    enum Reason: Equatable {
        /// A layer for a cool evening, with the evening temperature.
        case eveningLayer(temp: Int)
        /// Shoes or outerwear that handle the expected rain.
        case rainReady
        /// Only light pieces on a hot day.
        case lightForHeat(temp: Int)
        /// A warm layer on a cold day.
        case warmForCold(temp: Int)
        /// The look matches a calendar occasion that changed the formality.
        case occasion(CalendarOccasionKind)
        /// Includes a garment the user marked as a favorite.
        case favorite(garmentID: UUID)
        /// Brings back a piece that has not been worn for a while.
        case rotation(garmentID: UUID, days: Int)
        /// Two pieces the user has worn together before.
        case provenPair
        /// The colors follow a classic rule (one accent, tone-on-tone, neighbors, opposites).
        case palette(LookDNA.Palette)
        /// Loose piece with a fitted one.
        case balancedProportions
        /// Built around the user's most-loved color.
        case favoriteColor(ColorTag)
        /// Neutral fallback: the temperature range it was planned for.
        case weatherRange(low: Int, high: Int)

        var garmentID: UUID? {
            switch self {
            case .favorite(let id), .rotation(let id, _): return id
            default: return nil
            }
        }
    }

    struct Input {
        var garments: [Garment]
        var profile: DayTemperatureProfile?
        var occasion: CalendarOccasionKind = .none
        var lastWorn: [UUID: Date] = [:]
        var combination: CombinationAffinity = .empty
        /// Colors that carry a real share of the user's taste (most-loved first).
        var favoriteColors: [ColorTag] = []
        var now = Date()
    }

    static let rotationDays = 14
    static let rainThreshold = 0.35
    static let hotThresholdC = 28.0
    static let coldThresholdC = 10.0

    static func reasons(_ input: Input, limit: Int = 3) -> [Reason] {
        let garments = input.garments
        guard !garments.isEmpty else { return [] }
        var result: [Reason] = []

        if let profile = input.profile {
            if profile.rainProbability >= rainThreshold, garments.contains(where: handlesRain) {
                result.append(.rainReady)
            }
            let hasOuter = garments.contains { $0.category == .outer }
            if profile.eveningJacketRecommended, hasOuter {
                result.append(.eveningLayer(temp: Int(profile.eveningTemp.rounded())))
            } else if profile.lowTemp <= coldThresholdC,
                      garments.contains(where: { $0.category == .outer && warmth($0) >= 4 }) {
                result.append(.warmForCold(temp: Int(profile.lowTemp.rounded())))
            }
            if profile.highTemp >= hotThresholdC,
               !hasOuter,
               garments.filter({ $0.category == .top }).allSatisfy({ warmth($0) <= 2 }) {
                result.append(.lightForHeat(temp: Int(profile.highTemp.rounded())))
            }
        }

        if occasionShapesLook(input.occasion) {
            result.append(.occasion(input.occasion))
        }

        if let favorite = garments.first(where: \.isFavorite) {
            result.append(.favorite(garmentID: favorite.id))
        }

        let calendar = Calendar.current
        let rested = garments.compactMap { garment -> (UUID, Int)? in
            guard let last = input.lastWorn[garment.id] else { return nil }
            let days = calendar.dateComponents([.day], from: last, to: input.now).day ?? 0
            return days >= rotationDays ? (garment.id, days) : nil
        }
        if let longest = rested.max(by: { $0.1 < $1.1 }) {
            result.append(.rotation(garmentID: longest.0, days: longest.1))
        }

        if hasProvenPair(garments, combination: input.combination) {
            result.append(.provenPair)
        }

        let dna = LookDNA(garments: garments)
        switch dna.scheme {
        case .neutralPlusPop, .tonal, .analogous:
            result.append(.palette(dna.scheme))
        case .complementary where dna.priorScore >= 0.6:
            result.append(.palette(dna.scheme))
        default:
            break
        }
        if dna.silhouette == .balanced {
            result.append(.balancedProportions)
        }

        if let color = input.favoriteColors.first(where: { color in
            garments.contains { $0.safeColorTags.first == color }
        }) {
            result.append(.favoriteColor(color))
        }

        if result.count < limit, let profile = input.profile {
            result.append(.weatherRange(
                low: Int(profile.lowTemp.rounded()),
                high: Int(profile.highTemp.rounded())
            ))
        }

        return Array(result.prefix(limit))
    }

    // MARK: - Helpers

    private static func warmth(_ garment: Garment) -> Int {
        garment.thermalWarmthOverride ?? garment.warmth
    }

    private static func handlesRain(_ garment: Garment) -> Bool {
        let tags = garment.weatherTags ?? []
        if tags.contains(.waterproof) || tags.contains(.rainFriendly) { return true }
        switch garment.itemType {
        case .boots, .raincoat, .parka: return true
        default: return false
        }
    }

    /// Occasions that actually change what the planner picks.
    private static func occasionShapesLook(_ occasion: CalendarOccasionKind) -> Bool {
        switch occasion {
        case .formal, .blackTie, .socialEvening, .work, .sport, .shabbat, .holiday: return true
        case .none, .travel, .outdoor: return false
        }
    }

    private static func hasProvenPair(_ garments: [Garment], combination: CombinationAffinity) -> Bool {
        for (index, first) in garments.enumerated() {
            for second in garments.dropFirst(index + 1)
            where combination.score(between: first.id, and: second.id) > 0 {
                return true
            }
        }
        return false
    }
}
