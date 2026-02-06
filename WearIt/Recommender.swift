//
//  Recommender.swift
//  WearIt
//
//  Simple rule-based outfit recommender (fallback when AI has no data)

import Foundation

struct WeatherInput {
    var temperatureC: Double
    var isRaining: Bool
}

struct OutfitRecommender {
    
    /// Suggest a complete outfit based on weather and formality
    func suggest(
        from garments: [Garment],
        desiredFormality: Int,
        weather: WeatherInput,
        coldThreshold: Double = 16.0
    ) -> [Garment] {

        let tops     = garments.filter { $0.category == .top && !$0.isBlocked }
        let bottoms  = garments.filter { $0.category == .bottom && !$0.isBlocked }
        let shoes    = garments.filter { $0.category == .shoes && !$0.isBlocked }
        let outers   = garments.filter { $0.category == .outer && !$0.isBlocked }

        let desiredWarmth = warmthTarget(for: weather.temperatureC)

        func score(_ g: Garment) -> Double {
            // Formality match
            let formScore = 10.0 - Double(abs(g.formality - desiredFormality))
            
            // Warmth match
            let warmthScore = 10.0 - Double(abs(g.warmth - desiredWarmth))

            // Love boost (0..6)
            let loveBoost = Double(g.loveScore) / 100.0 * 6.0

            // Recency boost (encourage rotation)
            let daysSince = daysSinceLastWorn(g)
            let recencyBoost = min(Double(daysSince) / 3.0, 8.0)
            
            // Favorite boost
            let favBoost = g.isFavorite ? 2.0 : 0.0

            // Rain penalty for formal shoes
            let rainPenalty: Double
            if weather.isRaining && g.category == .shoes && g.formality >= 4 {
                rainPenalty = 4.0
            } else if weather.isRaining && g.category == .shoes {
                // Slight penalty for any shoes in rain
                rainPenalty = 1.0
            } else {
                rainPenalty = 0.0
            }
            
            // Warmth bonus for outer in cold
            let outerBonus: Double
            if g.category == .outer && weather.temperatureC < coldThreshold {
                outerBonus = 3.0
            } else {
                outerBonus = 0.0
            }

            return formScore + warmthScore + loveBoost + recencyBoost + favBoost + outerBonus - rainPenalty
        }

        func pickBest(_ arr: [Garment]) -> Garment? {
            arr.max(by: { score($0) < score($1) })
        }

        var chosen: [Garment] = []
        if let t = pickBest(tops)     { chosen.append(t) }
        if let b = pickBest(bottoms)  { chosen.append(b) }
        if let s = pickBest(shoes)    { chosen.append(s) }

        // Add outer layer in cold weather
        if weather.temperatureC <= coldThreshold, let o = pickBest(outers) {
            chosen.append(o)
        }
        
        return chosen
    }

    private func warmthTarget(for temp: Double) -> Int {
        switch temp {
        case ..<8:   return 5
        case ..<14:  return 4
        case ..<20:  return 3
        case ..<26:  return 2
        default:     return 1
        }
    }

    private func daysSinceLastWorn(_ g: Garment) -> Int {
        guard let d = g.lastWorn else { return 30 }
        return Calendar.current.dateComponents([.day], from: d, to: .now).day ?? 30
    }
}
