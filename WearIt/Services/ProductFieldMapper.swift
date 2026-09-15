import Foundation

/// Single source of truth for mapping free-text product metadata into WearIt taxonomy.
/// Used by barcode API, HTML scrape, Digimarc/DPID resolvers, and on-device AutoFill.
enum ProductFieldMapper {

    // MARK: - Category

    static func mapCategory(path: String, title: String?) -> Category? {
        let haystack = normalize("\(path) \(title ?? "")")
        guard !haystack.isEmpty else { return nil }

        // Scored phrases — longer / more specific wins within each bucket.
        let shoesScore = bestScore(haystack, [
            "footwear", "sneaker", "loafer", "sandal", "boot", "heel", "shoe",
            "נעליים", "סניקרס", "מגפיים", "סנדלים"
        ])
        let outerScore = bestScore(haystack, [
            "outerwear", "raincoat", "windbreaker", "puffer", "parka", "blazer", "jacket", "coat",
            "מעיל", "גקט", "ג'קט", "בלייזר"
        ])
        let topScore = bestScore(haystack, [
            "t-shirt", "tshirt", "tshirts", "knit shirt", "crew neck", "short sleeve", "long sleeve",
            "blouse", "cardigan", "sweater", "hoodie", "polo", "tank", "shirt", "shirts", "top", "tee", "vest",
            "טי שרט", "טי-שרט", "טישרט", "טישירט", "חולצה", "חולצות", "גופיה", "קפוצון", "סווטשירט", "סוודר", "פולו"
        ])
        let bottomScore: Int = {
            let phrases = [
                "sweatpant", "legging", "trouser", "jogger", "chino", "skirt", "jean", "jeans", "pant", "pants", "bottom", "shorts",
                "מכנסיים", "ג'ינס", "גינס", "שורט", "חצאית", "טייץ"
            ]
            if hasStandaloneShorts(haystack) {
                return max(bestScore(haystack, phrases), 8)
            }
            return bestScore(haystack, phrases)
        }()
        let accessoryScore = bestScore(haystack, [
            "sunglass", "jewellery", "jewelry", "accessor", "scarf", "watch", "belt", "bag", "hat", "cap", "tie",
            "משקפיים", "צעיף", "חגורה", "תיק", "כובע", "שעון"
        ])

        // Fixed priority when scores tie across buckets.
        struct Candidate { let category: Category; let score: Int; let priority: Int }
        let candidates: [Candidate] = [
            .init(category: .shoes, score: shoesScore, priority: 0),
            .init(category: .outer, score: outerScore, priority: 1),
            .init(category: .top, score: topScore, priority: 2),
            .init(category: .bottom, score: bottomScore, priority: 3),
            .init(category: .accessory, score: accessoryScore, priority: 4)
        ]
        .filter { $0.score > 0 }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.priority < $1.priority
        }

        if let best = candidates.first, best.score >= 3 {
            return best.category
        }

        // Weak apparel signal only — still better than guessing bottoms from "short".
        if haystack.contains("clothing") || path.localizedCaseInsensitiveContains("Apparel") {
            return .top
        }
        return nil
    }

    // MARK: - Item type

    static func mapItemType(path: String, title: String?, category: Category?) -> ItemType? {
        let haystack = normalize("\(path) \(title ?? "")")
        guard !haystack.isEmpty else { return nil }

        let pairs: [(ItemType, [String])] = [
            (.tshirt, ["t-shirt", "tshirt", "tshirts", "crew neck", "tee ", " tee", "טי שרט", "טי-שרט", "טישרט", "טישירט"]),
            (.polo, ["polo", "פולו"]),
            (.shirt, ["dress shirt", "button-down", "button down", "oxford shirt", "knit shirt", "חולצה מכופתרת", "shirts"]),
            (.blouse, ["blouse"]),
            (.tank, ["tank", "sleeveless", "גופיה"]),
            (.hoodie, ["hoodie", "hooded", "קפוצון"]),
            (.cardigan, ["cardigan", "קרדיגן"]),
            (.sweater, ["sweater", "jumper", "pullover", "סוודר", "סריג"]),
            (.vest, ["vest"]),
            (.jeans, ["jean", "jeans", "denim pant", "ג'ינס", "גינס"]),
            (.chinos, ["chino"]),
            (.trousers, ["trouser", "slack", "מכנסיים ארוכים"]),
            (.shorts, ["shorts", "short pant", "short trouser", "chino short", "jean short", "bermuda", "boardshort", "מכנסיים קצרים", "שורטס"]),
            (.skirt, ["skirt", "חצאית"]),
            (.leggings, ["legging", "טייץ"]),
            (.joggers, ["jogger"]),
            (.sweatpants, ["sweatpant", "sweat pant", "טרנינג"]),
            (.sneakers, ["sneaker", "trainer", "running shoe", "סניקרס"]),
            (.boots, ["boot", "מגף", "מגפיים"]),
            (.loafers, ["loafer"]),
            (.sandals, ["sandal", "סנדל"]),
            (.heels, ["heel", "pump", "עקב"]),
            (.flats, ["flat"]),
            (.oxfords, ["oxford"]),
            (.slippers, ["slipper"]),
            (.denim_jacket, ["denim jacket", "jean jacket"]),
            (.raincoat, ["raincoat", "rain coat"]),
            (.windbreaker, ["windbreaker", "wind breaker"]),
            (.puffer, ["puffer", "down jacket"]),
            (.parka, ["parka"]),
            (.blazer, ["blazer", "בלייזר"]),
            (.jacket, ["jacket", "גקט", "ג'קט"]),
            (.coat, ["coat", "מעיל"]),
            (.sunglasses, ["sunglass", "משקפי שמש"]),
            (.jewelry, ["jewel"]),
            (.scarf, ["scarf", "צעיף"]),
            (.belt, ["belt", "חגורה"]),
            (.watch, ["watch", "שעון"]),
            (.bag, ["bag", "backpack", "tote", "תיק"]),
            (.hat, ["hat", "beanie", "כובע"]),
            (.cap, ["cap", "baseball cap"]),
            (.tie, ["tie", "necktie"])
        ]

        var best: (type: ItemType, score: Int)?
        for (type, keywords) in pairs {
            if let category, !category.itemTypes.contains(type), type != .other {
                continue
            }
            let score = bestScore(haystack, keywords)
            if score > 0, best == nil || score > best!.score {
                best = (type, score)
            }
        }

        if let best, best.score >= 3 {
            return best.type
        }

        if category == .bottom, hasStandaloneShorts(haystack) {
            return .shorts
        }

        // Pants without a more specific type — only when "pant" is present (not bare defaults).
        if category == .bottom || category == nil {
            if bestScore(haystack, ["pant"]) >= 4, bestScore(haystack, ["jean", "chino", "jogger", "sweat"]) == 0 {
                if category == nil || category == .bottom {
                    return .trousers
                }
            }
        }

        // No low-confidence category defaults (.tshirt / .trousers) — leave nil for the user/AI.
        return nil
    }

    /// True for garment shorts, false for "short sleeve" tops.
    static func hasStandaloneShorts(_ haystack: String) -> Bool {
        let text = normalize(haystack)
        if text.contains("shorts") { return true }
        guard text.contains("short") else { return false }
        if text.contains("short sleeve") || text.contains("short-sleeve") || text.contains("shortsleeve") {
            return false
        }
        return bestScore(text, [
            "short pant", "bermuda", "boardshort", "chino short", "jean short"
        ]) >= 3
            || (text.contains("short") && bestScore(text, ["pant", "bottom", "trouser", "chino", "jean"]) >= 3)
    }

    // MARK: - Colors

    static func mapColors(colorField: String?, title: String?) -> [ColorTag] {
        var tokens: [String] = []
        if let colorField, !colorField.isEmpty {
            tokens += splitColorTokens(colorField)
        }
        if let title {
            let parts = title.split(separator: "-").map(String.init)
            if let last = parts.last, last.count <= 24 {
                tokens += splitColorTokens(parts.dropLast().last ?? last)
            }
            // Only append an explicit color token when matchColor would resolve it —
            // avoids flooding with weak title substring hits.
            for known in ColorTag.allCases {
                let candidates = [known.rawValue, known.title.lowercased()]
                if candidates.contains(where: { title.localizedCaseInsensitiveContains($0) }),
                   let tag = matchColor(known.rawValue) {
                    tokens.append(tag.rawValue)
                }
            }
        }

        var result: [ColorTag] = []
        for token in tokens {
            if let tag = matchColor(token), !result.contains(tag) {
                result.append(tag)
            }
            if result.count >= 3 { break }
        }
        return result
    }

    static func matchColor(_ raw: String) -> ColorTag? {
        let token = normalize(raw)
        guard !token.isEmpty else { return nil }

        let aliases: [(ColorTag, [String])] = [
            (.black, ["black", "noir", "שחור"]),
            (.white, ["white", "ivory", "לבן"]),
            (.gray, ["gray", "grey", "charcoal", "heather", "אפור"]),
            (.navy, ["navy", "נייבי", "כחול כהה", "כחול נייבי"]),
            (.lightBlue, ["light blue", "baby blue", "cornflower", "sky blue", "powder blue", "lightblue", "תכלת", "כחול בהיר"]),
            (.blue, ["blue", "cobalt", "royal", "teal", "כחול"]),
            (.red, ["red", "אדום"]),
            (.pink, ["pink", "rose", "ורוד"]),
            (.orange, ["orange", "כתום"]),
            (.yellow, ["yellow", "gold", "צהוב"]),
            (.green, ["green", "ירוק"]),
            (.olive, ["olive", "khaki", "זית"]),
            (.brown, ["brown", "chocolate", "mocha", "חום"]),
            (.beige, ["beige", "tan", "sand", "בז"]),
            (.cream, ["cream", "off-white", "off white", "שמנת"]),
            (.burgundy, ["burgundy", "maroon", "wine", "בורדו"]),
            (.purple, ["purple", "violet", "lilac", "סגול"]),
            (.denim, ["denim", "דנים"]),
            (.multicolor, ["multi-color", "multicolor", "multi", "מולטי"])
        ]

        var best: (tag: ColorTag, score: Int)?
        for (tag, words) in aliases {
            for word in words where token == word || token.contains(word) {
                if best == nil || word.count > best!.score {
                    best = (tag, word.count)
                }
            }
        }
        return best?.tag
    }

    // MARK: - Size

    static func mapSize(_ raw: String?, category: Category?) -> SizeOption? {
        guard let raw, !raw.isEmpty else { return nil }
        let normalized = raw
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")

        let apparel: [(SizeOption, [String])] = [
            (.xs, ["xs", "xsmall", "extrasmall"]),
            (.s, ["s", "small"]),
            (.m, ["m", "medium", "med"]),
            (.l, ["l", "large"]),
            (.xl, ["xl", "xlarge", "extralarge"]),
            (.xxl, ["xxl", "2xl", "xxlarge"])
        ]

        if category == .bottom {
            let widths: [(SizeOption, [String])] = [
                (.w28, ["w28", "28"]), (.w30, ["w30", "30"]), (.w32, ["w32", "32"]),
                (.w34, ["w34", "34"]), (.w36, ["w36", "36"]), (.w38, ["w38", "38"]), (.w40, ["w40", "40"])
            ]
            // Prefer exact / prefixed matches over bare digit contains.
            for (size, keys) in widths {
                if keys.contains(where: { normalized == $0 || normalized.hasPrefix($0) || normalized.hasSuffix($0) }) {
                    return size
                }
            }
        }

        if category == .shoes {
            let eu: [(SizeOption, String)] = [
                (.eu39, "39"), (.eu40, "40"), (.eu41, "41"), (.eu42, "42"),
                (.eu43, "43"), (.eu44, "44"), (.eu45, "45"), (.eu46, "46"), (.eu47, "47")
            ]
            for (size, key) in eu {
                if normalized == key || normalized == "eu\(key)" || normalized.hasPrefix("eu\(key)") {
                    return size
                }
            }
        }

        // Exact letter sizes only (avoid "s" inside "xs").
        for (size, keys) in apparel.sorted(by: { $0.1.map(\.count).max()! > $1.1.map(\.count).max()! }) {
            if keys.contains(normalized) { return size }
        }
        return nil
    }

    // MARK: - Materials

    static func mapMaterials(_ raw: String?) -> [MaterialTag] {
        guard let raw, !raw.isEmpty else { return [] }
        let haystack = normalize(raw)
        var result: [MaterialTag] = []
        for tag in MaterialTag.allCases where haystack.contains(tag.rawValue) {
            if !result.contains(tag) {
                result.append(tag)
            }
        }
        return result
    }

    // MARK: - Apparel gate

    /// Rejects non-wardrobe products (candles, food, electronics, etc.) before form fill.
    static func requireApparel(_ product: BarcodeProduct) throws {
        guard isLikelyApparel(
            path: product.categoryPath,
            title: product.title,
            brand: product.brand,
            mappedCategory: product.category
        ) else {
            throw BarcodeLookupError.notApparel
        }
    }

    static func isLikelyApparel(
        path: String?,
        title: String?,
        brand: String? = nil,
        mappedCategory: Category? = nil
    ) -> Bool {
        let haystack = normalize("\(path ?? "") \(title ?? "") \(brand ?? "")")
        guard !haystack.isEmpty else { return false }

        // Explicit non-clothing — deny even if a keyword accidentally scores.
        let denied = [
            "candle", "candles", "wax melt", "incense",
            "perfume", "cologne", "fragrance", "eau de toilette", "eau de parfum",
            "grocery", "food", "snack", "beverage", "soft drink", "energy drink",
            "electronics", "phone case", "charger", "hdmi", "usb-c",
            "toy", "puzzle", "board game", "video game",
            "book", "magazine", "paperback",
            "detergent", "dishwasher", "laundry pod",
            "furniture", "mattress", "home & garden", "home and garden", "household",
            "pet food", "dog treat", "cat litter",
            "vitamin", "supplement", "pharmacy",
            "tool kit", "hardware", "paint can",
            "kitchen", "cookware", "cutlery"
        ]
        if bestScore(haystack, denied) >= 4 { return false }
        // Hebrew common non-apparel
        if haystack.contains("נר ") || haystack.hasSuffix(" נר") || haystack == "נר"
            || haystack.contains("נרות") {
            return false
        }

        if mappedCategory != nil { return true }

        // Mapped category may be nil if we only have a retailer breadcrumb — check allow phrases.
        let allowed = [
            "apparel", "clothing", "garment", "fashion", "ready-to-wear",
            "menswear", "womenswear", "activewear", "sportswear", "footwear",
            "lingerie", "underwear", "hosiery", "outerwear",
            "t-shirt", "tshirt", "tshirts", "shirt", "shirts", "hoodie", "sweater", "jacket", "coat",
            "jean", "trouser", "pant", "shorts", "skirt", "dress",
            "sneaker", "boot", "loafer", "sandal", "heel",
            "scarf", "belt", "handbag", "backpack",
            "טי שרט", "טישרט", "חולצה", "מכנסיים", "נעליים", "מעיל", "גקט"
        ]
        if bestScore(haystack, allowed) >= 4 { return true }

        // Re-run taxonomy on the combined text in case path alone lacked signal.
        if mapCategory(path: path ?? "", title: title) != nil { return true }

        return false
    }

    // MARK: - Scoring helpers

    /// Score = longest matching phrase length. 0 if nothing matches.
    static func bestScore(_ haystack: String, _ phrases: [String]) -> Int {
        let text = normalize(haystack)
        var best = 0
        for phrase in phrases {
            let needle = normalize(phrase)
            guard !needle.isEmpty, text.contains(needle) else { continue }
            best = max(best, needle.count)
        }
        return best
    }

    static func normalize(_ raw: String) -> String {
        raw
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitColorTokens(_ value: String) -> [String] {
        value
            .replacingOccurrences(of: "/", with: ",")
            .replacingOccurrences(of: "&", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
