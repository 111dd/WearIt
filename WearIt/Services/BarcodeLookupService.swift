import Foundation
import UIKit

struct BarcodeProduct: Equatable {
    let barcode: String
    let title: String?
    let brand: String?
    let category: Category?
    let itemType: ItemType?
    let colors: [ColorTag]
    let size: SizeOption?
    let imageURL: URL?
    let categoryPath: String?
    let materials: [MaterialTag]

    init(
        barcode: String,
        title: String?,
        brand: String?,
        category: Category?,
        itemType: ItemType?,
        colors: [ColorTag],
        size: SizeOption?,
        imageURL: URL?,
        categoryPath: String?,
        materials: [MaterialTag] = []
    ) {
        self.barcode = barcode
        self.title = title
        self.brand = brand
        self.category = category
        self.itemType = itemType
        self.colors = colors
        self.size = size
        self.imageURL = imageURL
        self.categoryPath = categoryPath
        self.materials = materials
    }
}

enum BarcodeLookupError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case notFound
    case unsupportedCode
    case unauthorized
    case httpStatus(Int)
    case decodingFailed
    case imageDownloadFailed
    case notApparel

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return String(localized: "barcode_error_missing_key")
        case .invalidURL:
            return String(localized: "barcode_error_invalid_url")
        case .notFound:
            return String(localized: "barcode_error_not_found")
        case .unsupportedCode:
            return String(localized: "barcode_error_unsupported_code")
        case .unauthorized:
            return String(localized: "barcode_error_unauthorized")
        case .httpStatus(let code):
            return String(format: NSLocalizedString("barcode_error_http_format", comment: ""), code)
        case .decodingFailed:
            return String(localized: "barcode_error_decoding")
        case .imageDownloadFailed:
            return String(localized: "barcode_error_image")
        case .notApparel:
            return String(localized: "barcode_error_not_apparel")
        }
    }
}

enum BarcodeLookupService {
    private static let baseURL = "https://api.barcodelookup.com/v3/products"

    /// Injected via Info.plist from the `BARCODE_LOOKUP_API_KEY` build setting
    /// (Config/Secrets.xcconfig). No bundled fallback — a missing key surfaces
    /// as `BarcodeLookupError.missingAPIKey` instead of shipping a secret.
    private static var apiKey: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "BarcodeLookupAPIKey") as? String else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unresolved build-setting placeholder means the xcconfig wasn't picked up.
        guard !key.isEmpty, !key.hasPrefix("$(") else { return nil }
        return key
    }

    static func lookup(barcode rawCode: String) async throws -> BarcodeProduct {
        let code = try normalizeScannedCode(rawCode)
        guard let apiKey, !apiKey.isEmpty else { throw BarcodeLookupError.missingAPIKey }

        var components = URLComponents(string: baseURL)
        components?.queryItems = [
            URLQueryItem(name: "barcode", value: code),
            URLQueryItem(name: "key", value: apiKey)
        ]
        guard let url = components?.url else { throw BarcodeLookupError.invalidURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw BarcodeLookupError.decodingFailed }
        if http.statusCode == 404 {
            throw BarcodeLookupError.notFound
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw BarcodeLookupError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BarcodeLookupError.httpStatus(http.statusCode)
        }

        let decoded: APIResponse
        do {
            decoded = try JSONDecoder().decode(APIResponse.self, from: data)
        } catch {
            throw BarcodeLookupError.decodingFailed
        }

        guard let product = decoded.products.first else {
            throw BarcodeLookupError.notFound
        }
        return map(product, scannedBarcode: code)
    }

    /// Accepts EAN/UPC digits. For QR payloads, extracts an embedded GTIN when possible;
    /// plain website QR links are rejected with a clear error (API only accepts product codes).
    static func normalizeScannedCode(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BarcodeLookupError.notFound }

        let digitOnly = trimmed.filter(\.isNumber)
        if trimmed.allSatisfy({ $0.isNumber }) && (8...14).contains(digitOnly.count) {
            return digitOnly
        }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            if let extracted = extractProductCode(from: url) {
                return extracted
            }
            throw BarcodeLookupError.unsupportedCode
        }

        if let embedded = firstProductCode(in: trimmed) {
            return embedded
        }

        throw BarcodeLookupError.unsupportedCode
    }

    private static func extractProductCode(from url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let preferredKeys = ["gtin", "ean", "upc", "barcode", "sku"]
        for key in preferredKeys {
            if let value = items.first(where: { $0.name.lowercased() == key })?.value,
               let code = normalizeDigits(value) {
                return code
            }
        }
        // Do NOT scrape arbitrary digits from the path — fashion URLs often contain
        // IDs that look like GTINs and would hijack QR page-metadata fallback.
        return nil
    }

    /// Explicit gtin/ean/upc/barcode/sku query param only (used before page scrape).
    static func explicitProductCode(fromURL url: URL) -> String? {
        extractProductCode(from: url)
    }

    private static func firstProductCode(in text: String) -> String? {
        let digits = text.filter(\.isNumber)
        // Prefer EAN-13, then UPC-A (12), then EAN-8.
        for length in [13, 12, 14, 8] {
            if digits.count >= length {
                let start = digits.index(digits.startIndex, offsetBy: digits.count - length)
                let candidate = String(digits[start...])
                if let code = normalizeDigits(candidate) { return code }
            }
        }
        return normalizeDigits(digits)
    }

    private static func normalizeDigits(_ value: String) -> String? {
        let digits = value.filter(\.isNumber)
        guard (8...14).contains(digits.count) else { return nil }
        return digits
    }

    static func downloadImage(from url: URL) async throws -> UIImage {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BarcodeLookupError.imageDownloadFailed
        }
        guard let image = UIImage(data: data) else {
            throw BarcodeLookupError.imageDownloadFailed
        }
        return image
    }

    // MARK: - Mapping

    private static func map(_ product: APIProduct, scannedBarcode: String) -> BarcodeProduct {
        let path = product.category ?? ""
        let title = product.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let brand = product.brand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mappedCategory = ProductFieldMapper.mapCategory(path: path, title: title)
        let mappedType = ProductFieldMapper.mapItemType(path: path, title: title, category: mappedCategory)
        let colors = ProductFieldMapper.mapColors(colorField: product.color, title: title)
        let size = ProductFieldMapper.mapSize(product.size, category: mappedCategory)
        let imageURL = product.images?
            .compactMap { URL(string: $0) }
            .first

        return BarcodeProduct(
            barcode: product.barcodeNumber ?? scannedBarcode,
            title: title?.isEmpty == false ? title : nil,
            brand: brand?.isEmpty == false ? brand : nil,
            category: mappedCategory,
            itemType: mappedType,
            colors: colors,
            size: size,
            imageURL: imageURL,
            categoryPath: path.isEmpty ? nil : path,
            materials: []
        )
    }
}

// MARK: - API DTOs

private struct APIResponse: Decodable {
    let products: [APIProduct]
}

private struct APIProduct: Decodable {
    let barcodeNumber: String?
    let title: String?
    let brand: String?
    let category: String?
    let color: String?
    let size: String?
    let images: [String]?

    enum CodingKeys: String, CodingKey {
        case barcodeNumber = "barcode_number"
        case title, brand, category, color, size, images
    }
}
