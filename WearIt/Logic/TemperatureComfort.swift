//
//  TemperatureComfort.swift
//  WearIt
//
//  Shared temperature → outfit comfort helpers.
//  Used by recommendation scoring, outer-layer policy, and planner UI.
//

import Foundation

/// Optional morning→evening temps for a planning day.
struct DiurnalTemps: Equatable, Sendable {
    let morning: Double
    let afternoon: Double
    let evening: Double
    let low: Double
    let high: Double

    var range: Double { high - low }

    /// Cool start that warms up meaningfully (classic layering day).
    var isCoolMorningWarmAfternoon: Bool {
        morning < RecoContext.outerLayerTempThresholdC
            && afternoon >= 22
            && (afternoon - morning) >= 6
    }

    init(morning: Double, afternoon: Double, evening: Double, low: Double, high: Double) {
        self.morning = morning
        self.afternoon = afternoon
        self.evening = evening
        self.low = low
        self.high = high
    }

    init(profile: DayTemperatureProfile) {
        self.init(
            morning: profile.morningTemp,
            afternoon: profile.afternoonTemp,
            evening: profile.eveningTemp,
            low: profile.lowTemp,
            high: profile.highTemp
        )
    }
}

/// How aggressively to include outerwear for the current context.
enum OuterLayerPolicy: Equatable, Sendable {
    /// No outer layer (warm/hot and dry).
    case suppress
    /// Only light layers: jackets up to warmth 3, never a winter coat.
    case lightOnly
    /// Outer layer is appropriate; prefer one when cool/cold.
    case prefer
}

enum TemperatureComfort {
    /// Keep every relevant hour in the score instead of hiding hot/cold hours
    /// behind a daily mean. Missing hourly data uses the existing context.
    static func garmentScore(_ garment: Garment, context: RecoContext, warmthOffset: Double = 0) -> Double {
        let profile = garment.thermalProfile
        let hourly = context.thermalSamples.map(\.comfortTemperatureC).filter(\.isFinite)
        let temperatures = hourly.isEmpty ? [context.temperatureC] : hourly
        let scores = temperatures.map { temperature in
            profile.comfortScore(
                temperatureC: temperature,
                targetWarmth: targetWarmth(temperatureC: temperature, warmthTaste: context.warmthTaste, offset: warmthOffset)
            )
        }
        let mean = scores.reduce(0, +) / Double(scores.count)
        return mean * 0.75 + (scores.min() ?? mean) * 0.25
    }

    /// Continuous target warmth (1…5) for a given air temperature.
    static func targetWarmth(
        temperatureC: Double,
        warmthTaste: Double = 0,
        offset: Double = 0
    ) -> Double {
        let base: Double
        switch temperatureC {
        case ...0:   base = 5.0
        case ...8:   base = 5.0 - (temperatureC / 8.0) * 0.7          // 5 → 4.3
        case ...14:  base = 4.3 - ((temperatureC - 8) / 6.0) * 1.0     // 4.3 → 3.3
        case ...20:  base = 3.3 - ((temperatureC - 14) / 6.0) * 1.0     // 3.3 → 2.3
        case ...26:  base = 2.3 - ((temperatureC - 20) / 6.0) * 0.8     // 2.3 → 1.5
        case ...32:  base = 1.5 - ((temperatureC - 26) / 6.0) * 0.5     // 1.5 → 1.0
        default:     base = 1.0
        }
        return min(max(base + warmthTaste * 0.5 + offset, 1), 5)
    }

    /// How well a garment's warmth matches the target.
    /// Overheating in warm weather is penalized more than being slightly cool.
    static func warmthMatch(
        garmentWarmth: Int,
        target: Double,
        temperatureC: Double
    ) -> Double {
        let delta = Double(garmentWarmth) - target
        if temperatureC >= 20, delta > 0 {
            // Too warm for the weather — steep penalty.
            return max(0, 1.0 - delta / 2.5)
        }
        if temperatureC < 12, delta < 0 {
            // Too light for cold — steeper penalty.
            return max(0, 1.0 - abs(delta) / 3.0)
        }
        return max(0, 1.0 - abs(delta) / 4.0)
    }

    /// Soft score for garment temp-range suitability (0…1).
    static func tempRangeScore(
        temperatureC: Double,
        range: (min: Double, max: Double)
    ) -> Double {
        if temperatureC >= range.min && temperatureC <= range.max {
            // Prefer the middle of the garment's comfort band.
            let mid = (range.min + range.max) / 2
            let halfWidth = max(1, (range.max - range.min) / 2)
            let centered = 1.0 - min(1.0, abs(temperatureC - mid) / halfWidth) * 0.25
            return centered
        }
        let distance: Double
        if temperatureC < range.min {
            distance = range.min - temperatureC
        } else {
            distance = temperatureC - range.max
        }
        return max(0, 1.0 - distance / 18.0)
    }

    /// Soft season match when the garment has an explicit season tag.
    static func seasonMatch(season: SeasonSuitability?, temperatureC: Double) -> Double {
        guard let season else { return 0 }
        let range = season.defaultTempRange
        if temperatureC >= range.min && temperatureC <= range.max {
            return 1.0
        }
        let distance: Double
        if temperatureC < range.min {
            distance = range.min - temperatureC
        } else {
            distance = temperatureC - range.max
        }
        return max(0, 1.0 - distance / 15.0)
    }

    /// Decide outer-layer policy from primary temp + optional diurnal profile.
    static func outerLayerPolicy(
        temperatureC: Double,
        isRaining: Bool,
        lookTime: LookTime,
        diurnal: DiurnalTemps?
    ) -> OuterLayerPolicy {
        if isRaining {
            // Rain jacket: light when warm, fuller when cool.
            return temperatureC < RecoContext.outerLayerTempThresholdC ? .prefer : .lightOnly
        }

        if temperatureC >= 26 {
            return .suppress
        }

        if temperatureC >= RecoContext.outerLayerTempThresholdC {
            // Warm primary temp — allow a packable layer only on cool→warm swing days.
            if lookTime == .day, let diurnal, diurnal.isCoolMorningWarmAfternoon {
                return .lightOnly
            }
            if lookTime == .evening, let diurnal, diurnal.evening < RecoContext.outerLayerTempThresholdC {
                return .prefer
            }
            return .suppress
        }

        // Below 20°C
        if temperatureC < 12 {
            return .prefer
        }

        // Mild: prefer a layer when the day still swings warm, else light optional.
        if let diurnal, diurnal.range >= 8, diurnal.high >= 22 {
            return .lightOnly
        }
        return temperatureC < 16 ? .prefer : .lightOnly
    }

    /// Whether a specific outer garment fits the policy.
    static func outerGarmentAllowed(_ garment: Garment, policy: OuterLayerPolicy) -> Bool {
        switch policy {
        case .suppress:
            return false
        case .lightOnly:
            return isLightLayer(garment)
        case .prefer:
            return true
        }
    }

    /// Heavy coats never count as a light layer, whatever their rating.
    private static let heavyOuterTypes: Set<ItemType> = [.coat, .parka, .puffer]
    /// Jackets, denim jackets, overshirts and blazers are rated 2–3: all light enough
    /// to carry or wear over a tee on a mild day.
    static let lightLayerMaxWarmth = 3

    /// A jacket you'd throw over short sleeves (not a winter coat).
    static func isLightLayer(_ garment: Garment) -> Bool {
        guard garment.category == .outer, garment.recommendationWarmth <= lightLayerMaxWarmth else { return false }
        return garment.itemType.map { !heavyOuterTypes.contains($0) } ?? true
    }
}
