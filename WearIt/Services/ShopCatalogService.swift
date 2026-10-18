//
//  ShopCatalogService.swift
//  WearIt
//
//  Downloads the nightly shop catalog (built by scripts/catalog/build_catalog.py and published on
//  the repo's `catalog-data` branch) and maps each product to the app's taxonomy through
//  `ProductPageMetadataService.makeProduct`, the same path a pasted product link takes.
//  The wardrobe never leaves the device: ranking happens in `PurchaseScorer`.
//

import Foundation

/// One product exactly as the catalog stores it (raw shop fields).
struct ShopCatalogItem: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let store: String
    let url: String
    var title: String?
    var brand: String?
    var description: String?
    var color: String?
    var material: String?
    var categoryPath: String?
    var gender: String?
    var sizes: [String]?
    var inStockSizes: [String]?
    var images: [String]?
    var price: Double?
    var originalPrice: Double?
    /// Only newer crawls establish that the crossed-out price belongs to the same offer/variant.
    var originalPriceVerified: Bool?
    var currency: String?
    var available: Bool?
    /// The product's own fetch time; the catalog can be republished without refreshing this item.
    var fetchedAt: String?
    /// Optional in older catalogs. An empty size list does not establish that every size is sold out.
    var sizeAvailabilityKnown: Bool?
}

struct ShopCatalog: Codable, Sendable {
    struct Store: Codable, Hashable, Sendable {
        let id: String
        let name: String
        let base: String?
    }

    let version: Int
    let country: String
    let generatedAt: String
    let stores: [Store]
    let items: [ShopCatalogItem]
}

/// A catalog product mapped to WearIt's taxonomy.
struct ShopProduct: Identifiable, Hashable, Sendable {
    let item: ShopCatalogItem
    let storeName: String
    let url: URL
    let title: String
    let category: Category
    let itemType: ItemType?
    let colors: [ColorTag]
    let materials: [MaterialTag]
    let fit: FitTag?
    let pattern: PatternTag?
    let styleTags: [StyleTag]
    /// Retailer metadata only; photographed people never establish a product's department.
    let audience: ShopAudience
    let imageURL: URL?
    /// Sizes the shop has in stock, mapped to the app's sizes (empty when the shop doesn't say).
    let inStockSizes: [SizeOption]
    /// Every size the shop lists, mapped.
    let allSizes: [SizeOption]
    let fetchedAt: Date?

    var id: String { item.id }
    var price: Double? { item.price.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
    var originalPrice: Double? { item.originalPrice.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }

    var hasKnownSizeAvailability: Bool {
        guard item.sizeAvailabilityKnown != false, let raw = item.inStockSizes else { return false }
        if raw.isEmpty { return item.sizeAvailabilityKnown == true }
        // "One size", US shoes and other unsupported scales are unknown, not sold out.
        // A partially mapped list also cannot rule out the user's usual size.
        return raw.allSatisfy { ProductFieldMapper.mapSize($0, category: category) != nil }
    }

    /// A recently republished catalog is not evidence of a recently checked offer.
    var hasRecentOffer: Bool {
        guard let fetchedAt else { return false }
        let age = Date().timeIntervalSince(fetchedAt)
        return age >= -3600 && age <= 7 * 24 * 3600
    }

    /// Percent off when the shop shows a higher crossed-out price.
    var discountPercent: Int? {
        guard item.originalPriceVerified == true, hasRecentOffer,
              let price, let original = originalPrice, original > price else { return nil }
        let percent = Int(((original - price) / original * 100).rounded())
        return percent >= 5 ? percent : nil
    }

    var priceText: String? {
        formattedPrice(price)
    }

    var originalPriceText: String? {
        guard discountPercent != nil else { return nil }
        return formattedPrice(originalPrice)
    }

    private func formattedPrice(_ amount: Double?) -> String? {
        guard let amount else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = item.currency ?? "ILS"
        formatter.maximumFractionDigits = amount.rounded() == amount ? 0 : 2
        return formatter.string(from: NSNumber(value: amount))
    }

    static func == (lhs: ShopProduct, rhs: ShopProduct) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
final class ShopCatalogService: ObservableObject {
    static let shared = ShopCatalogService()

    /// Pilot: Israel only. Other countries get their own `<country>/catalog.json` later.
    nonisolated static let country = "IL"
    /// Re-check the catalog at most this often (it is rebuilt nightly).
    private static let refreshInterval: TimeInterval = 6 * 3600
    private static let retryInterval: TimeInterval = 5 * 60

    @Published private(set) var products: [ShopProduct] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var catalogGeneratedAt: Date?
    /// Count alone misses price, stock and preference-relevant metadata changes.
    @Published private(set) var revision = 0

    private var lastCheck: Date?
    private var lastSuccess: Date?
    private var didLoadCache = false

    private init() {}

    private static var remoteURL: URL {
        URL(string: "https://raw.githubusercontent.com/111dd/WearIt/catalog-data/\(country.lowercased())/catalog.json")!
    }

    private static var cacheURL: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("ShopCatalog", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(country.lowercased()).json")
    }

    private static let etagKey = "shopCatalog.etag"

    /// Loads the cached catalog right away, then refreshes from the network when it's due.
    func refreshIfNeeded(force: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if !didLoadCache {
            didLoadCache = true
            if let cached = Self.cacheURL,
               let data = try? Data(contentsOf: cached),
               let decoded = try? await Self.decodeAndMap(data) {
                apply(decoded)
            }
        }
        if !force {
            if let lastSuccess, Date().timeIntervalSince(lastSuccess) < Self.refreshInterval { return }
            if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.retryInterval { return }
        }
        lastCheck = Date()

        var request = URLRequest(url: Self.remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if !products.isEmpty, let etag = UserDefaults.standard.string(forKey: Self.etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 304 {
                lastError = nil
                lastSuccess = Date()
                return
            }
            guard http.statusCode == 200 else {
                lastError = "HTTP \(http.statusCode)"
                return
            }
            let decoded = try await Self.decodeAndMap(data)
            apply(decoded)
            lastError = nil
            lastSuccess = Date()
            if let cached = Self.cacheURL { try? data.write(to: cached, options: .atomic) }
            UserDefaults.standard.set(http.value(forHTTPHeaderField: "ETag"), forKey: Self.etagKey)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func apply(_ catalog: MappedCatalog) {
        products = catalog.products
        catalogGeneratedAt = catalog.generatedAt
        revision += 1
    }

    private struct MappedCatalog: Sendable {
        let products: [ShopProduct]
        let generatedAt: Date?
    }

    /// Decoding a few MB of JSON and running the mapper over thousands of titles stays off the main thread.
    nonisolated private static func decodeAndMap(_ data: Data) async throws -> MappedCatalog {
        try await Task.detached(priority: .utility) {
            let catalog = try JSONDecoder().decode(ShopCatalog.self, from: data)
            guard catalog.version == 1, catalog.country.uppercased() == country else {
                throw URLError(.cannotParseResponse)
            }
            let storeNames = Dictionary(catalog.stores.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            var seen = Set<String>()
            let products = catalog.items.compactMap { item -> ShopProduct? in
                guard seen.insert(item.id).inserted else { return nil }
                return ShopCatalogService.map(item, storeName: storeNames[item.store] ?? item.store)
            }
            return MappedCatalog(products: products, generatedAt: catalogDate(catalog.generatedAt))
        }.value
    }

    nonisolated static func catalogDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: raw)
    }

    nonisolated static func map(_ item: ShopCatalogItem, storeName: String) -> ShopProduct? {
        guard item.available != false,
              let url = URL(string: item.url),
              isWebURL(url),
              let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              !isChildrensItem(item, title: title), !isNonWearable(title) else { return nil }
        let imageURLs = (item.images ?? []).compactMap(URL.init(string:)).filter(isWebURL)
        let product = ProductPageMetadataService.makeProduct(
            title: title,
            brand: item.brand,
            color: item.color,
            size: nil,
            material: item.material,
            categoryPath: [item.categoryPath, item.gender].compactMap { $0 }.joined(separator: " "),
            imageURLs: imageURLs,
            description: item.description,
            barcodeOverride: item.id,
            sourceURL: url
        )
        // Without a category there is nothing to compare against the wardrobe.
        // Broad store navigation can include several departments; the item's own title wins.
        guard let category = ProductFieldMapper.mapCategory(path: "", title: title) ?? product.category else { return nil }
        let itemType = ProductFieldMapper.mapItemType(path: "", title: title, category: category)
            ?? product.itemType.flatMap { category.itemTypes.contains($0) ? $0 : nil }
        let explicitStyles = ProductFieldMapper.mapStyles([title, item.description, item.categoryPath].compactMap { $0 }.joined(separator: " "))
        let styleTags = explicitStyles.isEmpty
            ? (itemType.flatMap { ItemTypeDefaults.defaults(for: $0)?.styleTags } ?? [])
            : explicitStyles
        func mapSizes(_ raw: [String]?) -> [SizeOption] {
            var seen = Set<SizeOption>()
            return (raw ?? []).compactMap { ProductFieldMapper.mapSize($0, category: category) }
                .filter { seen.insert($0).inserted }
        }
        return ShopProduct(
            item: item,
            storeName: storeName,
            url: url,
            title: product.title ?? title,
            category: category,
            itemType: itemType,
            colors: product.colors,
            materials: product.materials,
            fit: product.fit,
            pattern: product.pattern,
            styleTags: styleTags,
            audience: classifyAudience(item, title: title, url: url),
            imageURL: imageURLs.first,
            inStockSizes: mapSizes(item.inStockSizes),
            allSizes: mapSizes(item.sizes),
            fetchedAt: catalogDate(item.fetchedAt)
        )
    }

    nonisolated private static func isWebURL(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    nonisolated private static func classifyAudience(_ item: ShopCatalogItem, title: String, url: URL) -> ShopAudience {
        func evidence(_ raw: String?) -> Set<ShopAudience> {
            guard let raw else { return [] }
            let value = (raw.removingPercentEncoding ?? raw)
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .replacingOccurrences(of: "’", with: "'")
            let patterns: [(ShopAudience, String)] = [
                (.men, #"\b(men(?:'s|s)?|man|male|menswear|homme)\b|(?:^|[^\p{L}])(?:גברים|לגברים|לגבר|גבר)(?:$|[^\p{L}])"#),
                (.women, #"\b(women(?:'s|s)?|woman|female|ladies|womenswear|femme)\b|(?:^|[^\p{L}])(?:נשים|לנשים|אישה|לאישה)(?:$|[^\p{L}])"#),
                (.unisex, #"\b(unisex|gender[ -]?neutral|genderless)\b|(?:^|[^\p{L}])יוניסקס(?:$|[^\p{L}])"#),
                (.children, #"\b(kids?|children|boys?|girls?|bab(y|ies)|junior|toddler|youth)\b|ילדים|ילדות|תינוק|בנים|בנות|נוער"#)
            ]
            return Set(patterns.compactMap { audience, pattern in
                value.range(of: pattern, options: .regularExpression) == nil ? nil : audience
            })
        }

        let explicit = evidence(item.gender)
        // A malformed explicit label is not repaired by picking the first matching department.
        if explicit.count > 1 { return .unknown }
        var inferred = evidence(title).union(evidence(url.path))
        let breadcrumbs = (item.categoryPath ?? "").components(separatedBy: CharacterSet(charactersIn: ">/|"))
        for breadcrumb in breadcrumbs {
            let departments = evidence(breadcrumb)
            // Broad "Women / Men / Kids" navigation is not item-specific evidence.
            if departments.count == 1 { inferred.formUnion(departments) }
        }
        let combined = explicit.union(inferred)
        guard combined.count == 1, let audience = combined.first else { return .unknown }
        return audience
    }

    nonisolated private static func isChildrensItem(_ item: ShopCatalogItem, title: String) -> Bool {
        let labels = [item.gender, item.categoryPath, title, URL(string: item.url)?.path.removingPercentEncoding]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        return labels.range(
            of: #"\b(kids?|children|boys?|girls?|bab(y|ies)|junior|toddler|youth)\b|ילדים|ילדות|תינוק|בנים|בנות|נוער"#,
            options: .regularExpression
        ) != nil
    }

    nonisolated private static func isNonWearable(_ title: String) -> Bool {
        title.lowercased().range(
            of: #"\b(gift card|perfume|fragrance|cosmetics?|makeup|shampoo|conditioner|candle|phone case|airpods case|water bottle|bedding|towel|shoe cleaner|shoe care)\b|בושם|בשמים|קוסמטיקה|איפור|שמפו|מרכך שיער|מצעים|מגבת|מגבות|בקבוק שתיה|כיסוי לטלפון|גיפט קארד"#,
            options: .regularExpression
        ) != nil
    }
}
