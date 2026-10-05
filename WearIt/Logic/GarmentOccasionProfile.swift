import Foundation

/// The kinds of situation an item can be right for, as the user sees them.
enum GarmentOccasion: String, CaseIterable, Identifiable {
    case everyday
    case work
    case eveningOut
    case formal
    case sport
    case outdoor
    case home

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everyday: return String(localized: "fits_everyday")
        case .work: return String(localized: "fits_work")
        case .eveningOut: return String(localized: "fits_evening_out")
        case .formal: return String(localized: "fits_formal")
        case .sport: return String(localized: "fits_sport")
        case .outdoor: return String(localized: "fits_outdoor")
        case .home: return String(localized: "fits_home")
        }
    }

    var icon: String {
        switch self {
        case .everyday: return "sun.max"
        case .work: return "briefcase"
        case .eveningOut: return "wineglass"
        case .formal: return "sparkles"
        case .sport: return "figure.run"
        case .outdoor: return "leaf"
        case .home: return "house"
        }
    }

    /// The situation a calendar occasion asks for (nil when it asks for nothing special).
    init?(calendar occasion: CalendarOccasionKind) {
        switch occasion {
        case .work: self = .work
        case .socialEvening, .socialDay: self = .eveningOut
        case .formal, .blackTie, .shabbat, .holiday, .mourning: self = .formal
        case .sport: self = .sport
        case .outdoor, .travel: self = .outdoor
        case .none: return nil
        }
    }

    /// Calendar occasions whose tagged wear counts as evidence for this situation.
    var calendarOccasions: [CalendarOccasionKind] {
        switch self {
        case .everyday: return []
        case .work: return [.work]
        case .eveningOut: return [.socialEvening, .socialDay]
        case .formal: return [.formal, .blackTie, .shabbat, .holiday, .mourning]
        case .sport: return [.sport]
        case .outdoor: return [.outdoor, .travel]
        case .home: return []
        }
    }
}

/// How well each item fits each situation, 0...1: the user's own answer wins,
/// then what they actually wore it for, then what the item itself says
/// (formality, type, style, workout/work tags).
enum GarmentOccasionProfile {
    /// At or above this an item "fits" the situation.
    static let fitsThreshold = 0.6

    static func score(_ g: Garment, for occasion: GarmentOccasion, wornFor wearCount: Int = 0) -> Double {
        if g.occasionFits.contains(occasion) { return 1 }
        if g.occasionNotFits.contains(occasion) { return 0 }
        let derived = derivedScore(g, for: occasion)
        guard wearCount > 0 else { return derived }
        return max(derived, min(1, 0.45 + 0.15 * Double(wearCount)))
    }

    static func fits(_ g: Garment, _ occasion: GarmentOccasion, wornFor wearCount: Int = 0) -> Bool {
        score(g, for: occasion, wornFor: wearCount) >= fitsThreshold
    }

    /// Looks each garment was worn in, per situation, from tagged wear events.
    static func wearCounts(from events: [WearEvent]) -> [UUID: [GarmentOccasion: Int]] {
        var byOccasion: [CalendarOccasionKind: GarmentOccasion] = [:]
        for occasion in GarmentOccasion.allCases {
            for kind in occasion.calendarOccasions { byOccasion[kind] = occasion }
        }
        var result: [UUID: [GarmentOccasion: Int]] = [:]
        for event in events where event.source != .calendarBlock {
            guard let kind = event.occasion, let occasion = byOccasion[kind] else { continue }
            for id in Set(event.garmentIDs) {
                result[id, default: [:]][occasion, default: 0] += 1
            }
        }
        return result
    }

    // MARK: - Derived from the item

    static func derivedScore(_ g: Garment, for occasion: GarmentOccasion) -> Double {
        let styles = Set(g.styleTags ?? [])
        let tags = Set(g.occasionTags ?? [])
        let formality = g.formality
        let type = g.itemType
        let lounge: Set<ItemType> = [.sweatpants, .joggers, .hoodie, .slippers, .leggings]
        let isLounge = type.map { lounge.contains($0) } ?? false
        let dressy: Set<ItemType> = [.blazer, .oxfords, .heels, .loafers, .tie, .shirt, .blouse, .trousers, .coat, .watch, .jewelry]
        let isDressy = type.map { dressy.contains($0) } ?? false
        let accessory = g.category == .accessory

        switch occasion {
        case .formal:
            if g.isActivewear || isLounge { return 0.05 }
            if styles.contains(.formal) { return 0.95 }
            var score = [0.05, 0.15, 0.4, 0.75, 0.95][clamped(formality)]
            if isDressy { score = max(score, 0.65) }
            if styles.contains(.sporty) || styles.contains(.streetwear) { score *= 0.5 }
            return accessory ? max(score, 0.5) : score
        case .work:
            if tags.contains(.work) { return 1 }
            if g.isActivewear || isLounge || type == .shorts || type == .tank || type == .sandals { return 0.15 }
            if styles.contains(.business) || styles.contains(.smart_casual) { return 0.85 }
            return [0.15, 0.5, 0.75, 0.9, 0.65][clamped(formality)]
        case .eveningOut:
            if tags.contains(.dateNight) || tags.contains(.party) { return 1 }
            if g.isActivewear || isLounge { return 0.1 }
            return [0.3, 0.6, 0.8, 0.8, 0.6][clamped(formality)]
        case .everyday:
            if styles.contains(.casual) || styles.contains(.streetwear) { return 0.9 }
            if g.isActivewear { return 0.6 }
            return [0.85, 0.9, 0.75, 0.45, 0.15][clamped(formality)]
        case .sport:
            if tags.contains(.gym) || g.isActivewear { return 1 }
            if type == .sneakers || type == .shorts || type == .tshirt || type == .cap { return 0.45 }
            return 0.05
        case .outdoor:
            if tags.contains(.travel) || tags.contains(.beach) { return 0.9 }
            let weather = Set(g.weatherTags ?? [])
            if !weather.intersection([.waterproof, .rainFriendly, .windproof]).isEmpty { return 0.85 }
            let gear: Set<ItemType> = [.boots, .sneakers, .parka, .windbreaker, .raincoat, .shorts, .hat, .cap, .sunglasses, .sandals]
            if let type, gear.contains(type) { return 0.8 }
            if formality >= 4 { return 0.2 }
            return 0.5
        case .home:
            if tags.contains(.home) { return 1 }
            if isLounge || type == .tshirt || type == .sweatpants { return 0.9 }
            if formality >= 4 { return 0.1 }
            return formality <= 2 ? 0.6 : 0.35
        }
    }

    private static func clamped(_ formality: Int) -> Int {
        min(4, max(0, formality - 1))
    }
}

extension Garment {
    /// Situations the user said this item is right for.
    var occasionFits: Set<GarmentOccasion> {
        Set((occasionFitsRaw ?? []).compactMap(GarmentOccasion.init(rawValue:)))
    }

    /// Situations the user said this item is not for.
    var occasionNotFits: Set<GarmentOccasion> {
        Set((occasionNotFitsRaw ?? []).compactMap(GarmentOccasion.init(rawValue:)))
    }

    /// Records the user's answer (nil = back to automatic). Work and sport also
    /// update the work / gym tags that reminders and work days read.
    func setOccasionAnswer(_ fits: Bool?, for occasion: GarmentOccasion) {
        var yes = occasionFits
        var no = occasionNotFits
        yes.remove(occasion)
        no.remove(occasion)
        if fits == true { yes.insert(occasion) }
        if fits == false { no.insert(occasion) }
        occasionFitsRaw = yes.isEmpty ? nil : yes.map(\.rawValue).sorted()
        occasionNotFitsRaw = no.isEmpty ? nil : no.map(\.rawValue).sorted()

        let tag: OccasionTag?
        switch occasion {
        case .work: tag = .work
        case .sport: tag = .gym
        default: tag = nil
        }
        if let tag {
            var tags = occasionTags ?? []
            tags.removeAll { $0 == tag }
            if fits == true { tags.append(tag) }
            occasionTags = tags.isEmpty ? nil : tags
            markUserEdited(ItemTypeDefaults.FieldKey.occasionTags)
        }
    }
}
