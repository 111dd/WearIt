import UIKit
import Vision
import ImageIO

/// Shared, bounded work for visible tiles. Show a usable photo immediately;
/// prefer an item-only angle without hiding a product that only has modeled photos.
actor ShopProductPhotoService {
    static let shared = ShopProductPhotoService()

    private static let previewSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 7
        configuration.timeoutIntervalForResource = 10
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.urlCache = URLCache.shared
        return URLSession(configuration: configuration)
    }()

    private struct Key: Hashable {
        let urls: [URL]
        let productOnly: Bool
        var maxSide = 480
    }
    private struct Cached {
        let image: UIImage?
        let expiresAt: Date
        var lastUsed: Date

        var decodedBytes: Int {
            guard let cg = image?.cgImage else { return 0 }
            return cg.bytesPerRow * cg.height
        }
    }
    private struct Pending {
        let id: UUID
        var waiters: [UUID: AsyncStream<UIImage>.Continuation]
        var preview: UIImage?
        var task: Task<Void, Never>?
    }
    private var cache: [Key: Cached] = [:]
    private var pending: [Key: Pending] = [:]
    private var queue: [Key] = []
    private var activeLoads = 0

    func images(for product: ShopProduct, preferProductOnly: Bool) -> AsyncStream<UIImage> {
        var urls: [URL] = []
        for raw in [product.imageURL?.absoluteString].compactMap({ $0 }) + (product.item.images ?? []) {
            guard let url = URL(string: raw), Self.isWebURL(url), !urls.contains(url) else { continue }
            urls.append(url)
            if urls.count == 6 { break }
        }
        return images(for: Key(urls: urls, productOnly: preferProductOnly))
    }

    /// Each gallery page requests its exact source angle through the same bounded queue.
    /// The caller activates only the selected page and its immediate neighbours.
    func images(for url: URL, maxSide: Int = 1200) -> AsyncStream<UIImage> {
        let urls = Self.isWebURL(url) ? [url] : []
        return images(for: Key(urls: urls, productOnly: false, maxSide: min(1600, max(320, maxSide))))
    }

    private func images(for key: Key) -> AsyncStream<UIImage> {
        let waiter = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            guard !Task.isCancelled, !key.urls.isEmpty else { continuation.finish(); return }
            if var entry = cache[key], entry.expiresAt > Date() {
                entry.lastUsed = Date(); cache[key] = entry
                if let image = entry.image { continuation.yield(image) }
                continuation.finish()
                return
            }
            cache[key] = nil
            continuation.onTermination = { @Sendable _ in
                Task { await self.cancel(key: key, waiter: waiter) }
            }
            if var request = pending[key] {
                request.waiters[waiter] = continuation
                if let image = request.preview { continuation.yield(image) }
                pending[key] = request
            } else {
                guard pending.count < 64 else { continuation.finish(); return }
                pending[key] = Pending(id: UUID(), waiters: [waiter: continuation])
                queue.append(key)
            }
            startQueuedLoads()
        }
    }

    private func cancel(key: Key, waiter: UUID) {
        guard var request = pending[key], let continuation = request.waiters.removeValue(forKey: waiter) else { return }
        continuation.finish()
        if request.waiters.isEmpty {
            if let image = request.preview { remember(image, for: key, lifetime: 60) }
            request.task?.cancel()
            pending[key] = nil
            queue.removeAll { $0 == key }
            // A cancelled running load retains its slot until it actually completes.
        } else { pending[key] = request }
        startQueuedLoads()
    }

    private func startQueuedLoads() {
        while activeLoads < 3, !queue.isEmpty {
            let key = queue.removeFirst()
            guard let request = pending[key] else { continue }
            activeLoads += 1
            let requestID = request.id
            let task = Task.detached(priority: .utility) {
                let image = await Self.load(urls: key.urls, productOnly: key.productOnly, maxSide: key.maxSide) { image in
                    await self.publish(image, key: key, id: requestID)
                }
                await self.complete(image, key: key, id: requestID)
            }
            pending[key]?.task = task
        }
    }

    private func publish(_ image: UIImage, key: Key, id: UUID) {
        guard var request = pending[key], request.id == id else { return }
        request.preview = image
        pending[key] = request
        for continuation in request.waiters.values { continuation.yield(image) }
    }

    private func complete(_ image: UIImage?, key: Key, id: UUID) {
        activeLoads -= 1
        defer { startQueuedLoads() }
        guard pending[key]?.id == id, let request = pending.removeValue(forKey: key) else { return }
        let final = image ?? request.preview
        remember(final, for: key, lifetime: final == nil ? 2 : 6 * 3600)
        for continuation in request.waiters.values {
            if let final { continuation.yield(final) }
            continuation.finish()
        }
    }

    private func remember(_ image: UIImage?, for key: Key, lifetime: TimeInterval) {
        cache[key] = Cached(image: image, expiresAt: Date().addingTimeInterval(lifetime), lastUsed: Date())
        // A few gallery originals must not turn the thumbnail cache into hundreds of MB.
        while cache.count > 48 || cache.values.reduce(0, { $0 + $1.decodedBytes }) > 64 * 1024 * 1024 {
            guard let oldest = cache.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key else { break }
            cache[oldest] = nil
        }
    }

    nonisolated private static func load(urls: [URL], productOnly: Bool, maxSide: Int,
        onPreview: @Sendable (UIImage) async -> Void) async -> UIImage? {
        var deadline = Date().addingTimeInterval(22)
        var fallback: UIImage?
        for url in urls {
            guard !Task.isCancelled, Date() < deadline else { return fallback }
            do {
                let data = try await previewData(url, timeout: fallback == nil ? 6 : 2, deadline: deadline)
                try Task.checkCancellation()
                guard let image = downsample(data, maxSide: maxSide), let cg = image.cgImage else { continue }
                if fallback == nil {
                    fallback = image
                    await onPreview(image)
                    deadline = min(deadline, Date().addingTimeInterval(3))
                }
                if !productOnly || looksLikeProductPhoto(cg) { return image }
            } catch is CancellationError { return nil }
            catch { continue }
        }
        return fallback
    }

    /// Import a useful wardrobe-sized original; no catalog-wide prefetching.
    nonisolated static func wardrobePhoto(for product: ShopProduct) async -> UIImage? {
        let urls = ([product.imageURL?.absoluteString].compactMap { $0 } + (product.item.images ?? []))
        var seen = Set<String>()
        for raw in urls.filter({ seen.insert($0).inserted }).prefix(3) {
            guard !Task.isCancelled, let url = URL(string: raw), isWebURL(url) else { continue }
            if let data = try? await previewData(url, timeout: 7, deadline: Date().addingTimeInterval(9)),
               let image = downsample(data, maxSide: 1600) { return image }
        }
        return nil
    }

    nonisolated private static func downsample(_ data: Data, maxSide: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    nonisolated private static func previewData(_ url: URL, timeout: TimeInterval, deadline: Date) async throws -> Data {
        let byteLimit = 5 * 1024 * 1024
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: timeout)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await previewSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.mimeType?.lowercased().hasPrefix("image/") == true,
              response.expectedContentLength <= Int64(byteLimit), response.url.map(isWebURL) == true else {
            bytes.task.cancel(); throw URLError(.badServerResponse)
        }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        do {
            for try await byte in bytes {
                guard data.count < byteLimit else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(byte)
                if data.count % (32 * 1024) == 0 {
                    try Task.checkCancellation()
                    if Date() > deadline { throw URLError(.timedOut) }
                }
            }
            try Task.checkCancellation()
            guard !data.isEmpty else { throw URLError(.zeroByteResource) }
            return data
        } catch { bytes.task.cancel(); throw error }
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
        // studio frame and a visible foreground object; uncertain crops keep the first usable shop photo.
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
