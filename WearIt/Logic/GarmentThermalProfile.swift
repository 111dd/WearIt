import Foundation

/// Relative comfort estimates, not measured clo values or a heat-safety model.
/// Derived on demand: existing wardrobes need no backfill or AI requests.
struct GarmentThermalProfile: Equatable {
    static let version = 1

    let insulation: Double             // 1...5; compatible with legacy warmth
    let breathability: Double          // 0...1; unknown starts neutral
    let coverage: Double               // relative coverage within a category
    let warmthIsUserAdjusted: Bool
    let breathabilityIsUserAdjusted: Bool

    init(
        warmth: Int,
        itemType: ItemType?,
        materials: [MaterialTag] = [],
        fit: FitTag? = nil,
        weatherTags: [WeatherSuitability] = [],
        estimatedFields: Set<String> = [],
        warmthOverride: Int? = nil,
        breathabilityOverride: Int? = nil
    ) {
        // Keep existing user warmth ratings authoritative. Correct inferred
        // rain-shell defaults only: water protection is not thermal insulation.
        var base = Double(min(5, max(1, warmth)))
        if estimatedFields.contains("warmth"), itemType == .raincoat {
            base = 2
        }
        insulation = Double(min(5, max(1, warmthOverride ?? Int(base))))
        warmthIsUserAdjusted = warmthOverride != nil
        breathabilityIsUserAdjusted = breathabilityOverride != nil

        switch itemType {
        case .tank, .shorts, .sandals: coverage = 0.35
        case .tshirt, .polo, .vest: coverage = 0.6
        case .coat, .parka, .raincoat: coverage = 1
        default: coverage = 0.85
        }

        var ventilation = 0.5
        // Material names alone do not establish weave, weight or permeability.
        // Use only modest priors, and never treat model-inferred fabric as fact.
        if !estimatedFields.contains("materialTags") {
            if materials.contains(.linen) { ventilation += 0.12 }
            if materials.contains(.fleece) || materials.contains(.leather) {
                ventilation -= 0.12
            }
        }
        if !estimatedFields.contains("weatherTags"), weatherTags.contains(.breathable) {
            ventilation += 0.2
        }
        if fit == .relaxed || fit == .oversized { ventilation += 0.08 }
        if fit == .skinny { ventilation -= 0.06 }
        ventilation += (1 - coverage) * 0.12
        if let override = breathabilityOverride {
            ventilation = Double(min(5, max(1, override)) - 1) / 4
        }
        breathability = min(1, max(0, ventilation))
    }

    /// No discontinuity at a temperature bucket boundary. Ventilation matters
    /// gradually more in heat; it never substitutes for insulation in the cold.
    func comfortScore(temperatureC: Double, targetWarmth: Double) -> Double {
        guard temperatureC.isFinite, targetWarmth.isFinite else { return 0.5 }
        let delta = insulation - targetWarmth
        let divisor = temperatureC >= 20 && delta > 0 ? 2.5 :
            (temperatureC < 12 && delta < 0 ? 3.0 : 4.0)
        let insulationScore = max(0, 1 - abs(delta) / divisor)
        let heat = min(1, max(0, (temperatureC - 22) / 10))
        let ventilationAdjustment = heat * (breathability - 0.5) * 0.4
        return min(1, max(0, insulationScore + ventilationAdjustment))
    }
}

/// A forecast snapshot, independent of WeatherKit, for deterministic scoring.
struct ThermalWeatherSample: Equatable {
    let date: Date
    let temperatureC: Double
    let apparentTemperatureC: Double?
    let rainProbability: Double

    var comfortTemperatureC: Double {
        // Apparent temperature already accounts for wind/humidity. Do not add
        // another wind-chill or humidity correction to it in the recommender.
        if let apparentTemperatureC, apparentTemperatureC.isFinite {
            return apparentTemperatureC
        }
        return temperatureC
    }
}
