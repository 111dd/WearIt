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
    var currency: String?
    var available: Bool?
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

/// Who a product is cut for, as the shop labels it.
enum ShopGender: String, CaseIterable, Identifiable {
    case women, men, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .women: return String(localized: "shop_gender_women")
        case .men: return String(localized: "shop_gender_men")
        case .all: return String(localized: "shop_gender_all")
        }
    }

    /// Kids' items never show; unlabeled items show for everyone.
    func includes(_ raw: String?) -> Bool {
        guard raw != "kids" else { return false }
        guard self != .all, let raw else { return true }
        return raw == rawValue
    }
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
    let imageURL: URL?
    /// Sizes the shop has in stock, mapped to the app's sizes (empty when the shop doesn't say).
    let inStockSizes: [SizeOption]
    /// Every size the shop lists, mapped.
    let allSizes: [SizeOption]

    var id: String { item.id }
    var price: Double? { item.price }
    var originalPrice: Double? { item.originalPrice }

    /// Percent off when the shop shows a higher crossed-out price.
    var discountPercent: Int? {
        guard let price, let original = originalPrice, original > price, original > 0 else { return nil }
        let percent = Int(((original - price) / original * 100).rounded())
        return percent >= 5 ? percent : nil
    }

    var priceText: String? {
        guard let price else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = item.currency ?? "ILS"
        formatter.maximumFractionDigits = price.rounded() == price ? 0 : 2
        return formatter.string(from: NSNumber(value: price))
    }

    static func == (lhs: ShopProduct, rhs: ShopProduct) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
final class ShopCatalogService: ObservableObject {
    static let shared = ShopCatalogService()

    /// Pilot: Israel only. Other countries get their own `<country>/catalog.json` later.
    static let country = "IL"
    /// Re-check the catalog at most this often (it is rebuilt nightly).
    private static let refreshInterval: TimeInterval = 6 * 3600

    @Published private(set) var products: [ShopProduct] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private var lastCheck: Date?

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
        if products.isEmpty, let cached = Self.cacheURL, let data = try? Data(contentsOf: cached) {
            products = await Self.decodeAndMap(data)
        }
        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < Self.refreshInterval { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        lastCheck = Date()

        var request = URLRequest(url: Self.remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if !products.isEmpty, let etag = UserDefaults.standard.string(forKey: Self.etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 304 { lastError = nil; return }
            guard http.statusCode == 200 else {
                lastError = "HTTP \(http.statusCode)"
                return
            }
            let mapped = await Self.decodeAndMap(data)
            guard !mapped.isEmpty else { return }
            products = mapped
            lastError = nil
            if let cached = Self.cacheURL { try? data.write(to: cached, options: .atomic) }
            UserDefaults.standard.set(http.value(forHTTPHeaderField: "ETag"), forKey: Self.etagKey)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Decoding a few MB of JSON and running the mapper over thousands of titles stays off the main thread.
    nonisolated private static func decodeAndMap(_ data: Data) async -> [ShopProduct] {
        await Task.detached(priority: .utility) {
            guard let catalog = try? JSONDecoder().decode(ShopCatalog.self, from: data) else { return [] }
            let storeNames = Dictionary(catalog.stores.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            return catalog.items.compactMap { ShopCatalogService.map($0, storeName: storeNames[$0.store] ?? $0.store) }
        }.value
    }

    nonisolated static func map(_ item: ShopCatalogItem, storeName: String) -> ShopProduct? {
        guard item.available != false,
              let url = URL(string: item.url),
              let title = item.title, !title.isEmpty else { return nil }
        let imageURLs = (item.images ?? []).compactMap(URL.init(string:))
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
        guard let category = product.category else { return nil }
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
            itemType: product.itemType,
            colors: product.colors,
            materials: product.materials,
            fit: product.fit,
            pattern: product.pattern,
            imageURL: imageURLs.first,
            inStockSizes: mapSizes(item.inStockSizes),
            allSizes: mapSizes(item.sizes)
        )
    }
}
