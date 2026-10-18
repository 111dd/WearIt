import UIKit
import Vision

struct GarmentPhotoSuggestion: Identifiable {
    let id: String
    let title: String
    let sourceName: String
    let sourceURL: URL
    let imageURL: URL
    let preview: UIImage
}

/// Downloads public product photos only. The user's image and feature print
/// remain on the device. A visual neighbor is not proof of the same product.
actor GarmentPhotoDiscovery {
    static let shared = GarmentPhotoDiscovery()

    func similarPhotos(to image: UIImage?, products: [ShopProduct]) async -> [GarmentPhotoSuggestion] {
        let reference = image.flatMap(Self.featurePrint)
        var ranked: [(GarmentPhotoSuggestion, Float)] = []
        let deadline = Date().addingTimeInterval(18)
        // The caller prefilters metadata; bound network, Vision work and memory.
        for (index, product) in products.prefix(12).enumerated() {
            guard !Task.isCancelled else { return [] }
            guard Date() < deadline else { break }
            guard let url = product.imageURL,
                  let preview = try? await Self.download(url, pixels: 420) else { continue }
            guard !Task.isCancelled else { return [] }
            var distance = reference == nil ? Float(index) / 12 : 100 + Float(index)
            if let reference, let candidate = Self.featurePrint(preview) {
                var visual: Float = 0
                if (try? reference.computeDistance(&visual, to: candidate)) != nil {
                    distance = visual + Float(index) * 0.015
                }
            }
            ranked.append((GarmentPhotoSuggestion(id: product.id, title: product.title,
                sourceName: product.storeName, sourceURL: product.url, imageURL: url, preview: preview), distance))
        }
        return ranked.sorted { $0.1 < $1.1 }.prefix(6).map(\.0)
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
                    sourceURL: url, imageURL: imageURL, preview: preview))
            }
            if photos.count == 6 { break }
        }
        return photos
    }

    func fullImage(for suggestion: GarmentPhotoSuggestion) async throws -> UIImage {
        let large = ProductImagePicker.highResolution(suggestion.imageURL)
        do {
            return try await Self.download(large, pixels: 2048)
        } catch {
            try Task.checkCancellation()
            guard large != suggestion.imageURL else { throw error }
            return try await Self.download(suggestion.imageURL, pixels: 2048)
        }
    }

    private static func download(_ url: URL, pixels: CGFloat) async throws -> UIImage {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        // Download to a temporary file so compressed image bytes don't accumulate in memory.
        let (file, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.mimeType?.hasPrefix("image/") == true,
              let bytes = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              bytes > 0, bytes <= 12 * 1024 * 1024 else { throw URLError(.badServerResponse) }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard let image = ImageStore.downsample(data: data, maxPixelSize: pixels) else { throw URLError(.cannotDecodeContentData) }
        return image
    }

    private static func featurePrint(_ image: UIImage) -> VNFeaturePrintObservation? {
        let image = GarmentPhotoFraming.trimmed(image)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: 256, height: 256)
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let scale = min(248 / max(image.size.width, 1), 248 / max(image.size.height, 1))
            let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (256 - fitted.width) / 2, y: (256 - fitted.height) / 2,
                                  width: fitted.width, height: fitted.height))
        }
        guard let cg = normalized.cgImage else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        guard (try? VNImageRequestHandler(cgImage: cg).perform([request])) != nil else { return nil }
        return request.results?.first as? VNFeaturePrintObservation
    }
}
