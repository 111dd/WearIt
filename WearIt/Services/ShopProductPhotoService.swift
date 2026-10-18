import UIKit
import Vision
import ImageIO

/// A visible shop tile asks for at most four small public previews. Nothing from
/// the wardrobe is uploaded, and photographed people never determine department.
actor ShopProductPhotoService {
    static let shared = ShopProductPhotoService()

    private static let previewSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.urlCache = URLCache.shared
        return URLSession(configuration: configuration)
    }()

    private struct Key: Hashable {
        let urls: [URL]
        let productOnly: Bool
        let fetchedAt: String?
    }

    private struct Cached {
        let image: UIImage?
        let expiresAt: Date
        var lastUsed: Date
    }

    private struct Pending {
        let id: UUID
        var waiters: [UUID: CheckedContinuation<UIImage?, Never>]
        var task: Task<UIImage?, Never>?
    }

    private var cache: [Key: Cached] = [:]
    private var pending: [Key: Pending] = [:]
    private var queue: [Key] = []
    private var worker: Task<Void, Never>?

    func image(for product: ShopProduct, preferProductOnly: Bool) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        var urls: [URL] = []
        for raw in product.item.images ?? [] {
            guard let url = URL(string: raw), Self.isWebURL(url), !urls.contains(url) else { continue }
            urls.append(url)
            if urls.count == 4 { break }
        }
        if urls.isEmpty, let fallback = product.imageURL, Self.isWebURL(fallback) { urls = [fallback] }
        guard !urls.isEmpty else { return nil }
        let key = Key(urls: urls, productOnly: preferProductOnly, fetchedAt: product.item.fetchedAt)
        if var entry = cache[key], entry.expiresAt > Date() {
            entry.lastUsed = Date()
            cache[key] = entry
            return entry.image
        }
        cache[key] = nil
        let waiter = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                if pending[key] != nil {
                    pending[key]?.waiters[waiter] = continuation
                } else {
                    // Lazy tiles normally keep this much smaller; do not queue the catalog.
                    guard pending.count < 32 else { continuation.resume(returning: nil); return }
                    pending[key] = Pending(id: UUID(), waiters: [waiter: continuation], task: nil)
                    queue.append(key)
                }
                if worker == nil { worker = Task { await drainQueue() } }
            }
        } onCancel: {
            Task { await self.cancel(key: key, waiter: waiter) }
        }
    }

    private func cancel(key: Key, waiter: UUID) {
        guard var request = pending[key], let continuation = request.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: nil)
        if request.waiters.isEmpty {
            request.task?.cancel()
            pending[key] = nil
            queue.removeAll { $0 == key }
        } else {
            pending[key] = request
        }
    }

    private func drainQueue() async {
        while !queue.isEmpty {
            let key = queue.removeFirst()
            guard let request = pending[key] else { continue }
            let task = Task.detached(priority: .utility) {
                await Self.load(urls: key.urls, productOnly: key.productOnly)
            }
            pending[key]?.task = task
            let image = await task.value
            // A cancelled request may have been replaced by a new waiter for this key.
            guard pending[key]?.id == request.id, let completed = pending.removeValue(forKey: key) else { continue }
            let now = Date()
            cache[key] = Cached(image: image, expiresAt: now.addingTimeInterval(image == nil ? 300 : 6 * 3600), lastUsed: now)
            while cache.count > 48, let oldest = cache.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
                cache[oldest] = nil
            }
            for continuation in completed.waiters.values { continuation.resume(returning: image) }
        }
        worker = nil
    }

    nonisolated private static func load(urls: [URL], productOnly: Bool) async -> UIImage? {
        let deadline = Date().addingTimeInterval(24)
        for url in urls.prefix(4) {
            guard !Task.isCancelled, Date() < deadline else { return nil }
            do {
                let data = try await previewData(url)
                try Task.checkCancellation()
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 480,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { continue }
                if productOnly && !looksLikeProductPhoto(cg) { continue }
                try Task.checkCancellation()
                return UIImage(cgImage: cg)
            } catch is CancellationError {
                return nil
            } catch {
                continue
            }
        }
        return nil
    }

    nonisolated private static func previewData(_ url: URL) async throws -> Data {
        let byteLimit = 5 * 1024 * 1024
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        // Original catalog URLs only; never ask image CDNs for a larger rendition.
        let (bytes, response) = try await previewSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.mimeType?.lowercased().hasPrefix("image/") == true,
              response.expectedContentLength <= Int64(byteLimit),
              response.url.map(isWebURL) == true else {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        do {
            for try await byte in bytes {
                guard data.count < byteLimit else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(byte)
                if data.count % (32 * 1024) == 0 { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            guard !data.isEmpty else { throw URLError(.zeroByteResource) }
            return data
        } catch {
            bytes.task.cancel()
            throw error
        }
    }

    nonisolated private static func looksLikeProductPhoto(_ image: CGImage) -> Bool {
        let fullBody = VNDetectHumanRectanglesRequest()
        fullBody.upperBodyOnly = false
        let upperBody = VNDetectHumanRectanglesRequest()
        upperBody.upperBodyOnly = true
        let faces = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([fullBody, upperBody, faces])
        } catch {
            return false
        }
        guard (faces.results ?? []).isEmpty,
              !(fullBody.results ?? []).contains(where: { $0.confidence >= 0.3 && $0.boundingBox.height >= 0.12 }),
              !(upperBody.results ?? []).contains(where: { $0.confidence >= 0.3 && $0.boundingBox.height >= 0.12 }) else { return false }
        // Detection failure is not proof of an item-alone photo. Require a plain
        // studio frame and a visible foreground object; uncertain crops stay hidden.
        return hasPlainProductFrame(image)
    }

    nonisolated private static func hasPlainProductFrame(_ image: CGImage) -> Bool {
        let side = 48
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                  bytesPerRow: side * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let raw = context.data else { return false }
        let pixels = raw.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var edges: [Double] = []
        var center: [Double] = []
        for y in 0..<side {
            for x in 0..<side {
                let index = (y * side + x) * 4
                let value = 0.299 * Double(pixels[index]) + 0.587 * Double(pixels[index + 1]) + 0.114 * Double(pixels[index + 2])
                if x < 3 || y < 3 || x >= side - 3 || y >= side - 3 { edges.append(value) }
                else if (12..<36).contains(x), (12..<36).contains(y) { center.append(value) }
            }
        }
        guard !edges.isEmpty, !center.isEmpty else { return false }
        let edgeMean = edges.reduce(0, +) / Double(edges.count)
        let deviation = (edges.reduce(0) { $0 + pow($1 - edgeMean, 2) } / Double(edges.count)).squareRoot()
        let centerMean = center.reduce(0, +) / Double(center.count)
        let foreground = Double(center.filter { abs($0 - edgeMean) > 15 }.count) / Double(center.count)
        return deviation <= 12 && abs(centerMean - edgeMean) >= 8 && foreground >= 0.08
    }

    nonisolated private static func isWebURL(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }
}
