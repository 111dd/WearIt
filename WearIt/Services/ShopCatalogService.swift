//
//  ShopCatalogService.swift
//  WearIt
//
//  Downloads the nightly shop catalog (built by scripts/catalog/build_catalog.py and published on
//  the repo's `catalog-data` branch) and maps each product to the app's taxonomy through
//  `ProductPageMetadataService.makeProduct`, the same path a pasted product link takes.
//  The catalog is an index plus several small files; only files whose content changed are
//  downloaded again, and they are decoded one at a time.
//  The wardrobe never leaves the device: ranking happens in `PurchaseScorer`.
//

import CryptoKit
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

/// The list of catalog files for one country (`index.json`, version 2).
struct ShopCatalogIndex: Codable, Sendable {
    struct Shard: Codable, Hashable, Sendable {
        /// Relative to the country folder, e.g. `shards/castro-men-0.json`.
        let path: String
        /// First 16 hex digits of the file's SHA-1; a changed file has a new hash.
        let hash: String
        var store: String?
        var audience: String?
        var items: Int?
    }

    let version: Int
    let country: String
    let generatedAt: String
    let stores: [ShopCatalog.Store]
    let shards: [Shard]
}

/// One catalog file named by the index.
struct ShopCatalogShardFile: Codable, Sendable {
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
        // A reliable before/after comparison is useful even below the 5% deal threshold.
        guard item.originalPriceVerified == true, hasRecentOffer,
              let price, let original = originalPrice, original > price else { return nil }
        return formattedPrice(original)
    }

    private func formattedPrice(_ amount: Double?) -> String? {
        guard let amount else { return nil }
        return amount.formatted(.currency(code: item.currency ?? "ILS").precision(.fractionLength(amount.rounded() == amount ? 0 : 2)))
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

    nonisolated private static var countryFolderURL: URL {
        URL(string: "https://raw.githubusercontent.com/111dd/WearIt/catalog-data/\(country.lowercased())/")!
    }

    /// The single-file catalog, still published for app versions that predate the index.
    private static var remoteURL: URL { countryFolderURL.appendingPathComponent("catalog.json") }

    private static let etagKey = "shopCatalog.etag"
    private static let indexEtagKey = "shopCatalog.indexEtag"

    private struct HTTPStatusError: LocalizedError {
        let code: Int
        var errorDescription: String? { "HTTP \(code)" }
    }

    private enum IndexRefresh: Sendable {
        case unchanged
        /// The crawler has not published an index yet; the single file is the catalog.
        case notPublished
        case loaded(MappedCatalog, etag: String?)
    }

    /// Loads the cached catalog right away, then refreshes from the network when it's due.
    func refreshIfNeeded(force: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if !didLoadCache {
            didLoadCache = true
            if let cached = await Self.loadCachedCatalog() { apply(cached) }
        }
        if !force {
            if let lastSuccess, Date().timeIntervalSince(lastSuccess) < Self.refreshInterval { return }
            if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.retryInterval { return }
        }
        lastCheck = Date()

        do {
            let etag = products.isEmpty ? nil : UserDefaults.standard.string(forKey: Self.indexEtagKey)
            switch try await Self.fetchIndexedCatalog(etag: etag) {
            case .unchanged:
                break
            case .loaded(let catalog, let newEtag):
                apply(catalog)
                UserDefaults.standard.set(newEtag, forKey: Self.indexEtagKey)
                UserDefaults.standard.removeObject(forKey: Self.etagKey)
            case .notPublished:
                try await refreshSingleFile()
            }
            lastError = nil
            lastSuccess = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshSingleFile() async throws {
        var request = URLRequest(url: Self.remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if !products.isEmpty, let etag = UserDefaults.standard.string(forKey: Self.etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 304 { return }
        guard http.statusCode == 200 else { throw HTTPStatusError(code: http.statusCode) }
        let decoded = try await Self.decodeAndMap(data)
        apply(decoded)
        await Self.writeCachedData(data)
        UserDefaults.standard.set(http.value(forHTTPHeaderField: "ETag"), forKey: Self.etagKey)
    }

    // MARK: - Index and files

    nonisolated private static let indexCacheName = "\(country.lowercased())-index.json"

    nonisolated private static func fetchIndexedCatalog(etag: String?) async throws -> IndexRefresh {
        var request = URLRequest(url: countryFolderURL.appendingPathComponent("index.json"),
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 304 { return .unchanged }
        if http.statusCode == 404 { return .notPublished }
        guard http.statusCode == 200 else { throw HTTPStatusError(code: http.statusCode) }
        let index = try decodeIndex(data)
        let catalog = try await loadShards(index, download: true)
        // Every file of this index is on disk now; older files and the single-file cache can go.
        let keep = Set(index.shards.compactMap(cacheName) + [indexCacheName])
        await Task.detached(priority: .utility) {
            guard let folder = cacheFolder else { return }
            try? data.write(to: folder.appendingPathComponent(indexCacheName), options: .atomic)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(name) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }.value
        return .loaded(catalog, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    nonisolated private static func decodeIndex(_ data: Data) throws -> ShopCatalogIndex {
        let index = try JSONDecoder().decode(ShopCatalogIndex.self, from: data)
        guard index.version == 2, index.country.uppercased() == country, !index.shards.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        return index
    }

    /// The cached index and its files, or the single-file cache from before the index existed.
    nonisolated private static func loadCachedCatalog() async -> MappedCatalog? {
        let cachedIndex = await Task.detached(priority: .utility) { () -> ShopCatalogIndex? in
            guard let folder = cacheFolder,
                  let data = try? Data(contentsOf: folder.appendingPathComponent(indexCacheName)) else { return nil }
            return try? decodeIndex(data)
        }.value
        if let cachedIndex, let catalog = try? await loadShards(cachedIndex, download: false) { return catalog }
        guard let data = await readCachedData() else { return nil }
        return try? await decodeAndMap(data)
    }

    /// Decodes one file at a time, so memory stays bounded however large the catalog grows.
    nonisolated private static func loadShards(_ index: ShopCatalogIndex, download: Bool) async throws -> MappedCatalog {
        try await Task.detached(priority: .utility) {
            let storeNames = Dictionary(index.stores.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            var seen = Set<String>()
            var products: [ShopProduct] = []
            for shard in index.shards {
                let data = try await shardData(shard, download: download)
                let items = try JSONDecoder().decode(ShopCatalogShardFile.self, from: data).items
                for item in items where seen.insert(item.id).inserted {
                    if let product = map(item, storeName: storeNames[item.store] ?? item.store) {
                        products.append(product)
                    }
                }
            }
            return MappedCatalog(products: products, generatedAt: catalogDate(index.generatedAt))
        }.value
    }

    /// The hash is part of the cached name, so a file on disk always matches its index entry.
    nonisolated private static func cacheName(_ shard: ShopCatalogIndex.Shard) -> String? {
        guard shard.hash.range(of: "^[0-9a-f]{8,64}$", options: .regularExpression) != nil,
              shard.path.range(of: "^[A-Za-z0-9_/-]+\\.json$", options: .regularExpression) != nil else { return nil }
        return "\(country.lowercased())-\(shard.hash)-\(shard.path.replacingOccurrences(of: "/", with: "-"))"
    }

    nonisolated private static func shardData(_ shard: ShopCatalogIndex.Shard, download: Bool) async throws -> Data {
        guard let name = cacheName(shard) else { throw URLError(.cannotParseResponse) }
        let file = cacheFolder?.appendingPathComponent(name)
        if let file, let cached = try? Data(contentsOf: file) { return cached }
        guard download else { throw URLError(.resourceUnavailable) }
        let request = URLRequest(url: countryFolderURL.appendingPathComponent(shard.path),
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { throw HTTPStatusError(code: http.statusCode) }
        // The index and its files are published together, but the CDN can briefly serve an
        // older copy of one of them. A mismatch fails this refresh; the next one retries.
        let digest = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest.hasPrefix(shard.hash) else { throw URLError(.cannotParseResponse) }
        if let file { try? data.write(to: file, options: .atomic) }
        return data
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

    /// Resolve/create the cache directory only inside the disk workers.
    nonisolated private static var cacheFolder: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("ShopCatalog", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The single-file catalog's cache.
    nonisolated private static var cacheURL: URL? {
        cacheFolder?.appendingPathComponent("\(country.lowercased()).json")
    }

    nonisolated private static func readCachedData() async -> Data? {
        await Task.detached(priority: .utility) { () -> Data? in
            guard let cached = cacheURL else { return nil }
            return try? Data(contentsOf: cached)
        }.value
    }

    nonisolated private static func writeCachedData(_ data: Data) async {
        await Task.detached(priority: .utility) {
            guard let cached = cacheURL else { return }
            try? data.write(to: cached, options: .atomic)
        }.value
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
                (.children, childrenPattern)
            ]
            return Set(patterns.compactMap { audience, pattern in
                value.range(of: pattern, options: .regularExpression) == nil ? nil : audience
            })
        }

        let explicit = evidence(item.gender)
        // A malformed explicit label is not repaired by picking the first matching department.
        if explicit.count > 1 { return .unknown }
        var inferred = evidence(title).union(evidence(url.path))
        // The retailer's label, the title and the URL describe this product. Terminal X's category
        // field also lists every collection it appears in ("BEST OF WOMEN" on a men's item,
        // a kids' collection on adult sneakers); that list only helps when nothing else is known.
        let specific = explicit.union(inferred)
        if specific.count == 1, let audience = specific.first { return audience }
        if specific.count > 1 { return .unknown }
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

    /// Hebrew needs explicit word edges: "אבנים" (stones) and "לבנות" (white) contain "בנים"/"בנות".
    /// scripts/catalog/build_catalog.py uses the same rule (KIDS_PATTERN, unusable_reason).
    nonisolated private static let childrenPattern =
        #"\b(kids?|children|boys?|girls?|bab(y|ies)|junior|toddler|youth)\b|(?<![א-ת])(?:ל?ילדים|ל?ילדות|ל?תינוק(?:ות)?|ל?נוער|בנים|בנות)(?![א-ת])"#

    nonisolated private static func isChildrensItem(_ item: ShopCatalogItem, title: String) -> Bool {
        func mentionsChildren(_ raw: String?) -> Bool {
            raw?.lowercased().range(of: childrenPattern, options: .regularExpression) != nil
        }
        if mentionsChildren(item.gender) || mentionsChildren(title)
            || mentionsChildren(URL(string: item.url)?.path.removingPercentEncoding) { return true }
        // Terminal X also lists adult shoes and bags in kids' collections, so that list
        // decides only for products the retailer did not label for adults.
        let adultLabels: Set<String> = ["men", "women", "unisex"]
        return !adultLabels.contains(item.gender?.lowercased() ?? "") && mentionsChildren(item.categoryPath)
    }

    nonisolated private static func isNonWearable(_ title: String) -> Bool {
        title.lowercased().range(
            of: #"\b(gift card|perfume|fragrance|cosmetics?|makeup|shampoo|conditioner|candle|phone case|airpods case|water bottle|bedding|towel|shoe cleaner|shoe care)\b|בושם|בשמים|קוסמטיקה|איפור|שמפו|מרכך שיער|מצעים|מגבת|מגבות|בקבוק שתיה|כיסוי לטלפון|גיפט קארד"#,
            options: .regularExpression
        ) != nil
    }
}
