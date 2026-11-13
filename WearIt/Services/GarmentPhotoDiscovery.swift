import UIKit

struct GarmentPhotoSuggestion: Identifiable {
    let id: String
    let title: String
    let sourceName: String
    let sourceURL: URL
    let imageURL: URL
    let preview: UIImage
    /// True when the user pointed at a product page. A web search result is only a candidate.
    let matchesItem: Bool
}

/// Public web image results and product-page photos. The wardrobe photo is never uploaded.
actor GarmentPhotoDiscovery {
    static let shared = GarmentPhotoDiscovery()

    private struct WebHit {
        var image: URL
        var thumbnail: URL?
        var page: URL
        var title: String
    }

    func webPhotos(matching words: String) async -> [GarmentPhotoSuggestion] {
        let query = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !Task.isCancelled else { return [] }
        var hits = await Self.duckDuckGoImages(matching: query)
        if hits.count < 4 {
            let more = await Self.bingImages(matching: query)
            var seen = Set(hits.map { $0.image.absoluteString })
            hits.append(contentsOf: more.filter { seen.insert($0.image.absoluteString).inserted })
        }
        var photos: [GarmentPhotoSuggestion] = []
        let deadline = Date().addingTimeInterval(20)
        for hit in hits.prefix(8) {
            guard !Task.isCancelled, Date() < deadline else { break }
            let previewURL = hit.thumbnail ?? hit.image
            guard let preview = try? await Self.download(previewURL, pixels: 420, allowAmbiguousMime: true) else { continue }
            photos.append(GarmentPhotoSuggestion(
                id: hit.image.absoluteString, title: hit.title, sourceName: hit.page.host ?? "",
                sourceURL: hit.page, imageURL: hit.image, preview: preview, matchesItem: false))
            if photos.count == 8 { break }
        }
        return photos
    }

    func photos(from url: URL) async throws -> [GarmentPhotoSuggestion] {
        let product = try await ProductPageMetadataService.fetch(url: url)
        try Task.checkCancellation()
        var photos: [GarmentPhotoSuggestion] = []
        var seen = Set<URL>()
        for imageURL in product.imageURLs.prefix(8) where seen.insert(imageURL).inserted {
            try Task.checkCancellation()
            if let preview = try? await Self.download(imageURL, pixels: 420) {
                photos.append(GarmentPhotoSuggestion(id: imageURL.absoluteString,
                    title: product.title ?? url.host ?? "", sourceName: url.host ?? "",
                    sourceURL: url, imageURL: imageURL, preview: preview, matchesItem: true))
            }
            if photos.count == 6 { break }
        }
        return photos
    }

    func fullImage(for suggestion: GarmentPhotoSuggestion) async throws -> UIImage {
        let large = ProductImagePicker.highResolution(suggestion.imageURL)
        let urls = large == suggestion.imageURL ? [suggestion.imageURL] : [large, suggestion.imageURL]
        var lastError: Error = URLError(.badURL)
        for url in urls {
            do {
                return try await Self.download(url, pixels: 2048, allowAmbiguousMime: true)
            } catch {
                lastError = error
                try Task.checkCancellation()
            }
        }
        throw lastError
    }

    private static func duckDuckGoImages(matching query: String) async -> [WebHit] {
        guard var page = URLComponents(string: "https://duckduckgo.com/") else { return [] }
        page.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let pageURL = page.url, let html = try? await text(from: pageURL),
              let token = firstMatch(in: html, patterns: [
                #"vqd="([^"]+)""#, #"vqd='([^']+)'"#, #"vqd=([0-9-]+)"#
              ]) else { return [] }
        guard var api = URLComponents(string: "https://duckduckgo.com/i.js") else { return [] }
        api.queryItems = [
            URLQueryItem(name: "o", value: "json"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "vqd", value: token),
            URLQueryItem(name: "p", value: "1")
        ]
        guard let apiURL = api.url, let data = try? await data(from: apiURL, referer: pageURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { item in
            guard let image = (item["image"] as? String).flatMap(URL.init(string:)),
                  isWeb(image) else { return nil }
            let thumb = (item["thumbnail"] as? String).flatMap(URL.init(string:)).flatMap { isWeb($0) ? $0 : nil }
            let page = (item["url"] as? String).flatMap(URL.init(string:)).flatMap { isWeb($0) ? $0 : nil } ?? image
            let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return WebHit(image: image, thumbnail: thumb, page: page, title: title?.isEmpty == false ? title! : (page.host ?? ""))
        }
    }

    private static func bingImages(matching query: String) async -> [WebHit] {
        guard var components = URLComponents(string: "https://www.bing.com/images/search") else { return [] }
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "form", value: "HDRSC2")]
        guard let url = components.url, let html = try? await text(from: url) else { return [] }
        let text = html.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
        var hits: [WebHit] = []
        var seen = Set<String>()
        var cursor = text.startIndex
        while hits.count < 8, let range = text.range(of: "\"murl\":\"", range: cursor..<text.endIndex) {
            let valueStart = range.upperBound
            guard let valueEnd = text[valueStart...].firstIndex(of: "\"") else { break }
            cursor = text.index(after: valueEnd)
            let windowEnd = text.index(valueEnd, offsetBy: 900, limitedBy: text.endIndex) ?? text.endIndex
            let window = text[valueEnd..<windowEnd]
            guard let image = URL(string: unescape(String(text[valueStart..<valueEnd]))), isWeb(image),
                  seen.insert(image.absoluteString).inserted else { continue }
            let page = firstURL(in: window, key: "purl") ?? image
            let title = firstValue(in: window, key: "t") ?? (page.host ?? "")
            let thumb = firstURL(in: window, key: "turl")
            hits.append(WebHit(image: image, thumbnail: thumb, page: page, title: title))
        }
        return hits
    }

    private static func text(from url: URL) async throws -> String {
        let data = try await data(from: url, referer: nil)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw URLError(.cannotDecodeContentData)
        }
        return text
    }

    private static func data(from url: URL, referer: URL?) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count < 5_000_000 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func firstMatch(in text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
                  let hit = Range(match.range(at: 1), in: text) else { continue }
            return String(text[hit])
        }
        return nil
    }

    private static func firstValue(in text: Substring, key: String) -> String? {
        guard let range = text.range(of: "\"\(key)\":\"") else { return nil }
        guard let end = text[range.upperBound...].firstIndex(of: "\"") else { return nil }
        let value = unescape(String(text[range.upperBound..<end]))
        return value.isEmpty ? nil : value
    }

    private static func firstURL(in text: Substring, key: String) -> URL? {
        guard let value = firstValue(in: text, key: key), let url = URL(string: value), isWeb(url) else { return nil }
        return url
    }

    private static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func isWeb(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    private static func download(_ url: URL, pixels: CGFloat, allowAmbiguousMime: Bool = false) async throws -> UIImage {
        guard isWeb(url) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        // Download to a temporary file so compressed image bytes don't accumulate in memory.
        let (file, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        let mime = response.mimeType ?? ""
        let mimeOK = mime.hasPrefix("image/") || (allowAmbiguousMime && (mime.isEmpty || mime == "application/octet-stream"))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), mimeOK,
              let bytes = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              bytes > 0, bytes <= 12 * 1024 * 1024 else { throw URLError(.badServerResponse) }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard let image = ImageStore.downsample(data: data, maxPixelSize: pixels) else { throw URLError(.cannotDecodeContentData) }
        return image
    }
}
