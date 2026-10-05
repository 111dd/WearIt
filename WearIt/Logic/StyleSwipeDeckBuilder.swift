import Foundation
import SwiftData

/// Builds Style Swipe decks: whole looks from the user's own wardrobe, chosen
/// so each swipe teaches the recommender as much as possible (active learning)
/// while staying fun.
///  - ~60% looks the model is least sure about (predicted taste near 50%)
///  - ~20% contrasting looks, far from what was already swiped
///  - ~20% looks the user will most likely enjoy (the reward)
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

    static let onboardingDeckSize = 15
    static let dailyDeckSize = 5
    /// Wardrobe needed before swiping makes sense.
    static let minimumGarments = 12

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
        let pool = recommender.rankLooks(
            from: garments,
            ctx: ctx,
            modelContext: modelContext,
            perSlot: 8,
            limit: 60,
            includeOptionalLayers: false
        )
        guard !pool.isEmpty else { return [] }

        var contrasting: [AIRecommender.ScoredLook] = []
        if let best = pool.first {
            contrasting = recommender.rankLooks(
                from: garments,
                ctx: ctx,
                modelContext: modelContext,
                perSlot: 8,
                limit: 12,
                includeOptionalLayers: false,
                target: AIRecommender.LookTarget(dna: best.dna.contrasting, weight: 0.6, maxShared: 1, avoidSharingWith: Set(best.garments.map(\.id)))
            )
        }

        let state = recommender.ensureState(context: modelContext, profileID: ctx.profileID)
        func uncertainty(_ look: AIRecommender.ScoredLook) -> Double {
            1 - abs(2 * recommender.lookPreference(look.dna, state: state) - 1)
        }

        let likely = pool
        // Ties (no look taste yet) fall back to rule-based variety via DNA diversity below.
        let uncertain = pool.enumerated()
            .sorted { lhs, rhs in
                let l = uncertainty(lhs.element), r = uncertainty(rhs.element)
                return l != r ? l > r : lhs.offset > rhs.offset
            }
            .map { $0.element }

        var deck: [Card] = []
        var usedKeys = recentlySwiped
        var usage: [UUID: Int] = [:]

        func take(from source: [AIRecommender.ScoredLook], count: Int) {
            var added = 0
            for look in source where added < count && deck.count < size {
                let key = Card.key(for: look.garments.map(\.id))
                guard !usedKeys.contains(key) else { continue }
                guard look.garments.allSatisfy({ usage[$0.id, default: 0] < 2 }) else { continue }
                // Keep the deck varied: skip near-duplicates of a card already in it.
                if deck.contains(where: { $0.dna.similarity(to: look.dna) > 0.995 && $0.dna.scheme == look.dna.scheme }),
                   source.count > size {
                    continue
                }
                usedKeys.insert(key)
                look.garments.forEach { usage[$0.id, default: 0] += 1 }
                deck.append(Card(garments: look.garments, dna: look.dna))
                added += 1
            }
        }

        let likelyCount = max(1, Int((Double(size) * 0.2).rounded()))
        let contrastCount = max(1, Int((Double(size) * 0.2).rounded()))
        let uncertainCount = max(0, size - likelyCount - contrastCount)

        // Interleave so the deck opens with a likely win, then alternates.
        take(from: likely, count: 1)
        take(from: uncertain, count: uncertainCount)
        take(from: contrasting, count: contrastCount)
        take(from: likely, count: likelyCount - 1)
        // Top up if filters left gaps (small wardrobes).
        take(from: uncertain, count: size)
        take(from: likely, count: size)

        return interleave(deck)
    }

    /// Spread contrasting / likely cards through the deck instead of clustering them.
    private static func interleave(_ deck: [Card]) -> [Card] {
        guard deck.count > 3 else { return deck }
        var head = [deck[0]]
        var rest = Array(deck.dropFirst())
        var result: [Card] = []
        var flip = false
        while !rest.isEmpty {
            result.append(flip ? rest.removeLast() : rest.removeFirst())
            flip.toggle()
        }
        head.append(contentsOf: result)
        return head
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
