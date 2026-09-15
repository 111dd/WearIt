import Foundation

/// Ralph Lauren / Digimarc Digital Product IDs (QR → `j.tn.gg` → `qrscan.ralphlauren.com`).
/// The landing page is a JS shell with no Open Graph; product details come from the
/// EVRYTHNG proxy API using the redirect's `token` + `product` query params.
enum DigimarcProductIDService: ProductURLResolver {

    static func canHandle(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "j.tn.gg" || host == "tn.gg" || host.hasSuffix(".tn.gg") { return true }
        if host == "qrscan.ralphlauren.com" { return true }
        return false
    }

    static func fetch(from url: URL) async throws -> BarcodeProduct {
        let resolved = try await resolveScanURL(from: url)
        guard let token = queryValue("token", in: resolved),
              let productID = queryValue("product", in: resolved),
              !token.isEmpty, !productID.isEmpty else {
            throw ProductPageMetadataError.noMetadataFound
        }

        let apiURL = URL(string: "https://qrscan.ralphlauren.com/v2/products/\(productID)")!
        var request = URLRequest(url: apiURL, timeoutInterval: 12)
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProductPageMetadataError.pageUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProductPageMetadataError.pageUnavailable
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProductPageMetadataError.pageUnavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProductPageMetadataError.pageUnavailable
        }

        let decoded: DigimarcProduct
        do {
            decoded = try JSONDecoder().decode(DigimarcProduct.self, from: data)
        } catch {
            throw ProductPageMetadataError.noMetadataFound
        }
        return map(decoded, sourceURL: resolved)
    }

    // MARK: - Redirect resolution

    /// Follows `j.tn.gg` → `qrscan.ralphlauren.com/?token=…&product=…` without loading the SPA HTML body.
    private static func resolveScanURL(from url: URL) async throws -> URL {
        if url.host?.lowercased() == "qrscan.ralphlauren.com",
           queryValue("token", in: url) != nil,
           queryValue("product", in: url) != nil {
            return url
        }

        let interceptor = RedirectInterceptor()
        let session = URLSession(
            configuration: .ephemeral,
            delegate: interceptor,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            _ = try await session.data(for: request)
        } catch {
            // RedirectInterceptor cancels after capturing Location; treat captured URL as success.
            if let captured = interceptor.redirectURL {
                return captured
            }
            throw ProductPageMetadataError.pageUnavailable
        }

        if let captured = interceptor.redirectURL {
            return captured
        }
        throw ProductPageMetadataError.noMetadataFound
    }

    private static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name.lowercased() == name.lowercased() })?
            .value
    }

    // MARK: - Mapping

    private static func map(_ product: DigimarcProduct, sourceURL: URL) -> BarcodeProduct {
        let fields = product.customFields
        let colorRaw = fields?.colorDescription?.components(separatedBy: "/").first
        let pathParts = [
            fields?.productClassDescription,
            fields?.productCategoryDescription,
            fields?.productSubClassDescription,
            fields?.materialGroupDesc,
            product.name,
            product.fn
        ].compactMap { $0 }.joined(separator: " ")

        let title = humanTitle(from: product)
        let category = ProductFieldMapper.mapCategory(path: pathParts, title: title)
        let itemType = ProductFieldMapper.mapItemType(path: pathParts, title: title, category: category)
        let colors = ProductFieldMapper.mapColors(colorField: colorRaw, title: title)
        let size = ProductFieldMapper.mapSize(fields?.size, category: category)
        let materials = ProductFieldMapper.mapMaterials(fields?.fabricContent)

        let barcode = product.identifiers?.upc
            ?? product.identifiers?.gs101
            ?? sourceURL.absoluteString

        return BarcodeProduct(
            barcode: barcode,
            title: title,
            brand: clean(product.brand),
            category: category,
            itemType: itemType,
            colors: colors,
            size: size,
            imageURL: nil,
            categoryPath: pathParts.isEmpty ? nil : pathParts,
            materials: materials
        )
    }

    /// `SSCNMM4-SHORT SLEEVE-T-SHIRT` → `Short Sleeve T-Shirt`
    private static func humanTitle(from product: DigimarcProduct) -> String? {
        let raw = clean(product.fn) ?? clean(product.name) ?? clean(product.description)
        guard var title = raw else { return nil }
        if let range = title.range(of: #"^[A-Z0-9]+-"#, options: .regularExpression) {
            title = String(title[range.upperBound...])
        }
        title = title
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return title.capitalized
    }

    private static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Redirect capture

private final class RedirectInterceptor: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Written once on the session delegate queue before the task finishes.
    private(set) var redirectURL: URL?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        redirectURL = request.url
        // Stop after the first hop — we only need token/product from Location.
        return nil
    }
}

// MARK: - API DTO

private struct DigimarcProduct: Decodable {
    let id: String?
    let brand: String?
    let name: String?
    let fn: String?
    let description: String?
    let customFields: CustomFields?
    let identifiers: Identifiers?

    struct CustomFields: Decodable {
        let colorDescription: String?
        let fabricContent: String?
        let size: String?
        let productCategoryDescription: String?
        let productClassDescription: String?
        let productSubClassDescription: String?
        let materialGroupDesc: String?
    }

    struct Identifiers: Decodable {
        let upc: String?
        let gs101: String?

        enum CodingKeys: String, CodingKey {
            case upc
            case gs101 = "gs1:01"
        }
    }
}
