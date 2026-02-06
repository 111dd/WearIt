import Foundation
import SwiftData

enum OutfitComposer {
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
        var outers  = base.filter { $0.category == .outer }

        // נסה להימנע מפריטים שנלבשו ממש לאחרונה אם יש חלופות
        if tops.count > 3 { tops.removeAll(where: isRecent) }
        if bottoms.count > 3 { bottoms.removeAll(where: isRecent) }
        if shoes.count > 2 { shoes.removeAll(where: isRecent) }
        if outers.count > 2 { outers.removeAll(where: isRecent) }

        // אם חסר חלק חובה (מכנס/נעליים) – אל נחזיר סט לא תקין
        guard !tops.isEmpty, !bottoms.isEmpty, !shoes.isEmpty else {
            return []
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
                let needOuter = ctx.isRaining || ctx.temperatureC < 16
                let candO = pruned(outers, n: 4)
                var best: ([Garment], Double)? = nil
                for b in (candB.isEmpty ? bottoms : candB) {
                    for s in (candS.isEmpty ? shoes : candS) {
                        let outerCandidates: [Garment?] = needOuter && !candO.isEmpty ? candO.map { Optional($0) } : [nil] + candO.map { Optional($0) }
                        for o in outerCandidates {
                            let set = [locked, b, s] + (o != nil ? [o!] : [])
                            let key = outfitKey(for: set)
                            if dismissedKeys.contains(key) { continue }
                            let sc = scoreSet(top: locked, bottom: b, shoes: s, outer: o, needOuter: needOuter, ctx: ctx, modelContext: modelContext)
                            if best == nil || sc > best!.1 { best = (set, sc) }
                        }
                    }
                }
                if let res = best?.0 { return res }
                // fallback: מינימום חוקי
                let fallbackOuter = (ctx.isRaining || ctx.temperatureC < 16) ? outers.first : nil
                return [locked, bottoms.first!, shoes.first!] + (fallbackOuter.map { [$0] } ?? [])

            case .bottom:
                let candT = pruned(tops, n: 8)
                let candS = pruned(shoes, n: 6)
                let needOuter = ctx.isRaining || ctx.temperatureC < 16
                let candO = pruned(outers, n: 4)
                var best: ([Garment], Double)? = nil
                for t in (candT.isEmpty ? tops : candT) {
                    for s in (candS.isEmpty ? shoes : candS) {
                        let outerCandidates: [Garment?] = needOuter && !candO.isEmpty ? candO.map { Optional($0) } : [nil] + candO.map { Optional($0) }
                        for o in outerCandidates {
                            let set = [t, locked, s] + (o != nil ? [o!] : [])
                            let key = outfitKey(for: set)
                            if dismissedKeys.contains(key) { continue }
                            let sc = scoreSet(top: t, bottom: locked, shoes: s, outer: o, needOuter: needOuter, ctx: ctx, modelContext: modelContext)
                            if best == nil || sc > best!.1 { best = (set, sc) }
                        }
                    }
                }
                if let res = best?.0 { return res }
                let fallbackOuter = (ctx.isRaining || ctx.temperatureC < 16) ? outers.first : nil
                return [tops.first!, locked, shoes.first!] + (fallbackOuter.map { [$0] } ?? [])

            case .shoes:
                let candT = pruned(tops, n: 8)
                let candB = pruned(bottoms, n: 8)
                let needOuter = ctx.isRaining || ctx.temperatureC < 16
                let candO = pruned(outers, n: 4)
                var best: ([Garment], Double)? = nil
                for t in (candT.isEmpty ? tops : candT) {
                    for b in (candB.isEmpty ? bottoms : candB) {
                        let outerCandidates: [Garment?] = needOuter && !candO.isEmpty ? candO.map { Optional($0) } : [nil] + candO.map { Optional($0) }
                        for o in outerCandidates {
                            let set = [t, b, locked] + (o != nil ? [o!] : [])
                            let key = outfitKey(for: set)
                            if dismissedKeys.contains(key) { continue }
                            let sc = scoreSet(top: t, bottom: b, shoes: locked, outer: o, needOuter: needOuter, ctx: ctx, modelContext: modelContext)
                            if best == nil || sc > best!.1 { best = (set, sc) }
                        }
                    }
                }
                if let res = best?.0 { return res }
                let fallbackOuter = (ctx.isRaining || ctx.temperatureC < 16) ? outers.first : nil
                return [tops.first!, bottoms.first!, locked] + (fallbackOuter.map { [$0] } ?? [])

            default: break
            }
        }

        // ללא נעילה — כמו קודם
        let candT = pruned(tops, n: 8)
        let candB = pruned(bottoms, n: 8)
        let candS = pruned(shoes, n: 6)
        let candO = pruned(outers, n: 4)

        let needOuter = ctx.isRaining || ctx.temperatureC < 16

        var best: (set: [Garment], score: Double)? = nil
        for t in (candT.isEmpty ? tops : candT) {
            for b in (candB.isEmpty ? bottoms : candB) {
                for s in (candS.isEmpty ? shoes : candS) {
                    let outerCandidates: [Garment?] = needOuter && !candO.isEmpty ? candO.map { Optional($0) } : [nil] + candO.map { Optional($0) }
                    for o in outerCandidates {
                        let set = [t, b, s] + (o != nil ? [o!] : [])
                        let key = outfitKey(for: set)
                        if dismissedKeys.contains(key) { continue }
                        let sc = scoreSet(top: t, bottom: b, shoes: s, outer: o, needOuter: needOuter, ctx: ctx, modelContext: modelContext)
                        if best == nil || sc > best!.score { best = (set, sc) }
                    }
                }
            }
        }

        if let res = best?.set { return res }
        // fallback מינימלי: פריט ראשון מכל קטגוריה
        let fallbackOuter = needOuter ? outers.first : nil
        return [tops.first!, bottoms.first!, shoes.first!] + (fallbackOuter.map { [$0] } ?? [])
    }

    // ניקוד סט: ממוצע ניקוד לוגיסטי של כל פריט (אפשר לשפר בהמשך עם התאמות צבע/סגנון)
    private static func scoreSet(top: Garment, bottom: Garment, shoes: Garment, outer: Garment?, needOuter: Bool, ctx: RecoContext, modelContext: ModelContext) -> Double {
        let ai = AIRecommender.shared
        let s = ai.ensureState(context: modelContext)
        let w = s.weights, b = s.bias

        func scoreItem(_ g: Garment) -> Double {
            let x = ai.features(for: g, ctx: ctx)
            var z = b; for i in 0..<x.count { z += w[i] * x[i] }
            return 1.0 / (1.0 + exp(-z))
        }

        var parts = [scoreItem(top), scoreItem(bottom), scoreItem(shoes)]
        if let o = outer { parts.append(scoreItem(o)) }

        let base = parts.reduce(0,+) / Double(parts.count)

        // בונוסים קלים (לשיפור UX): התאמת פורמליות וחום בין top/bottom/outer
        let formalityGap = abs(top.formality - bottom.formality)
        let warmthGap = abs(top.warmth - bottom.warmth)
        let outerWarmthGap = outer.map { abs($0.warmth - top.warmth) } ?? 0
        let styleBonus = max(0.0, 0.08 - 0.02 * Double(formalityGap + warmthGap + outerWarmthGap))

        // עונש אם צריך מעיל ואין
        let outerPenalty = (needOuter && outer == nil) ? 0.15 : 0.0

        return base + styleBonus - outerPenalty
    }
}

