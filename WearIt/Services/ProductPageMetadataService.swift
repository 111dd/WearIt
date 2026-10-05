import Foundation

enum ProductPageMetadataError: LocalizedError {
    case pageUnavailable
    case noMetadataFound

    var errorDescription: String? {
        switch self {
        case .pageUnavailable:
            return String(localized: "webpage_error_unavailable")
        case .noMetadataFound:
            return String(localized: "webpage_error_no_metadata")
        }
    }
}

/// Fallback for QR codes that encode a product page URL instead of a GTIN:
/// fetches the page HTML and extracts JSON-LD `Product` data or Open Graph tags.
enum ProductPageMetadataService {

    /// Returns a fetchable page URL when the scanned payload is an http(s) link.
    /// `http` links are upgraded to `https` (ATS blocks plain http anyway).
    static func productPageURL(from raw: String) -> URL? {
        // Shared text ("Check out this item… https://…") and HTML-escaped query strings.
        let unescaped = raw.replacingOccurrences(of: "&amp;", with: "&")
        var trimmed = unescaped.trimmingCharacters(in: .whitespacesAndNewlines)
        if URLComponents(string: trimmed)?.host == nil || trimmed.contains(" ") {
            trimmed = firstLink(in: unescaped) ?? trimmed
        }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return nil
        }
        if scheme == "http" {
            components.scheme = "https"
        }
        // Ad / campaign tracking only makes caching and matching worse.
        let tracking = ["utm_", "gclid", "gad_", "fbclid", "gbraid", "wbraid", "_ga", "mc_", "igsh", "srsltid"]
        let kept = components.queryItems?.filter { item in
            !tracking.contains { item.name.lowercased().hasPrefix($0) }
        }
        components.queryItems = (kept?.isEmpty ?? true) ? nil : kept
        return components.url
    }

    private static func firstLink(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range)
            .compactMap(\.url)
            .first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }?
            .absoluteString
    }

    /// Order: Shopify's product JSON (exact variant, all photos) → page HTML
    /// (JSON-LD, Open Graph) → the same page rendered in a hidden browser, for
    /// shops that build the page in JavaScript or block plain requests → URL slug.
    static func fetch(url: URL) async throws -> BarcodeProduct {
        if let shopify = await ShopifyProductService.fetch(url) {
            return shopify
        }

        var html = try? await downloadHTML(from: url)
        var product = html.flatMap { parse(html: $0, sourceURL: url) }
        if product == nil, let rendered = await WebPageRenderer.html(for: url) {
            html = rendered
            product = parse(html: rendered, sourceURL: url)
        }

        if var product {
            // If JSON-LD exposed a real GTIN, try Barcode Lookup and merge richer fields.
            if let gtin = extractGTIN(fromBarcodeField: product.barcode),
               let apiProduct = try? await BarcodeLookupService.lookup(barcode: gtin) {
                product = mergeProducts(primary: apiProduct, secondary: product) ?? apiProduct
            }
            return product
        }

        // ASOS and similar often block automated fetches — recover from the URL slug.
        if let fromSlug = productFromURLSlug(url) {
            return fromSlug
        }
        throw html == nil ? ProductPageMetadataError.pageUnavailable : ProductPageMetadataError.noMetadataFound
    }

    static func parse(html: String, sourceURL url: URL) -> BarcodeProduct? {
        let breadcrumbs = parseBreadcrumbs(html: html)
        let fromJSONLD = parseJSONLD(html: html, sourceURL: url, breadcrumbs: breadcrumbs)
        let fromOG = parseOpenGraph(html: html, sourceURL: url, breadcrumbs: breadcrumbs)
        return mergeProducts(primary: fromJSONLD, secondary: fromOG) ?? fromJSONLD ?? fromOG
    }

    /// When HTML is blocked (common on ASOS), recover brand/title/color from SEO-friendly path:
    /// `/polo-ralph-lauren/polo-ralph-lauren-short-sleeve-…-in-white/prd/203027027`
    static func productFromURLSlug(_ url: URL) -> BarcodeProduct? {
        let parts = url.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        let skip: Set<String> = ["prd", "product", "products", "p", "dp", "en", "us", "gb", "il", "men", "women", "kids"]
        let candidates = parts.filter { part in
            guard part.contains("-"), part.count >= 12 else { return false }
            if skip.contains(part.lowercased()) { return false }
            if part.range(of: #"^\d+$"#, options: .regularExpression) != nil { return false }
            return true
        }
        guard let slug = candidates.max(by: { $0.count < $1.count }) else { return nil }

        var titleWords = slug
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop trailing "in white" color phrase into color field when present.
        var color: String?
        if let range = titleWords.range(of: #"\bin\s+([a-z][a-z\s]+)$"#, options: [.regularExpression, .caseInsensitive]) {
            let match = String(titleWords[range])
            color = match.replacingOccurrences(of: #"^in\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            titleWords = String(titleWords[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        // Brand: first multi-word path segment that isn't the main slug (ASOS: /brand/slug/prd/id).
        var brand: String?
        if let brandPart = parts.first(where: { $0.contains("-") && $0.lowercased() != slug.lowercased() && $0.count >= 4 }) {
            brand = brandPart.replacingOccurrences(of: "-", with: " ").capitalized
            // Avoid duplicating brand prefix inside the title.
            let brandLower = brand!.lowercased()
            if titleWords.lowercased().hasPrefix(brandLower) {
                titleWords = String(titleWords.dropFirst(brandLower.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let title = titleWords.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
        guard !title.isEmpty else { return nil }

        // `/…/prd/208639913` → product id for CDN image construction.
        var productID: String?
        if let prdIndex = parts.firstIndex(where: { $0.lowercased() == "prd" }),
           prdIndex + 1 < parts.count {
            let candidate = parts[prdIndex + 1]
            if candidate.range(of: #"^\d+$"#, options: .regularExpression) != nil {
                productID = candidate
            }
        }

        let host = url.host?.lowercased() ?? ""
        let imageURL: URL? = host.contains("asos.com")
            ? asosCDNImageURL(slug: slug, productID: productID, color: color)
            : nil

        let pathHint = ([brand, title, color].compactMap { $0 } + parts).joined(separator: " ")
        return makeProduct(
            title: title,
            brand: brand,
            color: color?.capitalized,
            size: nil,
            material: nil,
            categoryPath: pathHint,
            imageURLs: imageURL.map { [$0] } ?? [],
            description: nil,
            barcodeOverride: nil,
            sourceURL: url
        )
    }

    /// ASOS hosts images on a predictable CDN path even when the PDP HTML is blocked:
    /// `images.asos-media.com/products/{slug}/{productId}-1-{colorcompact}`
    private static func asosCDNImageURL(slug: String, productID: String?, color: String?) -> URL? {
        guard let productID, !productID.isEmpty else { return nil }
        if let color {
            let compact = color.lowercased().filter { $0.isLetter || $0.isNumber }
            if !compact.isEmpty,
               let url = URL(string: "https://images.asos-media.com/products/\(slug)/\(productID)-1-\(compact)") {
                return url
            }
        }
        return URL(string: "https://images.asos-media.com/products/\(slug)/\(productID)-1")
    }

    /// Prefers primary text fields; fills gaps from secondary (image, brand, colors, etc.).
    private static func mergeProducts(primary: BarcodeProduct?, secondary: BarcodeProduct?) -> BarcodeProduct? {
        guard let primary, let secondary else { return nil }
        let title = primary.title ?? secondary.title
        let brand = primary.brand ?? secondary.brand
        let imageURL = primary.imageURL ?? secondary.imageURL
        let colors = primary.colors.isEmpty ? secondary.colors : primary.colors
        let path = primary.categoryPath ?? secondary.categoryPath ?? ""
        guard title != nil || imageURL != nil || brand != nil else { return nil }

        let category = primary.category
            ?? secondary.category
            ?? ProductFieldMapper.mapCategory(path: path, title: title)
        let itemType = primary.itemType
            ?? secondary.itemType
            ?? ProductFieldMapper.mapItemType(path: path, title: title, category: category)

        let barcode: String = {
            if extractGTIN(fromBarcodeField: primary.barcode) != nil { return primary.barcode }
            if extractGTIN(fromBarcodeField: secondary.barcode) != nil { return secondary.barcode }
            return primary.barcode
        }()

        var merged = BarcodeProduct(
            barcode: barcode,
            title: title,
            brand: brand,
            category: category,
            itemType: itemType,
            colors: colors,
            size: primary.size ?? secondary.size,
            imageURL: imageURL,
            categoryPath: primary.categoryPath ?? secondary.categoryPath,
            materials: primary.materials.isEmpty ? secondary.materials : primary.materials
        )
        var images: [URL] = []
        for url in primary.imageURLs + secondary.imageURLs where !images.contains(url) {
            images.append(url)
        }
        merged.imageURLs = images
        merged.fit = primary.fit ?? secondary.fit
        merged.sleeveLength = primary.sleeveLength ?? secondary.sleeveLength
        merged.pattern = primary.pattern ?? secondary.pattern
        return merged
    }

    private static func extractGTIN(fromBarcodeField value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("://"), trimmed.allSatisfy(\.isNumber) else { return nil }
        guard (8...14).contains(trimmed.count) else { return nil }
        return trimmed
    }

    // MARK: - Download

    private static func downloadHTML(from url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 15)
        // Some shops serve stripped pages (or 403) to non-browser user agents.
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9,he;q=0.8", forHTTPHeaderField: "Accept-Language")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProductPageMetadataError.pageUnavailable
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProductPageMetadataError.pageUnavailable
        }
        if let html = String(data: data, encoding: .utf8) {
            return html
        }
        if let html = String(data: data, encoding: .isoLatin1) {
            return html
        }
        // Last resort: lossy ASCII so meta tags with Latin text can still parse.
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - JSON-LD

    private static func parseJSONLD(html: String, sourceURL: URL, breadcrumbs: String) -> BarcodeProduct? {
        let pattern = #"<script[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }

        let range = NSRange(html.startIndex..., in: html)
        var breadcrumbFromLD = breadcrumbs
        for match in regex.matches(in: html, range: range) {
            guard let bodyRange = Range(match.range(at: 1), in: html) else { continue }
            let json = String(html[bodyRange])
            guard let data = json.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) else { continue }
            if breadcrumbFromLD.isEmpty, let crumbs = findBreadcrumbPath(in: root) {
                breadcrumbFromLD = crumbs
            }
            if let productDict = findProductObject(in: root),
               let product = mapJSONLDProduct(productDict, sourceURL: sourceURL, breadcrumbs: breadcrumbFromLD) {
                return product
            }
        }
        return nil
    }

    /// Finds the first `@type: Product` object at the top level, inside arrays, or inside `@graph`.
    private static func findProductObject(in node: Any) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if isType(dict["@type"], named: "Product") || isType(dict["@type"], named: "ProductGroup") {
                return dict
            }
            if let graph = dict["@graph"] as? [Any] {
                for item in graph {
                    if let found = findProductObject(in: item) { return found }
                }
            }
            return nil
        }
        if let array = node as? [Any] {
            for item in array {
                if let found = findProductObject(in: item) { return found }
            }
        }
        return nil
    }

    private static func findBreadcrumbPath(in node: Any) -> String? {
        if let dict = node as? [String: Any] {
            if isType(dict["@type"], named: "BreadcrumbList"),
               let elements = dict["itemListElement"] as? [Any] {
                let names: [String] = elements.compactMap { el in
                    guard let item = el as? [String: Any] else { return nil }
                    if let name = item["name"] as? String { return cleanText(name) }
                    if let nested = item["item"] as? [String: Any],
                       let name = nested["name"] as? String {
                        return cleanText(name)
                    }
                    return nil
                }
                if !names.isEmpty { return names.joined(separator: " > ") }
            }
            if let graph = dict["@graph"] as? [Any] {
                for item in graph {
                    if let found = findBreadcrumbPath(in: item) { return found }
                }
            }
        }
        if let array = node as? [Any] {
            for item in array {
                if let found = findBreadcrumbPath(in: item) { return found }
            }
        }
        return nil
    }

    private static func parseBreadcrumbs(html: String) -> String {
        let pattern = #"<script[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return "" }
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard let bodyRange = Range(match.range(at: 1), in: html) else { continue }
            let json = String(html[bodyRange])
            guard let data = json.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data),
                  let path = findBreadcrumbPath(in: root) else { continue }
            return path
        }
        return ""
    }

    private static func isType(_ value: Any?, named expected: String) -> Bool {
        if let type = value as? String {
            return typeMatches(type, expected: expected)
        }
        if let types = value as? [Any] {
            return types.contains { item in
                if let type = item as? String { return typeMatches(type, expected: expected) }
                return false
            }
        }
        return false
    }

    private static func typeMatches(_ type: String, expected: String) -> Bool {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare(expected) == .orderedSame { return true }
        return trimmed.lowercased().hasSuffix("/\(expected.lowercased())")
    }

    private static func mapJSONLDProduct(
        _ group: [String: Any],
        sourceURL: URL,
        breadcrumbs: String
    ) -> BarcodeProduct? {
        // ProductGroup: the variant the link points at supplies color, photos and GTIN.
        let variant = selectedVariant(in: group, sourceURL: sourceURL)
        let dict = group.merging(variant ?? [:]) { _, fromVariant in fromVariant }
        let name = (group["name"] as? String).flatMap(cleanText) ?? (dict["name"] as? String).flatMap(cleanText)
        let brand = brandName(from: dict["brand"])
        let color = stringValue(dict["color"])
        var images = allImageURLs(from: variant?["image"], relativeTo: sourceURL)
        for url in allImageURLs(from: group["image"], relativeTo: sourceURL) where !images.contains(url) {
            images.append(url)
        }
        let material = stringValue(dict["material"]) ?? stringValue(dict["materialExtent"])
        let description = stringValue(dict["description"])
        let categoryPath = [
            breadcrumbs,
            stringValue(dict["category"]),
            stringValue(dict["productID"])
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")

        let gtin = firstNonEmpty([
            stringValue(dict["gtin13"]),
            stringValue(dict["gtin12"]),
            stringValue(dict["gtin14"]),
            stringValue(dict["gtin8"]),
            stringValue(dict["gtin"]),
            stringValue(dict["sku"])
        ].compactMap { $0?.filter(\.isNumber) }.filter { (8...14).contains($0.count) })

        guard name != nil || !images.isEmpty || gtin != nil else { return nil }
        // Pages list every size on offer; the user's own size isn't one of them.
        return makeProduct(
            title: name,
            brand: brand,
            color: color,
            size: nil,
            material: material,
            categoryPath: categoryPath.isEmpty ? nil : categoryPath,
            imageURLs: images,
            description: description,
            barcodeOverride: gtin,
            sourceURL: sourceURL
        )
    }

    /// The `hasVariant` entry whose sku / id / GTIN / url matches the link's
    /// query or path (`?variant=`, `?color=`, `?v1=`…); else the first one.
    private static func selectedVariant(in group: [String: Any], sourceURL: URL) -> [String: Any]? {
        let variants = (group["hasVariant"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        guard !variants.isEmpty else { return nil }
        let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
        let keys = Set(((components?.queryItems ?? []).compactMap(\.value) + [sourceURL.lastPathComponent])
            .map { $0.lowercased() }
            .filter { $0.count >= 3 })
        guard !keys.isEmpty else { return variants.first }
        return variants.first { variant in
            let ids = ["sku", "productID", "gtin", "gtin13", "gtin12", "gtin14", "@id", "color"]
                .compactMap { stringValue(variant[$0])?.lowercased() }
            if ids.contains(where: { keys.contains($0) }) { return true }
            let link = (stringValue(variant["url"]) ?? offerString(variant["offers"], key: "url"))?.lowercased() ?? ""
            return keys.contains { link.contains("=\($0)") || link.hasSuffix("/\($0)") }
        } ?? variants.first
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return cleanText(string) }
        if let array = value as? [Any] {
            let parts = array.compactMap { stringValue($0) }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        if let dict = value as? [String: Any] {
            return stringValue(dict["name"]) ?? stringValue(dict["value"])
        }
        return nil
    }

    private static func offerString(_ offers: Any?, key: String) -> String? {
        if let dict = offers as? [String: Any] {
            return stringValue(dict[key])
        }
        if let array = offers as? [Any] {
            for item in array {
                if let value = offerString(item, key: key) { return value }
            }
        }
        return nil
    }

    private static func firstNonEmpty(_ values: [String]) -> String? {
        values.first { !$0.isEmpty }
    }

    private static func brandName(from value: Any?) -> String? {
        if let string = value as? String { return cleanText(string) }
        if let dict = value as? [String: Any], let name = dict["name"] as? String {
            return cleanText(name)
        }
        return nil
    }

    /// JSON-LD `image` may be a string, an array (of strings or objects), or an ImageObject.
    private static func firstImageURL(from value: Any?, relativeTo sourceURL: URL) -> URL? {
        if let string = value as? String {
            return resolveURL(string, relativeTo: sourceURL)
        }
        if let array = value as? [Any] {
            for item in array {
                if let url = firstImageURL(from: item, relativeTo: sourceURL) { return url }
            }
            return nil
        }
        if let dict = value as? [String: Any] {
            let candidate = (dict["url"] as? String) ?? (dict["contentUrl"] as? String)
            return candidate.flatMap { resolveURL($0, relativeTo: sourceURL) }
        }
        return nil
    }

    private static func allImageURLs(from value: Any?, relativeTo sourceURL: URL) -> [URL] {
        if let array = value as? [Any] {
            var urls: [URL] = []
            for item in array {
                for url in allImageURLs(from: item, relativeTo: sourceURL) where !urls.contains(url) {
                    urls.append(url)
                }
            }
            return urls
        }
        return firstImageURL(from: value, relativeTo: sourceURL).map { [$0] } ?? []
    }

    // MARK: - Open Graph

    private static func parseOpenGraph(html: String, sourceURL: URL, breadcrumbs: String) -> BarcodeProduct? {
        var tags: [String: String] = [:]
        for key in [
            "og:title", "og:image", "og:image:secure_url", "og:site_name", "og:description",
            "og:brand", "product:brand", "product:color", "twitter:title", "twitter:image", "description"
        ] {
            if let content = metaContent(for: key, in: html) {
                tags[key] = content
            }
        }

        var title = tags["og:title"].flatMap(cleanText)
            ?? tags["twitter:title"].flatMap(cleanText)
        if title == nil {
            title = htmlTitle(in: html)
        }
        let imageString = tags["og:image:secure_url"]
            ?? tags["og:image"]
            ?? tags["twitter:image"]
        var images = imageString.flatMap { resolveURL($0, relativeTo: sourceURL) }.map { [$0] } ?? []
        for extra in metaContents(for: "og:image", in: html) {
            if let url = resolveURL(extra, relativeTo: sourceURL), !images.contains(url) {
                images.append(url)
            }
        }

        guard title != nil || !images.isEmpty else { return nil }

        let siteName = tags["og:site_name"].flatMap(cleanText)
        let brand = tags["og:brand"].flatMap(cleanText)
            ?? tags["product:brand"].flatMap(cleanText)
            ?? siteName
        return makeProduct(
            title: stripSiteName(from: title, siteName: siteName),
            brand: brand,
            color: tags["product:color"],
            size: nil,
            material: nil,
            categoryPath: breadcrumbs.isEmpty ? nil : breadcrumbs,
            imageURLs: images,
            description: (tags["og:description"] ?? tags["description"]).flatMap(cleanText),
            barcodeOverride: nil,
            sourceURL: sourceURL
        )
    }

    /// Every `og:image` on the page, in order (galleries often list several).
    private static func metaContents(for property: String, in html: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let pattern = #"<meta[^>]*(?:property|name)\s*=\s*["']"# + escaped + #"["'][^>]*content\s*=\s*["']([^"']*)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).prefix(8).compactMap { match in
            Range(match.range(at: 1), in: html).map { decodeHTMLEntities(String(html[$0])) }
        }
    }

    /// Extracts `content` of a `<meta>` tag whose `property`/`name` matches, regardless of attribute order.
    private static func metaContent(for property: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        // Allow newlines inside the tag; shops often pretty-print meta attributes.
        let patterns = [
            #"<meta[\s\S]*?(?:property|name)\s*=\s*["']"# + escaped + #"["'][\s\S]*?content\s*=\s*["']([^"']*)["']"#,
            #"<meta[\s\S]*?content\s*=\s*["']([^"']*)["'][\s\S]*?(?:property|name)\s*=\s*["']"# + escaped + #"["']"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            if let match = regex.firstMatch(in: html, range: range),
               let contentRange = Range(match.range(at: 1), in: html) {
                let value = decodeHTMLEntities(String(html[contentRange]))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func htmlTitle(in html: String) -> String? {
        let pattern = #"<title[^>]*>(.*?)</title>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let titleRange = Range(match.range(at: 1), in: html) else { return nil }
        return cleanText(String(html[titleRange]))
    }

    /// Drops a trailing "| SiteName" / "- SiteName" suffix commonly appended to page titles.
    private static func stripSiteName(from title: String?, siteName: String?) -> String? {
        guard var title else { return nil }
        // Terminal X style: "… - TERMINAL X - TERMINAL X"
        while true {
            var stripped = false
            for separator in [" | ", " – ", " — ", " - "] {
                if let range = title.range(of: separator, options: .backwards) {
                    let suffix = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    let looksLikeSite = suffix.count <= 24
                        && (siteName.map { suffix.localizedCaseInsensitiveContains($0) } == true
                            || suffix.uppercased() == suffix
                            || suffix.localizedCaseInsensitiveContains("terminal"))
                    if looksLikeSite {
                        title = String(title[..<range.lowerBound])
                        stripped = true
                        break
                    }
                }
            }
            if !stripped { break }
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Mapping to BarcodeProduct

    static func makeProduct(
        title rawTitle: String?,
        brand: String?,
        color rawColor: String?,
        size: String?,
        material: String?,
        categoryPath: String?,
        imageURLs: [URL],
        description: String?,
        barcodeOverride: String?,
        sourceURL: URL
    ) -> BarcodeProduct {
        // "HB Badge Sweater | Black" → title + color.
        let (title, colorFromTitle) = splitColorSegment(rawTitle)
        let color = rawColor ?? colorFromTitle
        let path = [categoryPath, urlPathHint(from: sourceURL)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let category = ProductFieldMapper.mapCategory(path: path, title: title)
        let itemType = ProductFieldMapper.mapItemType(path: path, title: title, category: category)
        let colors = ProductFieldMapper.mapColors(colorField: color, title: title)
        let mappedSize = ProductFieldMapper.mapSize(size, category: category)
        var materials = ProductFieldMapper.mapMaterials(material)
        if materials.isEmpty { materials = ProductFieldMapper.mapMaterials(description) }

        var product = BarcodeProduct(
            barcode: barcodeOverride ?? sourceURL.absoluteString,
            title: title,
            brand: brand,
            category: category,
            itemType: itemType,
            colors: colors,
            size: mappedSize,
            imageURL: imageURLs.first,
            categoryPath: path.isEmpty ? nil : path,
            materials: materials
        )
        product.imageURLs = Array(imageURLs.prefix(8))
        // Title first: descriptions also mention what the item "pairs well with".
        product.fit = ProductFieldMapper.mapFit(title) ?? ProductFieldMapper.mapFit(description)
        if category == .top || category == nil {
            product.sleeveLength = ProductFieldMapper.mapSleeve(title) ?? ProductFieldMapper.mapSleeve(description)
        }
        product.pattern = ProductFieldMapper.mapPattern(title) ?? ProductFieldMapper.mapPattern(description)
        return product
    }

    /// A short title segment that is only a color ("… | Black", "… - שחור").
    private static func splitColorSegment(_ title: String?) -> (String?, String?) {
        guard let title else { return (nil, nil) }
        for separator in [" | ", " - ", " – "] {
            let parts = title.components(separatedBy: separator)
            guard parts.count > 1 else { continue }
            let kept = parts.filter { part in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                return !(trimmed.count <= 20 && ProductFieldMapper.matchColor(trimmed) != nil
                    && trimmed.split(separator: " ").count <= 3 && parts.first != part)
            }
            if kept.count < parts.count, !kept.isEmpty {
                let color = parts.first { !kept.contains($0) }?.trimmingCharacters(in: .whitespaces)
                return (kept.joined(separator: separator), color)
            }
        }
        return (title, nil)
    }

    /// `/men/shirts/tshirts/r495…` → useful English taxonomy hints for Israeli fashion sites.
    private static func urlPathHint(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init).filter { part in
            guard part.count > 1 else { return false }
            // Skip opaque product ids like r495570027
            if part.range(of: #"^[a-z]?\d{5,}$"#, options: .regularExpression) != nil { return false }
            return true
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - Text helpers

    private static func resolveURL(_ string: String, relativeTo sourceURL: URL) -> URL? {
        let trimmed = decodeHTMLEntities(string).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("//") {
            return URL(string: "https:" + trimmed)
        }
        guard let url = URL(string: trimmed, relativeTo: sourceURL)?.absoluteURL else { return nil }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func cleanText(_ raw: String) -> String? {
        let cleaned = decodeHTMLEntities(raw)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func decodeHTMLEntities(_ raw: String) -> String {
        var result = raw
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities like &#8211; or &#x2019;
        while let match = result.range(of: #"&#x?[0-9a-fA-F]+;"#, options: .regularExpression) {
            let entity = String(result[match])
            let body = entity.dropFirst(2).dropLast()
            let scalarValue: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                scalarValue = UInt32(body.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(body)
            }
            if let scalarValue, let scalar = Unicode.Scalar(scalarValue) {
                result.replaceSubrange(match, with: String(Character(scalar)))
            } else {
                result.replaceSubrange(match, with: "")
            }
        }
        return result
    }
}
