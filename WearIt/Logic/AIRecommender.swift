import Foundation
import SwiftData
import CoreGraphics

//
//  AIRecommender.swift
//  WearIt
//
//  Improved for MVP stability:
//  - No randomness by default (epsilon = 0)
//  - Uses rain/temperature context features
//  - Stable ranking (no shuffling)
//  - Per-item learning with negative sampling
//  - Cold-start heuristics

// MARK: - SwiftData Model State

@Model final class RecoState {
    var id: String = "global"
    var version: Int = 1
    var weights: [Double] = []
    var bias: Double = 0.0
    var epsilon: Double = 0.0      // exploration rate (0 = stable, 0.1 = some exploration)
    var lr: Double = 0.08          // learning rate
    
    /// Track how many times user has given feedback. Optional for migration compatibility.
    var totalInteractions: Int?

    init(size: Int) {
        self.weights = Array(repeating: 0.0, count: size)
        self.bias = 0.0
        self.epsilon = 0.0   // MVP: No randomness by default
        self.lr = 0.08
        self.totalInteractions = 0
    }
    
    /// Safe accessor that defaults to 0 if nil (for migrated records)
    var interactionCount: Int {
        get { totalInteractions ?? 0 }
        set { totalInteractions = newValue }
    }
}

// MARK: - Feature Space

enum FeatureSpace {
    // Categories (one-hot encoded)
    static let categories: [Category] = Category.allCases
    static let catCount = categories.count

    // Feature indices
    static let iCatStart = 0
    static let iCatEnd   = iCatStart + catCount

    // Core features
    static let iWarmthMatch   = iCatEnd          // how well warmth matches temperature
    static let iFormalMatch   = iWarmthMatch + 1 // how well formality matches desired
    static let iLove          = iFormalMatch + 1 // love score 0..1
    static let iRecency       = iLove + 1        // days since worn (normalized)
    
    // Context features (NEW)
    static let iIsRaining     = iRecency + 1     // 1 if raining, 0 otherwise
    static let iTempCold      = iIsRaining + 1   // 1 if temp < 10°C
    static let iTempMild      = iTempCold + 1    // 1 if 10-20°C
    static let iTempWarm      = iTempMild + 1    // 1 if 20-28°C
    static let iTempHot       = iTempWarm + 1    // 1 if > 28°C
    
    // Category-context interactions (NEW)
    static let iOuterInCold   = iTempHot + 1     // outer + cold weather
    static let iShoesInRain   = iOuterInCold + 1 // shoes + rain
    
    // Cold-start helpers
    static let iNeverWorn     = iShoesInRain + 1 // never been worn (boost new items)
    static let iFavorite      = iNeverWorn + 1   // is favorite
    
    static let total          = iFavorite + 1
}

// MARK: - Recommendation Context

struct RecoContext {
    let desiredFormality: Int
    let temperatureC: Double
    let isRaining: Bool
    let now: Date
    
    // Temperature bucket helpers
    var isCold: Bool { temperatureC < 10 }
    var isMild: Bool { temperatureC >= 10 && temperatureC < 20 }
    var isWarm: Bool { temperatureC >= 20 && temperatureC < 28 }
    var isHot: Bool { temperatureC >= 28 }
}

// MARK: - AI Recommender

final class AIRecommender {
    static let shared = AIRecommender()
    private init() {}

    // MARK: - State Management

    func ensureState(context: ModelContext) -> RecoState {
        if let s = try? context.fetch(FetchDescriptor<RecoState>()).first {
            // Migrate if feature space changed
            if s.weights.count != FeatureSpace.total {
                s.weights = Array(repeating: 0.0, count: FeatureSpace.total)
            }
            // MVP: Keep epsilon at 0 for stability
            s.epsilon = 0.0
            return s
        }
        let st = RecoState(size: FeatureSpace.total)
        context.insert(st)
        try? context.save()
        return st
    }

    // MARK: - Feature Extraction

    func features(for g: Garment, ctx: RecoContext) -> [Double] {
        var x = Array(repeating: 0.0, count: FeatureSpace.total)

        // 1) One-hot category
        if let idx = FeatureSpace.categories.firstIndex(of: g.category) {
            x[FeatureSpace.iCatStart + idx] = 1.0
        }

        // 2) Warmth match (based on temperature)
        let targetWarmth: Int
        switch ctx.temperatureC {
        case ..<8:   targetWarmth = 5
        case ..<14:  targetWarmth = 4
        case ..<20:  targetWarmth = 3
        case ..<26:  targetWarmth = 2
        default:     targetWarmth = 1
        }
        let warmthDelta = abs(Double(g.warmth - targetWarmth))
        x[FeatureSpace.iWarmthMatch] = max(0, 1.0 - warmthDelta / 4.0)

        // Fit comfort adjustments (light penalty in cold/hot extremes)
        if let fit = g.fitTag {
            if ctx.isCold, fit == .skinny {
                x[FeatureSpace.iWarmthMatch] -= 0.12
            } else if ctx.isCold, fit == .slim {
                x[FeatureSpace.iWarmthMatch] -= 0.06
            } else if ctx.isHot, fit == .oversized {
                x[FeatureSpace.iWarmthMatch] -= 0.06
            }
        }

        // 3) Formality match
        let formalDelta = abs(Double(g.formality - ctx.desiredFormality))
        x[FeatureSpace.iFormalMatch] = max(0, 1.0 - formalDelta / 4.0)

        // 4) Love score
        x[FeatureSpace.iLove] = Double(g.loveScore) / 100.0

        // 5) Recency (prefer items not worn recently)
        let days: Double
        if let last = g.lastWorn {
            days = max(0, ctx.now.timeIntervalSince(last) / 86400.0)
        } else {
            days = 30 // Never worn = high recency
        }
        x[FeatureSpace.iRecency] = min(1.0, days / 14.0)

        // 6) Context: Rain
        x[FeatureSpace.iIsRaining] = ctx.isRaining ? 1.0 : 0.0

        // 7) Context: Temperature buckets
        x[FeatureSpace.iTempCold] = ctx.isCold ? 1.0 : 0.0
        x[FeatureSpace.iTempMild] = ctx.isMild ? 1.0 : 0.0
        x[FeatureSpace.iTempWarm] = ctx.isWarm ? 1.0 : 0.0
        x[FeatureSpace.iTempHot]  = ctx.isHot ? 1.0 : 0.0

        // 8) Category-context interactions
        // Outer in cold weather
        if g.category == .outer && ctx.isCold {
            x[FeatureSpace.iOuterInCold] = 1.0
        }
        // Shoes in rain (penalize formal shoes)
        if g.category == .shoes && ctx.isRaining && g.formality >= 4 {
            x[FeatureSpace.iShoesInRain] = -1.0  // Negative = penalty
        }

        // 9) Cold-start helpers
        x[FeatureSpace.iNeverWorn] = (g.lastWorn == nil) ? 1.0 : 0.0
        x[FeatureSpace.iFavorite] = g.isFavorite ? 1.0 : 0.0
        
        // 10) Temperature suitability (using garment's temp range)
        let tempRange = g.effectiveTempRange
        if ctx.temperatureC >= tempRange.min && ctx.temperatureC <= tempRange.max {
            // Perfect temperature match - strong bonus
            x[FeatureSpace.iNeverWorn] += 0.3  // Reuse slot for bonus (temp hack)
        } else {
            // Calculate how far outside the range
            let distanceOutside: Double
            if ctx.temperatureC < tempRange.min {
                distanceOutside = tempRange.min - ctx.temperatureC
            } else {
                distanceOutside = ctx.temperatureC - tempRange.max
            }
            // Penalty based on distance (max penalty at 15°C outside range)
            let penalty = min(0.5, distanceOutside / 30.0)
            x[FeatureSpace.iWarmthMatch] -= penalty
        }

        return x
    }

    // MARK: - Scoring

    private func modelScore(w: [Double], b: Double, x: [Double]) -> Double {
        var s = b
        for i in 0..<min(w.count, x.count) {
            s += w[i] * x[i]
        }
        // Sigmoid to 0..1
        return 1.0 / (1.0 + exp(-s))
    }

    private func similarityBonus(for g: Garment, among garments: [Garment]) -> Double {
        // Only apply to new items (never worn or recently added)
        if g.lastWorn != nil { return 0 }
        if let created = g.createdAt, created < Date().addingTimeInterval(-14 * 86400) {
            return 0
        }

        let colors = Set(g.safeColorTags)
        let styles = Set(g.styleTags ?? [])
        var bestScore: Double = 0

        for other in garments where other.id != g.id {
            var sim: Double = 0

            if other.category == g.category { sim += 0.4 }
            if let itemType = g.itemType, itemType == other.itemType { sim += 0.25 }

            let otherColors = Set(other.safeColorTags)
            if !colors.isEmpty || !otherColors.isEmpty {
                let overlap = colors.intersection(otherColors).count
                let union = colors.union(otherColors).count
                if union > 0 {
                    sim += 0.2 * (Double(overlap) / Double(union))
                }
            }

            if let s1 = g.seasonSuitability, let s2 = other.seasonSuitability {
                if s1 == s2 || s1 == .allSeason || s2 == .allSeason {
                    sim += 0.1
                }
            }

            if !styles.isEmpty, let otherStyles = other.styleTags {
                let overlap = styles.intersection(otherStyles).count
                let union = styles.union(otherStyles).count
                if union > 0 {
                    sim += 0.05 * (Double(overlap) / Double(union))
                }
            }

            let love = Double(other.loveScore) / 100.0
            let preference = min(1.0, love + (other.isFavorite ? 0.3 : 0))
            let blended = sim * (0.5 + preference * 0.5)

            bestScore = max(bestScore, blended)
        }

        // Cap bonus to keep risk low
        return min(0.12, bestScore * 0.12)
    }

    /// Cold-start heuristic score (used when model has few interactions)
    private func heuristicScore(for g: Garment, ctx: RecoContext) -> Double {
        var score = 0.5
        
        // Temperature suitability (primary signal)
        let tempRange = g.effectiveTempRange
        if ctx.temperatureC >= tempRange.min && ctx.temperatureC <= tempRange.max {
            score += 0.25  // Strong bonus for being in range
        } else {
            let distanceOutside: Double
            if ctx.temperatureC < tempRange.min {
                distanceOutside = tempRange.min - ctx.temperatureC
            } else {
                distanceOutside = ctx.temperatureC - tempRange.max
            }
            // Penalty based on distance
            score -= min(0.3, distanceOutside / 20.0)
        }
        
        // Warmth match (secondary)
        let targetWarmth: Int
        switch ctx.temperatureC {
        case ..<8:   targetWarmth = 5
        case ..<14:  targetWarmth = 4
        case ..<20:  targetWarmth = 3
        case ..<26:  targetWarmth = 2
        default:     targetWarmth = 1
        }
        var warmthMatch = 1.0 - abs(Double(g.warmth - targetWarmth)) / 4.0
        if let fit = g.fitTag {
            if ctx.isCold, fit == .skinny { warmthMatch -= 0.12 }
            if ctx.isCold, fit == .slim { warmthMatch -= 0.06 }
            if ctx.isHot, fit == .oversized { warmthMatch -= 0.06 }
        }
        score += warmthMatch * 0.15
        
        // Formality match
        let formalMatch = 1.0 - abs(Double(g.formality - ctx.desiredFormality)) / 4.0
        score += formalMatch * 0.1
        
        // Love score boost
        score += (Double(g.loveScore) / 100.0) * 0.1
        
        // Recency boost (haven't worn in a while)
        if g.lastWorn == nil {
            score += 0.08
        } else if let last = g.lastWorn {
            let days = ctx.now.timeIntervalSince(last) / 86400.0
            score += min(0.08, days / 140.0)
        }
        
        // Favorite boost
        if g.isFavorite {
            score += 0.05
        }
        
        // Rain penalty for formal shoes
        if ctx.isRaining && g.category == .shoes && g.formality >= 4 {
            score -= 0.15
        }
        
        // Cold weather: boost outer
        if ctx.isCold && g.category == .outer {
            score += 0.1
        }
        
        // Hot weather: penalize outer
        if ctx.isHot && g.category == .outer {
            score -= 0.2
        }
        
        return max(0, min(1, score))
    }

    /// Combined score blending heuristics and learned model
    private func combinedScore(g: Garment, ctx: RecoContext, state: RecoState) -> Double {
        let x = features(for: g, ctx: ctx)
        let learned = modelScore(w: state.weights, b: state.bias, x: x)
        let heuristic = heuristicScore(for: g, ctx: ctx)
        
        // Blend based on interaction count
        // More interactions = trust learned model more
        let interactionWeight = min(1.0, Double(state.interactionCount) / 20.0)
        
        // Start with 80% heuristic, gradually shift to 80% learned
        let learnedWeight = 0.2 + (interactionWeight * 0.6)
        let heuristicWeight = 1.0 - learnedWeight
        
        return (learned * learnedWeight) + (heuristic * heuristicWeight)
    }

    // MARK: - Suggestion

    /// Suggest top K garments. Stable ranking, no random shuffling.
    /// - Parameters:
    ///   - garments: Pool of available garments
    ///   - k: Number of items to suggest
    ///   - ctx: Recommendation context (weather, formality, etc.)
    ///   - modelContext: SwiftData context
    ///   - excludedIDs: IDs to exclude (e.g., garments used in previous days)
    ///   - penalizedIDs: IDs to penalize but not exclude (reduce score by 30%)
    func suggest(
        from garments: [Garment],
        k: Int,
        ctx: RecoContext,
        modelContext: ModelContext,
        excludedIDs: Set<UUID> = [],
        penalizedIDs: Set<UUID> = []
    ) -> [Garment] {
        // Filter out blocked and excluded garments
        let pool = garments.filter { g in
            !g.isBlocked && !excludedIDs.contains(g.id)
        }
        guard !pool.isEmpty else { return [] }
        
        let state = ensureState(context: modelContext)

        // Score all garments
        var scored: [(Garment, Double)] = pool.map { g in
            var score = combinedScore(g: g, ctx: ctx, state: state)
            
            // Apply penalty for items used recently (in previous days)
            if penalizedIDs.contains(g.id) {
                score *= 0.7  // 30% penalty
            }

            // Similarity prior for new items (AI-ready without AI)
            score += similarityBonus(for: g, among: pool)
            
            return (g, score)
        }

        // Stable sort by score (descending) - NO shuffling for MVP stability
        scored.sort { $0.1 > $1.1 }

        // Add light diversity: avoid recommending 3+ of same category in top K
        var result: [Garment] = []
        var categoryCounts: [Category: Int] = [:]
        
        for (garment, _) in scored {
            let cat = garment.category
            let count = categoryCounts[cat, default: 0]
            
            // Allow max 2 of same category in suggestions
            if count < 2 {
                result.append(garment)
                categoryCounts[cat] = count + 1
            }
            
            if result.count >= k {
                break
            }
        }
        
        // If diversity rules limited us, fill with remaining top scores
        if result.count < k {
            for (garment, _) in scored {
                if !result.contains(where: { $0.id == garment.id }) {
                    result.append(garment)
                    if result.count >= k { break }
                }
            }
        }

        return result
    }
    
    /// Suggest a complete outfit with category diversity
    func suggestOutfit(
        from garments: [Garment],
        ctx: RecoContext,
        modelContext: ModelContext,
        excludedIDs: Set<UUID> = [],
        penalizedIDs: Set<UUID> = [],
        locked: Garment? = nil
    ) -> [Garment] {
        var result: [Garment] = []
        var usedCategories: Set<Category> = []
        var excludeSet = excludedIDs
        
        // If we have a locked garment, start with it
        if let locked = locked {
            result.append(locked)
            usedCategories.insert(locked.category)
            excludeSet.insert(locked.id)
        }
        
        // Define desired outfit composition
        let desiredCategories: [Category] = [.top, .bottom, .shoes, .outer, .accessory]
        
        for category in desiredCategories {
            // Skip if already covered by locked item
            guard !usedCategories.contains(category) else { continue }
            
            // For outer, only include in cold weather
            if category == .outer && ctx.temperatureC > 18 {
                continue
            }
            
            // Filter pool for this category
            let categoryPool = garments.filter { g in
                g.category == category && 
                !g.isBlocked && 
                !excludeSet.contains(g.id) &&
                !g.isCurrentlyUnavailable
            }
            
            guard !categoryPool.isEmpty else { continue }
            
            // Get top suggestion for this category
            let suggestions = suggest(
                from: categoryPool,
                k: 1,
                ctx: ctx,
                modelContext: modelContext,
                excludedIDs: excludeSet,
                penalizedIDs: penalizedIDs
            )
            
            if let item = suggestions.first {
                result.append(item)
                usedCategories.insert(category)
                excludeSet.insert(item.id)
            }
        }
        
        return result
    }

    // MARK: - Learning

    /// Learn from user feedback with per-item updates and negative sampling
    func learn(
        from selected: [Garment],
        shown: [Garment]? = nil,  // Other options that were shown but not selected
        ctx: RecoContext,
        reward: Double,
        modelContext: ModelContext
    ) {
        let state = ensureState(context: modelContext)
        var w = state.weights
        var b = state.bias
        let lr = state.lr

        // Per-item learning for selected items (reward)
        for g in selected {
            let x = features(for: g, ctx: ctx)
            let yhat = modelScore(w: w, b: b, x: x)
            let err = reward - yhat
            
            for i in 0..<min(w.count, x.count) {
                w[i] += lr * err * x[i]
            }
            b += lr * err
        }

        // Negative sampling: shown but not selected items get reward = 0
        if let shownItems = shown {
            let notSelected = shownItems.filter { item in
                !selected.contains(where: { $0.id == item.id })
            }
            
            // Sample up to 3 negative examples
            let negatives = Array(notSelected.prefix(3))
            for g in negatives {
                let x = features(for: g, ctx: ctx)
                let yhat = modelScore(w: w, b: b, x: x)
                let negReward = 0.3  // Slight negative signal (not 0, to avoid over-penalizing)
                let err = negReward - yhat
                
                // Smaller learning rate for negatives
                for i in 0..<min(w.count, x.count) {
                    w[i] += (lr * 0.5) * err * x[i]
                }
                b += (lr * 0.5) * err
            }
        }

        state.weights = w
        state.bias = b
        state.interactionCount += 1
        try? modelContext.save()
    }
    
    // MARK: - Settings
    
    /// Enable exploration (for advanced users who want variety)
    func setExploration(enabled: Bool, modelContext: ModelContext) {
        let state = ensureState(context: modelContext)
        state.epsilon = enabled ? 0.1 : 0.0
        try? modelContext.save()
    }
    
    /// Reset learned weights (start fresh)
    func resetLearning(modelContext: ModelContext) {
        let state = ensureState(context: modelContext)
        state.weights = Array(repeating: 0.0, count: FeatureSpace.total)
        state.bias = 0.0
        state.interactionCount = 0
        try? modelContext.save()
    }
}
