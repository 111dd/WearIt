import Foundation

/// A product department, not a declaration of the user's gender.
enum ShopDepartment: String, Codable, CaseIterable, Identifiable {
    case automatic, men, women, all
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return String(localized: "shop_department_automatic")
        case .men: return String(localized: "shop_department_men")
        case .women: return String(localized: "shop_department_women")
        case .all: return String(localized: "shop_department_all")
        }
    }

    func includes(_ audience: ShopAudience, category: Category) -> Bool {
        guard audience != .children else { return false }
        if self == .all { return true }
        if audience == .unisex { return true }
        // An unlabeled bag/watch is useful across departments. Unlabeled clothing is
        // uncertain and cannot silently bypass an explicitly selected department.
        if audience == .unknown { return category == .accessory }
        return (self == .men && audience == .men) || (self == .women && audience == .women)
    }
}

enum ShopAudience: String, Sendable {
    case men, women, unisex, unknown, children
}

struct ShoppingPreferences: Codable, Equatable {
    var department: ShopDepartment = .automatic
    var preferredColors: [ColorTag] = []
    var preferredBrands: [String] = []
    var preferredStyles: [StyleTag] = []
    var preferProductOnlyPhotos = true

    private enum CodingKeys: String, CodingKey {
        case department, preferredColors, preferredBrands, preferredStyles, preferProductOnlyPhotos
    }

    /// General browsing honors deliberate filters, independently of wardrobe relevance.
    func allows(product: ShopProduct) -> Bool {
        guard department.includes(product.audience, category: product.category) else { return false }
        if !preferredColors.isEmpty && Set(preferredColors).isDisjoint(with: product.colors) { return false }
        if !preferredBrands.isEmpty {
            let wanted = Set(preferredBrands.map(BrandStore.normalizeBrandKey))
            guard let brand = product.item.brand, wanted.contains(BrandStore.normalizeBrandKey(brand)) else { return false }
        }
        if !preferredStyles.isEmpty {
            guard !Set(preferredStyles).isDisjoint(with: product.styleTags) else { return false }
        }
        return true
    }

    struct DepartmentResolution {
        /// nil means there is no trustworthy answer yet, not a request for mixed departments.
        var department: ShopDepartment?
        var needsChoice: Bool { department == nil }
    }

    @MainActor
    static func resolvedDepartment(profile: UserProfile?, garments: [Garment], feedback: ShopFeedbackStore,
                                   products: [ShopProduct] = []) -> DepartmentResolution {
        let preferences = profile?.shoppingPreferences ?? ShoppingPreferences()
        if preferences.department != .automatic { return DepartmentResolution(department: preferences.department) }
        // A previous explicit department choice is evidence; the former default "all" is not.
        // Once the new settings have been saved, an explicit Automatic choice must win too.
        if profile?.shoppingPreferencesRaw == nil,
           let previous = UserDefaults.standard.string(forKey: "shop.gender"),
           let choice = ShopDepartment(rawValue: previous), choice == .men || choice == .women {
            return DepartmentResolution(department: choice)
        }
        var mass: [ShopAudience: Double] = [:]
        var counts: [ShopAudience: Int] = [:]
        var evidenceIDs = Set<String>()
        for (id, actions) in feedback.state.actions {
            guard actions[.bought] != nil,
                  let item = feedback.state.keptItems[id],
                  let product = ShopCatalogService.map(item, storeName: item.store),
                  product.category != .accessory, product.audience == .men || product.audience == .women,
                  evidenceIDs.insert(product.id).inserted else { continue }
            mass[product.audience, default: 0] += 3
            counts[product.audience, default: 0] += 1
        }
        // Only explicitly sourced retailer metadata can connect owned pieces to a department.
        // Names, profile photos, colors, sizes and generic style tags never choose it.
        let sources = garments.filter { !$0.isBlocked && $0.category != .accessory
            && ($0.ownerID == nil || $0.ownerID == profile?.id) }
            .map { Set($0.photoMetadata.values.compactMap(\.sourceURL)) }.filter { !$0.isEmpty }
        // Most closets have no retailer source links. Avoid indexing thousands of products then.
        let productByURL = sources.isEmpty ? [:] : Dictionary(products.map { (sourceKey($0.url), $0) }, uniquingKeysWith: { first, _ in first })
        for urls in sources {
            let linked = urls.compactMap { raw -> ShopProduct? in
                guard let url = URL(string: raw), let product = productByURL[sourceKey(url)],
                      product.audience == .men || product.audience == .women else { return nil }
                return product
            }
            let audiences = Set(linked.map(\.audience))
            if audiences.count == 1, let product = linked.first, evidenceIDs.insert(product.id).inserted {
                mass[product.audience, default: 0] += 1
                counts[product.audience, default: 0] += 1
            }
        }
        let total = mass.values.reduce(0, +)
        if let best = mass.max(by: { $0.value < $1.value }), best.value >= 3, (counts[best.key] ?? 0) >= 2,
           total > 0, best.value / total >= 0.8 {
            return DepartmentResolution(department: best.key == .men ? .men : .women)
        }
        return DepartmentResolution(department: nil)
    }

    private static func sourceKey(_ url: URL) -> String {
        (url.host?.lowercased() ?? "") + "/" + url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }
}

extension ShoppingPreferences {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try values.decodeIfPresent(String.self, forKey: .department)
        department = raw.flatMap(ShopDepartment.init(rawValue:)) ?? .automatic
        preferredColors = try values.decodeIfPresent([ColorTag].self, forKey: .preferredColors) ?? []
        preferredBrands = try values.decodeIfPresent([String].self, forKey: .preferredBrands) ?? []
        preferredStyles = try values.decodeIfPresent([StyleTag].self, forKey: .preferredStyles) ?? []
        preferProductOnlyPhotos = try values.decodeIfPresent(Bool.self, forKey: .preferProductOnlyPhotos) ?? true
    }
}

extension UserProfile {
    var shoppingPreferences: ShoppingPreferences {
        get {
            guard let raw = shoppingPreferencesRaw, let data = raw.data(using: .utf8),
                  let value = try? JSONDecoder().decode(ShoppingPreferences.self, from: data) else { return ShoppingPreferences() }
            return value
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue), let raw = String(data: data, encoding: .utf8) else { return }
            shoppingPreferencesRaw = raw
        }
    }
}
