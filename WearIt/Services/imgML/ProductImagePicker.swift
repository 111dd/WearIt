//
//  ProductImagePicker.swift
//  WearIt
//
//  Picks the best of a shop's product photos for the wardrobe: the item on
//  its own (no model) on a plain background beats a styled model shot, which
//  is usually the first photo on the page. Uses Vision on small thumbnails.
//

import UIKit
import Vision

enum ProductImagePicker {
    private static let maxCandidates = 6

    /// The best photo, or nil when none could be downloaded.
    static func bestImage(from urls: [URL]) async -> UIImage? {
        await rankedImages(from: urls, limit: 1).first
    }

    /// Up to `limit` different photos, best for the wardrobe first; the rest
    /// keep the shop's order (other angles, details).
    static func rankedImages(from urls: [URL], limit: Int) async -> [UIImage] {
        let candidates = Array(urls.prefix(maxCandidates))
        guard !candidates.isEmpty, limit > 0 else { return [] }
        if candidates.count == 1 {
            return await download(candidates[0]).map { [$0] } ?? []
        }

        let downloaded: [(index: Int, image: UIImage)] = await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask { (index, await download(url)) }
            }
            var results: [(index: Int, image: UIImage)] = []
            for await (index, image) in group {
                if let image { results.append((index, image)) }
            }
            return results
        }
        guard !downloaded.isEmpty else { return [] }

        return await Task.detached(priority: .userInitiated) {
            let ordered = downloaded.sorted { $0.index < $1.index }
            let scored = ordered.map { (image: $0.image, score: score($0.image) - Double($0.index) * 0.05) }
            guard let best = scored.max(by: { $0.score < $1.score })?.image else { return [] }
            var picked = [best]
            var signatures = [signature(best)]
            for candidate in ordered where picked.count < limit {
                let sig = signature(candidate.image)
                // Same photo at another size or crop → skip.
                guard !signatures.contains(where: { isSimilar($0, sig) }) else { continue }
                picked.append(candidate.image)
                signatures.append(sig)
            }
            return picked
        }.value
    }

    /// 16×16 grayscale fingerprint for spotting the same photo twice.
    private static func signature(_ image: UIImage) -> [UInt8] {
        let side = 16
        guard let cg = thumbnail(image),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return [] }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return [] }
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: side * side), count: side * side))
    }

    private static func isSimilar(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        let difference = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(difference) / Double(a.count) < 8
    }

    /// The large version of a shop photo, else the link as given.
    private static func download(_ url: URL) async -> UIImage? {
        let large = highResolution(url)
        if large != url, let image = try? await BarcodeLookupService.downloadImage(from: large) {
            return image
        }
        return try? await BarcodeLookupService.downloadImage(from: url)
    }

    /// Shops link small previews (`og:image` is often ~600 px). Ask their image
    /// CDNs for a large rendition: Cloudinary `h_630,w_…`, Shopify `_600x` /
    /// `width=`, Magento `/cache/<hash>/`, and `w=` / `width=` / `h=` queries.
    static func highResolution(_ url: URL, target: Double = 2000) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var path = components.path

        // Magento: /pub/media/catalog/product/cache/<hash>/a/b/file.jpg → the original upload.
        path = path.replacingOccurrences(of: #"/catalog/product/cache/[0-9a-f]{16,}/"#,
                                         with: "/catalog/product/", options: .regularExpression)
        // Shopify: file_600x800.jpg / file_600x.jpg → file.jpg
        if url.host?.contains("shopify") == true || path.contains("/cdn/shop/") {
            path = path.replacingOccurrences(of: #"_(?:\d+x\d*|x\d+)(?=\.[A-Za-z]+$)"#, with: "", options: .regularExpression)
        }
        // Cloudinary-style segment: c_fill,f_auto,h_630,q_80 — scale w_/h_ together.
        path = path.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            let text = String(segment)
            let sizes = text.matches(of: #/(?:^|,)([wh])_(\d+)/#).compactMap { Double($0.output.2) }
            guard let largest = sizes.max(), largest > 0, largest < target else { return text }
            let factor = target / largest
            return text.replacing(#/(^|,)([wh])_(\d+)/#) { match in
                "\(match.output.1)\(match.output.2)_\(Int((Double(match.output.3) ?? 0) * factor))"
            }
        }.joined(separator: "/")
        components.path = path

        if var items = components.queryItems {
            let keys: Set<String> = ["w", "width", "h", "height", "wid", "hei"]
            let sizes = items.filter { keys.contains($0.name.lowercased()) }.compactMap { $0.value.flatMap(Double.init) }
            if let largest = sizes.max(), largest > 0, largest < target {
                let factor = target / largest
                items = items.map { item in
                    guard keys.contains(item.name.lowercased()), let value = item.value.flatMap(Double.init) else { return item }
                    return URLQueryItem(name: item.name, value: String(Int(value * factor)))
                }
                components.queryItems = items
            }
        }
        return components.url ?? url
    }

    /// Higher is better: no person, plain background, a garment-shaped frame.
    private static func score(_ image: UIImage) -> Double {
        guard let cg = thumbnail(image) else { return 0 }
        var score = 0.0

        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let faces = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        try? handler.perform([humans, faces])
        let hasPerson = (humans.results ?? []).contains { $0.confidence > 0.5 && $0.boundingBox.height > 0.25 }
            || !(faces.results ?? []).isEmpty
        let frame = frameStats(cg)
        // An item on its own stands out from its background; a fabric close-up doesn't.
        if !hasPerson { score += frame.centerContrast > 12 ? 2 : 0.5 }
        score += frame.plainness
        // Detail crops (fabric close-ups, labels) are usually square-ish and busy;
        // a little bonus for portrait product frames.
        if cg.height >= cg.width { score += 0.2 }
        return score
    }

    /// plainness: 1 when the photo's edges are one flat color (studio background), 0 when busy.
    /// centerContrast: how far the middle differs from the edges (luminance 0–255).
    private static func frameStats(_ cg: CGImage) -> (plainness: Double, centerContrast: Double) {
        let side = 48
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0, 0) }
        context.interpolationQuality = .low
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return (0, 0) }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        var values: [Double] = []
        var center: [Double] = []
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                let luma = 0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])
                if x < 2 || y < 2 || x >= side - 2 || y >= side - 2 {
                    values.append(luma)
                } else if (side / 4..<side * 3 / 4).contains(x), (side / 4..<side * 3 / 4).contains(y) {
                    center.append(luma)
                }
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let centerMean = center.reduce(0, +) / Double(max(center.count, 1))
        return (max(0, 1 - variance.squareRoot() / 40), abs(centerMean - mean))
    }

    private static func thumbnail(_ image: UIImage) -> CGImage? {
        let longSide = max(image.size.width, image.size.height)
        guard longSide > 0 else { return nil }
        let scale = min(1, 384 / longSide)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }
}
