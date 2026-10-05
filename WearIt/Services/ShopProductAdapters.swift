//
//  ShopProductAdapters.swift
//  WearIt
//
//  Shop-specific product sources that beat HTML scraping. Each one is small
//  and returns nil (or falls back to the generic page reader) when the shop
//  answers differently than expected, so a site redesign never breaks adding.
//
//  - Shopify (Renuar and many smaller shops): `/products/<handle>.js` is a
//    public JSON with every variant, photo, product type and tag.
//  - Zara: the product page answers `?ajax=true` with JSON per color; `v1` in
//    the link is the color the user was looking at.
//

import Foundation

// MARK: - Shopify

enum ShopifyProductService {
    /// nil when the link isn't a Shopify product page.
    static func fetch(_ url: URL) async -> BarcodeProduct? {
        guard let jsonURL = productJSONURL(for: url),
              let data = try? await ShopFetch.data(from: jsonURL, accept: "application/json"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = root["title"] as? String else { return nil }

        let variants = (root["variants"] as? [[String: Any]]) ?? []
        let wanted = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "variant" }?.value
        let variant = variants.first { ShopFetch.string($0["id"]) == wanted } ?? variants.first

        // Which option is the color ("Color", "Colour", "צבע")?
        let optionNames: [String] = ((root["options"] as? [Any]) ?? []).map { option in
            if let dict = option as? [String: Any] { return (dict["name"] as? String) ?? "" }
            return (option as? String) ?? ""
        }
        let colorIndex = optionNames.firstIndex { name in
            let lower = name.lowercased()
            return lower.contains("color") || lower.contains("colour") || lower.contains("צבע")
        }
        let color = colorIndex.flatMap { variant?["option\($0 + 1)"] as? String }

        var images: [URL] = []
        func add(_ raw: String?) {
            guard let raw, let resolved = ShopFetch.absoluteURL(raw, base: url), !images.contains(resolved) else { return }
            images.append(resolved)
        }
        if let featured = variant?["featured_image"] as? [String: Any] { add(featured["src"] as? String) }
        ((root["images"] as? [Any]) ?? []).forEach { add($0 as? String) }

        let tags: [String] = (root["tags"] as? [String])
            ?? ((root["tags"] as? String)?.components(separatedBy: ",") ?? [])
        let path = ([root["type"] as? String, root["product_type"] as? String].compactMap { $0 } + tags)
            .joined(separator: " ")
        let description = (root["description"] as? String).map(ShopFetch.plainText)

        return ProductPageMetadataService.makeProduct(
            title: title,
            brand: (root["vendor"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            color: color,
            size: nil,
            material: nil,
            categoryPath: path.isEmpty ? nil : path,
            imageURLs: images,
            description: description,
            barcodeOverride: (variant?["barcode"] as? String).flatMap { $0.count >= 8 ? $0 : nil },
            sourceURL: url
        )
    }

    /// `/products/<handle>` (optionally under a locale or collection path) → `…/products/<handle>.js`.
    private static func productJSONURL(for url: URL) -> URL? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "products"), index + 1 < parts.count else { return nil }
        var handle = parts[index + 1]
        if let dot = handle.firstIndex(of: ".") { handle = String(handle[..<dot]) }
        guard !handle.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // Keep a locale prefix (`/en/products/x`), drop collection paths.
        let prefix = parts[..<index].filter { $0.count <= 5 && $0 != "collections" }
        components.path = "/" + (prefix + ["products", handle + ".js"]).joined(separator: "/")
        components.queryItems = nil
        return components.url
    }
}

// MARK: - Zara

enum ZaraProductService: ProductURLResolver {
    static func canHandle(_ url: URL) -> Bool {
        (url.host?.lowercased().hasSuffix("zara.com") ?? false) && url.path.hasSuffix(".html")
    }

    static func fetch(from url: URL) async throws -> BarcodeProduct {
        if let product = await fetchJSON(url) { return product }
        return try await ProductPageMetadataService.fetch(url: url)
    }

    private static func fetchJSON(_ url: URL) async -> BarcodeProduct? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "ajax", value: "true")]
        guard let jsonURL = components.url,
              let data = try? await ShopFetch.data(from: jsonURL, accept: "application/json"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let product = root["product"] as? [String: Any],
              let name = product["name"] as? String else { return nil }

        let detail = product["detail"] as? [String: Any]
        let colors = (detail?["colors"] as? [[String: Any]]) ?? []
        let wanted = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "v1" }?.value
        let color = colors.first { ShopFetch.string($0["productId"]) == wanted } ?? colors.first

        var images: [URL] = []
        for media in (color?["xmedia"] as? [[String: Any]]) ?? [] {
            var link = (media["url"] as? String)?.replacingOccurrences(of: "{width}", with: "1024")
            if link == nil, let path = media["path"] as? String, let file = media["name"] as? String {
                let stamp = ShopFetch.string(media["timestamp"]).map { "?ts=\($0)" } ?? ""
                link = "https://static.zara.net/photos//\(path)/w/1024/\(file).jpg\(stamp)"
            }
            if let link, let resolved = ShopFetch.absoluteURL(link, base: url), !images.contains(resolved) {
                images.append(resolved)
            }
        }

        // Composition and description live under the color; read every text in them.
        let composition = ShopFetch.allStrings(in: color?["detailedComposition"] ?? detail?["detailedComposition"])
        let description = [color?["description"], product["description"], detail?["description"]]
            .compactMap { $0 as? String }.joined(separator: " ")
        let path = [product["familyName"], product["subfamilyName"], product["sectionName"]]
            .compactMap { $0 as? String }.joined(separator: " ")

        return ProductPageMetadataService.makeProduct(
            title: name,
            brand: "Zara",
            color: color?["name"] as? String,
            size: nil,
            material: composition.isEmpty ? nil : composition,
            categoryPath: path.isEmpty ? nil : path,
            imageURLs: images,
            description: description.isEmpty ? nil : ShopFetch.plainText(description),
            barcodeOverride: nil,
            sourceURL: url
        )
    }
}

// MARK: - Shared helpers

enum ShopFetch {
    static let safariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static func data(from url: URL, accept: String) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("he-IL,he;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProductPageMetadataError.pageUnavailable
        }
        return data
    }

    static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func absoluteURL(_ raw: String, base: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("//") { return URL(string: "https:" + trimmed) }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }

    static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every string value in a JSON tree, joined ("92%", "כותנה", …).
    static func allStrings(in node: Any?) -> String {
        var parts: [String] = []
        func walk(_ value: Any?) {
            if let string = value as? String { parts.append(string) }
            else if let array = value as? [Any] { array.forEach(walk) }
            else if let dict = value as? [String: Any] { dict.values.forEach(walk) }
        }
        walk(node)
        return parts.joined(separator: " ")
    }
}
