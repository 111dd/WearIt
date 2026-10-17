//
//  PurchaseScorer.swift
//  WearIt
//
//  Ranks shop products by "how much would you actually wear this?" against the user's own wardrobe
//  (plan: project plans/shopping-israel.md). Four parts make the prior:
//    taste   – close to what the user wears and loves (choice-weighted `TasteAffinityBuilder` profile)
//    looks   – how many good looks it makes with the user's most-worn pieces (`AIRecommender.lookScore`)
//    need    – does it close a wardrobe gap (`WardrobeGapAnalyzer`)
//    size    – in stock in the user's usual size (a hard filter when the shop says)
//  minus a penalty for things the user already owns plenty of. `ShopPreferenceModel` learns on top
//  of that prior from saves, shop visits, "not for me" and purchases, and takes over as it learns.
//  Everything runs on the device.
//

import Foundation
import SwiftData

@MainActor
enum PurchaseScorer {
    struct Input {
        var garments: [Garment]
        /// Wear count per garment inside `windowDays` (from `WardrobeGapAnalyzer.wearSummary`).
        var wearCounts: [UUID: Int]
        var windowDays: Int = 90
        var taste: TasteAffinityBuilder.Profile
        var gaps: [WardrobeGapAnalyzer.Gap]
        var profile: UserProfile?
        var gender: ShopGender
        var model: ShopPreferenceModel
        var modelContext: ModelContext
        var now = Date()
    }

    enum Reason: Hashable {
        case fillsGap(WardrobeGapAnalyzer.Kind, Category)
        case opensLooks(Int)
        case lovedColor(ColorTag)
        case lovedBrand(String)
        case wornType(ItemType)
        case onSale(Int)
        case inYourSize(SizeOption)
        case alreadyHave(Int, ItemType)
    }

    struct Pick: Identifiable {
        let product: ShopProduct
        let score: Double
        /// About how many times a month the user would wear it, from how often they wear this category.
        let wearsPerMonth: Double?
        let looks: Int
        let reasons: [Reason]
        /// What `ShopPreferenceModel` sees (kept for learning from the user's reaction).
        let features: [Double]

        var id: String { product.id }
    }

    /// Products scored deeply (look building) after the cheap taste pass.
    private static let deepPoolSize = 70

    static func rank(_ products: [ShopProduct], input: Input, isHidden: (String) -> Bool, limit: Int = 40) -> [Pick] {
        let wardrobe = input.garments.filter { !$0.isBlocked }
        guard !wardrobe.isEmpty else { return [] }

        let candidates = products.filter { product in
            input.gender.includes(product.item.gender)
                && !isHidden(product.id)
                && fitsUsualSize(product, input: input, wardrobe: wardrobe)
        }
        guard !candidates.isEmpty else { return [] }

        let typeShare = wornTypeShare(wardrobe, wearCounts: input.wearCounts)
        let affinity = QuickAffinity(taste: input.taste)
        let quick = candidates
            .map { ($0, quickScore($0, affinity: affinity, typeShare: typeShare, gaps: input.gaps)) }
            .sorted { $0.1 > $1.1 }
            .prefix(deepPoolSize)

        let partners = PartnerPool(wardrobe: wardrobe, wearCounts: input.wearCounts)
        let recoContext = RecoContext(
            desiredFormality: Int(input.taste.formalityMean.rounded()),
            temperatureC: 22,
            isRaining: false,
            now: input.now,
            profileID: input.profile?.id,
            taste: input.taste
        )
        let state = AIRecommender.shared.ensureState(context: input.modelContext, profileID: input.profile?.id)
        let categoryRates = monthlyWearRate(wardrobe, wearCounts: input.wearCounts, windowDays: input.windowDays)
        let learnedShare = 0.6 * min(1.0, Double(input.model.interactions) / 30.0)

        var picks: [Pick] = []
        for (product, _) in quick {
            let garment = transientGarment(for: product)
            var reasons: [Reason] = []

            // Taste
            let taste = input.taste
            let tastePart = min(1, 0.30 * taste.colorScore(for: garment)
                + 0.15 * taste.brandScore(for: garment)
                + 0.20 * taste.styleScore(for: garment)
                + 0.10 * taste.categoryScore(for: garment)
                + 0.10 * taste.materialScore(for: garment)
                + 0.15 * (typeShare[product.itemType.map { $0.rawValue } ?? ""] ?? 0) * 3)
            if let color = product.colors.first(where: { (taste.colorAffinity[$0] ?? 0) >= 0.6 }) {
                reasons.append(.lovedColor(color))
            }
            if taste.brandScore(for: garment) >= 0.6, let brand = product.item.brand {
                reasons.append(.lovedBrand(brand))
            }
            if let type = product.itemType, (typeShare[type.rawValue] ?? 0) >= 0.15 {
                reasons.append(.wornType(type))
            }

            // Looks
            let looks = partners.goodLooks(with: garment, ctx: recoContext, state: state)
            if looks.count >= 2 { reasons.insert(.opensLooks(looks.count), at: 0) }

            // Need
            let gap = bestGap(for: product, in: input.gaps)
            let needPart = gap?.priority ?? 0
            if let gap { reasons.insert(.fillsGap(gap.kind, gap.suggestion.category), at: 0) }

            // Already owned
            let owned = ownedCount(like: product, in: wardrobe)
            let redundancy = min(0.45, max(0, Double(owned - 1)) * 0.15)
            if owned >= 2, let type = product.itemType { reasons.append(.alreadyHave(owned, type)) }

            let discount = Double(product.discountPercent ?? 0) / 100
            if let percent = product.discountPercent { reasons.append(.onSale(percent)) }
            if let size = MySizesView.usualSize(for: product.category, profile: input.profile, garments: wardrobe),
               product.inStockSizes.contains(size) {
                reasons.append(.inYourSize(size))
            }

            let prior = 0.35 * tastePart + 0.30 * looks.share + 0.25 * needPart + 0.10 * min(1, discount * 2) - redundancy
            let features = featureVector(
                taste: tastePart, looks: looks.share, need: needPart, discount: discount,
                redundancy: redundancy, product: product
            )
            let learned = input.model.predict(features)
            var score = (1 - learnedShare) * prior + learnedShare * learned
            score += exploration(for: product.id, interactions: input.model.interactions, now: input.now)

            let rate = categoryRates[product.category]
            let wears = rate.map { $0 * (0.4 + 1.2 * max(0, min(1, score))) }
            picks.append(Pick(
                product: product, score: score, wearsPerMonth: wears, looks: looks.count,
                reasons: reasons, features: features
            ))
        }

        return diversified(picks.sorted { $0.score > $1.score }, limit: limit)
    }

    // MARK: - Parts

    /// The shop must have the user's usual size when it lists stock; unknown stock passes.
    private static func fitsUsualSize(_ product: ShopProduct, input: Input, wardrobe: [Garment]) -> Bool {
        guard !product.inStockSizes.isEmpty,
              let size = MySizesView.usualSize(for: product.category, profile: input.profile, garments: wardrobe) else { return true }
        return product.inStockSizes.contains(size)
    }

    /// The taste maps the quick pass reads, normalized once instead of per product.
    private struct QuickAffinity {
        let color: [ColorTag: Double]
        let category: [Category: Double]
        let style: [StyleTag: Double]

        init(taste: TasteAffinityBuilder.Profile) {
            color = taste.colorAffinity
            category = taste.categoryAffinity
            style = taste.styleAffinity
        }
    }

    /// Cheap pass over the whole catalog, straight from product fields.
    private static func quickScore(
        _ product: ShopProduct,
        affinity: QuickAffinity,
        typeShare: [String: Double],
        gaps: [WardrobeGapAnalyzer.Gap]
    ) -> Double {
        let colors = product.colors.compactMap { affinity.color[$0] }
        let color = colors.isEmpty ? 0 : colors.reduce(0, +) / Double(colors.count)
        let category = affinity.category[product.category] ?? 0
        let styles = product.itemType.flatMap { ItemTypeDefaults.defaults(for: $0)?.styleTags } ?? []
        let styleValues = styles.compactMap { affinity.style[$0] }
        let style = styleValues.isEmpty ? 0 : styleValues.reduce(0, +) / Double(styleValues.count)
        let type = typeShare[product.itemType.map { $0.rawValue } ?? ""] ?? 0
        let need = bestGap(for: product, in: gaps)?.priority ?? 0
        return 0.3 * color + 0.15 * category + 0.2 * style + 0.25 * min(1, type * 3) + 0.3 * need
    }

    /// A Garment the scorer can read, never inserted into the store.
    static func transientGarment(for product: ShopProduct) -> Garment {
        let garment = Garment(
            category: product.category,
            itemType: product.itemType,
            brand: product.item.brand,
            colorTags: product.colors,
            materialTags: product.materials,
            patternTag: product.pattern,
            fitTag: product.fit
        )
        ItemTypeDefaults.apply(to: garment)
        return garment
    }

    /// Share of wear days per item type: does the user actually wear this kind of thing?
    private static func wornTypeShare(_ wardrobe: [Garment], wearCounts: [UUID: Int]) -> [String: Double] {
        var mass: [String: Double] = [:]
        for garment in wardrobe {
            guard let type = garment.itemType else { continue }
            mass[type.rawValue, default: 0] += Double(wearCounts[garment.id] ?? 0) + 0.25
        }
        let total = mass.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return mass.mapValues { $0 / total }
    }

    /// Wears per item per month in each category.
    private static func monthlyWearRate(_ wardrobe: [Garment], wearCounts: [UUID: Int], windowDays: Int) -> [Category: Double] {
        var result: [Category: Double] = [:]
        let months = max(1, Double(windowDays) / 30)
        for category in Category.allCases {
            let items = wardrobe.filter { $0.category == category }
            guard !items.isEmpty else { continue }
            let wears = items.reduce(0) { $0 + (wearCounts[$1.id] ?? 0) }
            guard wears > 0 else { continue }
            result[category] = Double(wears) / Double(items.count) / months
        }
        return result
    }

    private static func bestGap(for product: ShopProduct, in gaps: [WardrobeGapAnalyzer.Gap]) -> WardrobeGapAnalyzer.Gap? {
        gaps.filter { gap in
            guard gap.suggestion.category == product.category else { return false }
            guard let type = gap.suggestion.itemType else { return true }
            // Rain / warmth gaps name one type but any outer layer of the same kind counts.
            return type == product.itemType || gap.kind == .thinRotation || gap.kind == .missingCore
        }
        .max { $0.priority < $1.priority }
    }

    private static func ownedCount(like product: ShopProduct, in wardrobe: [Garment]) -> Int {
        guard let type = product.itemType else { return 0 }
        let color = product.colors.first
        return wardrobe.filter { $0.itemType == type && (color == nil || $0.safeColorTags.first == color) }.count
    }

    private static func featureVector(
        taste: Double, looks: Double, need: Double, discount: Double, redundancy: Double, product: ShopProduct
    ) -> [Double] {
        var x = [taste, looks, need, discount, redundancy]
        // Append-only: new features go at the end so saved weights still line up.
        x += Category.allCases.map { $0 == product.category ? 1.0 : 0.0 }
        let price = product.price ?? 0
        x.append(price > 0 ? min(1, log10(price) / 3) : 0)
        return x
    }

    /// A small, day-stable nudge so new kinds of picks get a chance to be learned.
    private static func exploration(for id: String, interactions: Int, now: Date) -> Double {
        let day = Int(now.timeIntervalSince1970 / 86_400)
        var hash: UInt64 = 1469598103934665603
        for byte in "\(id)|\(day)".utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let unit = Double(hash % 10_000) / 10_000
        return unit * 0.06 / sqrt(1 + Double(interactions) / 10)
    }

    /// Fewer repeats of the same item type near the top.
    private static func diversified(_ sorted: [Pick], limit: Int) -> [Pick] {
        var remaining = sorted
        var result: [Pick] = []
        var typeCounts: [String: Int] = [:]
        while !remaining.isEmpty, result.count < limit {
            let index = remaining.indices.max { a, b in
                adjusted(remaining[a], typeCounts) < adjusted(remaining[b], typeCounts)
            }!
            let pick = remaining.remove(at: index)
            typeCounts[pick.product.itemType?.rawValue ?? pick.product.category.rawValue, default: 0] += 1
            result.append(pick)
        }
        return result
    }

    private static func adjusted(_ pick: Pick, _ typeCounts: [String: Int]) -> Double {
        let key = pick.product.itemType?.rawValue ?? pick.product.category.rawValue
        return pick.score * pow(0.85, Double(typeCounts[key] ?? 0))
    }
}

// MARK: - Look building

/// The user's most-worn pieces per core category, to try a product against.
@MainActor
private struct PartnerPool {
    private var byCategory: [Category: [(garment: Garment, score: Double)]] = [:]

    private static let perCategory = 4

    init(wardrobe: [Garment], wearCounts: [UUID: Int]) {
        let maxWears = Double(wearCounts.values.max() ?? 0)
        for category in [Category.top, .bottom, .shoes, .outer] {
            byCategory[category] = wardrobe
                .filter { $0.category == category && !$0.isCurrentlyUnavailable }
                .map { garment -> (garment: Garment, score: Double) in
                    let wear = maxWears > 0 ? Double(wearCounts[garment.id] ?? 0) / maxWears : 0
                    return (garment, 0.6 * wear + 0.4 * Double(garment.loveScore) / 100)
                }
                .sorted { $0.score > $1.score }
                .prefix(Self.perCategory)
                .map { $0 }
        }
    }

    /// How many of the looks the product makes score at least as well as the user's own looks
    /// from the same pieces. `share` is that count over all looks tried (0...1).
    func goodLooks(with product: Garment, ctx: RecoContext, state: RecoState) -> (count: Int, share: Double) {
        guard product.category != .accessory else { return (0, 0) }
        let core: [Category] = [.top, .bottom, .shoes]
        let partnerSlots = core.filter { $0 != product.category }
        let partnerLists = partnerSlots.map { byCategory[$0] ?? [] }
        guard partnerLists.allSatisfy({ !$0.isEmpty }) else { return (0, 0) }

        // The user's own looks: same partners with their own pieces of the product's category
        // (for outerwear, the core looks without a layer).
        let own = product.category == .outer ? [] : (byCategory[product.category] ?? [])
        var baseline: [Double] = []
        for combo in combinations(partnerLists) {
            if product.category == .outer {
                baseline.append(score(combo, ctx: ctx, state: state))
            } else {
                for piece in own {
                    baseline.append(score(combo + [piece], ctx: ctx, state: state))
                }
            }
        }
        guard !baseline.isEmpty else { return (0, 0) }
        baseline.sort()
        let median = baseline[baseline.count / 2]

        // The product gets the average habit score of what it competes with, so only the look itself decides.
        let rivals = own.isEmpty ? partnerLists.flatMap { $0 } : own
        let productScore = rivals.map { $0.score }.reduce(0, +) / Double(max(1, rivals.count))
        var good = 0
        var total = 0
        for combo in combinations(partnerLists) {
            total += 1
            if score(combo + [(product, productScore)], ctx: ctx, state: state) >= median {
                good += 1
            }
        }
        return (good, total > 0 ? Double(good) / Double(total) : 0)
    }

    private func score(_ pieces: [(garment: Garment, score: Double)], ctx: RecoContext, state: RecoState) -> Double {
        AIRecommender.shared.lookScore(
            garments: pieces.map { $0.garment },
            itemScores: pieces.map { $0.score },
            ctx: ctx,
            state: state
        ).score
    }

    private func combinations(_ lists: [[(garment: Garment, score: Double)]]) -> [[(garment: Garment, score: Double)]] {
        lists.reduce([[]]) { partial, list in
            partial.flatMap { combo in list.map { combo + [$0] } }
        }
    }
}
