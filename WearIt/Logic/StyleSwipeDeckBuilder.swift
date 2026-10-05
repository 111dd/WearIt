import Foundation
import SwiftData

/// Builds Style Swipe decks: whole looks from the user's own wardrobe, chosen
/// so each swipe teaches the recommender as much as possible (active learning)
/// while staying fun and varied.
///  - candidates: the model's top looks, contrasting looks, and random combinations
///    from the whole closet (so new pieces and color schemes show up)
///  - every fourth card is a likely win; the rest favor new palettes and silhouettes,
///    looks unlike the ones already in the deck, and looks the model is unsure about
@MainActor
enum StyleSwipeDeckBuilder {
    struct Card: Identifiable, Equatable {
        let garments: [Garment]
        let dna: LookDNA

        var id: String { Self.key(for: garments.map(\.id)) }

        static func key(for ids: [UUID]) -> String {
            ids.map(\.uuidString).sorted().joined(separator: "|")
        }

        static func == (lhs: Card, rhs: Card) -> Bool { lhs.id == rhs.id }
    }

    nonisolated static let onboardingDeckSize = 15
    nonisolated static let dailyDeckSize = 5
    /// Wardrobe needed before swiping makes sense.
    nonisolated static let minimumGarments = 12

    static func isEligible(_ garments: [Garment]) -> Bool {
        let usable = garments.filter { !$0.isBlocked }
        guard usable.count >= minimumGarments else { return false }
        let categories = Set(usable.map(\.category))
        return categories.contains(.top) && categories.contains(.bottom) && categories.contains(.shoes)
    }

    /// A weather-neutral context: swipes teach taste, not weather handling.
    static func neutralContext(profile: UserProfile?, garments: [Garment]) -> RecoContext {
        RecoContext(
            desiredFormality: profile?.preferredFormality ?? 3,
            temperatureC: 20,
            isRaining: false,
            now: Date(),
            profileID: profile?.id,
            warmthSensitivity: profile?.warmthSensitivity ?? 3,
            rainTolerance: profile?.rainTolerance ?? 3,
            taste: TasteAffinityBuilder.build(from: garments),
            allowRepeatedItems: true
        )
    }

    /// Keys of looks swiped recently, so a deck never repeats them.
    static func recentlySwipedKeys(_ events: [RecommendationEvent], days: Double = 30) -> Set<String> {
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        return Set(events.compactMap { event in
            guard event.createdAt >= cutoff,
                  event.kind == .swipeLiked || event.kind == .swipeDisliked else { return nil }
            return Card.key(for: event.selectedGarmentIDs)
        })
    }

    static func build(
        garments: [Garment],
        ctx: RecoContext,
        modelContext: ModelContext,
        size: Int,
        recentlySwiped: Set<String>
    ) -> [Card] {
        let recommender = AIRecommender.shared
        // Personal pool: what the model already ranks well (with layers and accessories).
        let personal = recommender.rankLooks(
            from: garments,
            ctx: ctx,
            modelContext: modelContext,
            perSlot: 10,
            limit: 80,
            includeOptionalLayers: true
        )
        guard let best = personal.first else { return [] }

        let contrasting = recommender.rankLooks(
            from: garments,
            ctx: ctx,
            modelContext: modelContext,
            perSlot: 10,
            limit: 20,
            includeOptionalLayers: true,
            target: AIRecommender.LookTarget(dna: best.dna.contrasting, weight: 0.6, maxShared: 1, avoidSharingWith: Set(best.garments.map(\.id)))
        )

        let state = recommender.ensureState(context: modelContext, profileID: ctx.profileID)
        var candidates: [Candidate] = []
        var seen = recentlySwiped
        func add(_ looks: [[Garment]]) {
            for look in looks {
                let key = Card.key(for: look.map(\.id))
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                let dna = LookDNA(garments: look)
                let preference = recommender.lookPreference(dna, state: state)
                candidates.append(Candidate(
                    garments: look,
                    dna: dna,
                    quality: 0.5 * dna.priorScore + 0.5 * preference,
                    uncertainty: 1 - abs(2 * preference - 1)
                ))
            }
        }
        add(personal.map(\.garments))
        add(contrasting.map(\.garments))
        // Exploration pool: random combinations from the whole closet, so the deck
        // also shows pieces and color schemes the model would never pick yet.
        add(explorationLooks(from: garments, ctx: ctx).filter { LookDNA(garments: $0).priorScore >= 0.55 })
        guard !candidates.isEmpty else { return [] }

        var deck: [Card] = []
        var usage: [UUID: Int] = [:]
        var palettes: Set<LookDNA.Palette> = []
        var silhouettes: Set<LookDNA.Silhouette> = []
        var remaining = candidates

        func pick(_ index: Int) {
            let chosen = remaining.remove(at: index)
            chosen.garments.forEach { usage[$0.id, default: 0] += 1 }
            palettes.insert(chosen.dna.scheme)
            if let silhouette = chosen.dna.silhouette { silhouettes.insert(silhouette) }
            deck.append(Card(garments: chosen.garments, dna: chosen.dna))
        }

        while deck.count < size, !remaining.isEmpty {
            // Every fourth card (and the first) is a likely win; the rest go for variety.
            let reward = deck.count % 4 == 0
            var bestIndex: Int?
            var bestScore = -Double.infinity
            for (i, candidate) in remaining.enumerated() {
                let overused = candidate.garments.contains { usage[$0.id, default: 0] >= 2 }
                let novelty = 1 - (deck.map { $0.dna.similarity(to: candidate.dna) }.max() ?? 0)
                var score: Double
                if reward {
                    score = candidate.quality + 0.2 * novelty
                } else {
                    score = 0.35 * novelty + 0.3 * candidate.uncertainty + 0.35 * candidate.quality
                    if !palettes.contains(candidate.dna.scheme) { score += 0.3 }
                    if let silhouette = candidate.dna.silhouette, !silhouettes.contains(silhouette) { score += 0.1 }
                }
                if overused { score -= 1 }
                if score > bestScore {
                    bestScore = score
                    bestIndex = i
                }
            }
            guard let bestIndex else { break }
            pick(bestIndex)
        }
        return deck
    }

    private struct Candidate {
        let garments: [Garment]
        let dna: LookDNA
        /// Rule-of-thumb quality blended with learned look taste, 0...1.
        let quality: Double
        /// 1 when the model has no idea whether the user likes it.
        let uncertainty: Double
    }

    /// Random top + bottom + shoes (sometimes a layer or accessory) from the whole closet.
    private static func explorationLooks(from garments: [Garment], ctx: RecoContext, count: Int = 160) -> [[Garment]] {
        let usable = garments.filter { !$0.isBlocked && !$0.isCurrentlyUnavailable }
        func pool(_ category: Category) -> [Garment] { usable.filter { $0.category == category } }
        let tops = pool(.top), bottoms = pool(.bottom), shoes = pool(.shoes)
        let outers = pool(.outer).filter { TemperatureComfort.outerGarmentAllowed($0, policy: ctx.outerLayerPolicy) }
        let accessories = pool(.accessory)
        guard !tops.isEmpty, !bottoms.isEmpty, !shoes.isEmpty else { return [] }

        var looks: [[Garment]] = []
        for _ in 0..<count {
            guard let top = tops.randomElement(), let bottom = bottoms.randomElement(), let shoe = shoes.randomElement() else { break }
            let formality = [top, bottom, shoe].map(\.formality)
            // Skip clashing dress codes (sneakers with a suit) before scoring.
            guard (formality.max() ?? 3) - (formality.min() ?? 3) <= 2 else { continue }
            var look = [top, bottom, shoe]
            if Double.random(in: 0...1) < 0.3, let outer = outers.randomElement() { look.append(outer) }
            if Double.random(in: 0...1) < 0.3, let accessory = accessories.randomElement() { look.append(accessory) }
            looks.append(look)
        }
        return looks
    }

    // MARK: - Learning

    enum Verdict {
        case like, pass, love

        var reward: Double {
            switch self {
            case .like: return 1.0
            case .love: return 1.0
            case .pass: return 0.0
            }
        }
    }

    /// One swipe teaches three things: look taste, piece taste, and which pieces
    /// go together. Nothing is saved here; the view saves once per deck.
    static func record(
        _ card: Card,
        verdict: Verdict,
        ctx: RecoContext,
        modelContext: ModelContext
    ) {
        let recommender = AIRecommender.shared
        recommender.learnLook(
            card.garments,
            reward: verdict.reward,
            learningRate: verdict == .love ? 0.22 : 0.15,
            profileID: ctx.profileID,
            modelContext: modelContext,
            save: false
        )
        recommender.learn(
            from: card.garments,
            ctx: ctx,
            reward: verdict == .pass ? 0.2 : 0.8,
            weight: verdict == .love ? 0.75 : 0.5,
            modelContext: modelContext,
            save: false
        )
        if verdict == .love {
            for garment in card.garments {
                garment.loveScore = min(100, garment.loveScore + 3)
            }
        }
        RecommendationEventStore.record(
            kind: verdict == .pass ? .swipeDisliked : .swipeLiked,
            selectedGarmentIDs: card.garments.map(\.id),
            shownGarmentIDs: [],
            dayPlanID: nil,
            context: ctx,
            modelContext: modelContext,
            save: false
        )
    }
}
