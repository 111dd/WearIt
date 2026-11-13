import UIKit

struct GarmentPhotoSuggestion: Identifiable {
    let id: String
    let title: String
    let sourceName: String
    let sourceURL: URL
    let imageURL: URL
    let preview: UIImage
}

/// Photos from a product page the user pointed at. The app runs no web search of its own,
/// and the wardrobe photo is never uploaded.
actor GarmentPhotoDiscovery {
    static let shared = GarmentPhotoDiscovery()

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
                    sourceURL: url, imageURL: imageURL, preview: preview))
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
