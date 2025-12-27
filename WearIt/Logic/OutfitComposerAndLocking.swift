import Foundation
import SwiftData

extension OutfitComposer {
    /// ורסיה עם נעילת פריט + פסילת פריטים בלתי זמינים + סינון "נלבש לאחרונה".
    static func suggestOutfit(
        from all: [Garment],
        ctx: RecoContext,
        modelContext: ModelContext,
        locked: Garment? = nil,
        minDaysSinceWorn: Int = 2
    ) -> [Garment] {

        // שלוף רשימת סטים שנפסלו
        let dismissedKeys: Set<String> = {
            let desc = FetchDescriptor<DismissedOutfit>()
            let rows = (try? modelContext.fetch(desc)) ?? []
            return Set(rows.map { $0.key })
        }()

        // סינון בסיסי
        func isRecent(_ g: Garment) -> Bool {
            guard let d = g.lastWorn else { return false }
            return Date().timeIntervalSince(d) < Double(minDaysSinceWorn) * 86400
        }

        let base = all.filter {
            !$0.isBlocked &&
            !$0.isCurrentlyUnavailable
        }

        var tops    = base.filter { $0.category == .top }
        var bottoms = base.filter { $0.category == .bottom }
        var shoes   = base.filter { $0.category == .shoes }

        // נסה להימנע מפריטים שנלבשו ממש לאחרונה אם יש חלופות
        if tops.count > 3 { tops.removeAll(where: isRecent) }
        if bottoms.count > 3 { bottoms.removeAll(where: isRecent) }
        if shoes.count > 2 { shoes.removeAll(where: isRecent) }

        // אם אין כיסוי מלא – fallback לפריטים חזקים
        guard !tops.isEmpty, !bottoms.isEmpty, !shoes.isEmpty else {
            return AIRecommender.shared.suggest(from: base, k: min(3, base.count), ctx: ctx, modelContext: modelContext)
        }

        // פרונינג פר־קטגוריה
        func pruned(_ arr: [Garment], n: Int) -> [Garment] {
            let ai = AIRecommender.shared
            let s = ai.ensureState(context: modelContext)
            let w = s.weights, b = s.bias
            func scoreItem(_ g: Garment) -> Double {
                let x = ai.features(for: g, ctx: ctx)
                var s = b; for i in 0..<x.count { s += w[i]*x[i] }
                return 1.0 / (1.0 + exp(-s))
            }
            return arr
                .map { ($0, scoreItem($0)) }
                .shuffled()
                .sorted { $0.1 > $1.1 }
                .prefix(min(n, arr.count))
                .map { $0.0 }
        }

        // אם יש פריט נעול — בחר סביבו
        if let locked = locked, base.contains(where: { $0.persistentModelID == locked.persistentModelID }) {
            switch locked.category {
            case .top:
                let candB = pruned(bottoms, n: 8)
                let candS = pruned(shoes, n: 6)
                var best: ([Garment], Double)? = nil
                for b in candB {
                    for s in candS {
                        let set = [locked, b, s]
                        let key = outfitKey(for: set)
                        if dismissedKeys.contains(key) { continue }
                        let sc = scoreSet(top: locked, bottom: b, shoes: s, ctx: ctx, modelContext: modelContext)
                        if best == nil || sc > best!.1 { best = (set, sc) }
                    }
                }
                if let res = best?.0 { return res }

            case .bottom:
                let candT = pruned(tops, n: 8)
                let candS = pruned(shoes, n: 6)
                var best: ([Garment], Double)? = nil
                for t in candT {
                    for s in candS {
                        let set = [t, locked, s]
                        let key = outfitKey(for: set)
                        if dismissedKeys.contains(key) { continue }
                        let sc = scoreSet(top: t, bottom: locked, shoes: s, ctx: ctx, modelContext: modelContext)
                        if best == nil || sc > best!.1 { best = (set, sc) }
                    }
                }
                if let res = best?.0 { return res }

            case .shoes:
                let candT = pruned(tops, n: 8)
                let candB = pruned(bottoms, n: 8)
                var best: ([Garment], Double)? = nil
                for t in candT {
                    for b in candB {
                        let set = [t, b, locked]
                        let key = outfitKey(for: set)
                        if dismissedKeys.contains(key) { continue }
                        let sc = scoreSet(top: t, bottom: b, shoes: locked, ctx: ctx, modelContext: modelContext)
                        if best == nil || sc > best!.1 { best = (set, sc) }
                    }
                }
                if let res = best?.0 { return res }

            default: break
            }
        }

        // ללא נעילה — כמו קודם
        let candT = pruned(tops, n: 8)
        let candB = pruned(bottoms, n: 8)
        let candS = pruned(shoes, n: 6)

        var best: (set: [Garment], score: Double)? = nil
        for t in candT {
            for b in candB {
                for s in candS {
                    let set = [t, b, s]
                    let key = outfitKey(for: set)
                    if dismissedKeys.contains(key) { continue }
                    let sc = scoreSet(top: t, bottom: b, shoes: s, ctx: ctx, modelContext: modelContext)
                    if best == nil || sc > best!.score { best = (set, sc) }
                }
            }
        }
        return best?.set ?? []
    }
}
