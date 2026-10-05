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
        let candidates = Array(urls.prefix(maxCandidates))
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 {
            return try? await BarcodeLookupService.downloadImage(from: candidates[0])
        }

        let downloaded: [(index: Int, image: UIImage)] = await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask { (index, try? await BarcodeLookupService.downloadImage(from: url)) }
            }
            var results: [(index: Int, image: UIImage)] = []
            for await (index, image) in group {
                if let image { results.append((index, image)) }
            }
            return results
        }
        guard !downloaded.isEmpty else { return nil }

        return await Task.detached(priority: .userInitiated) {
            downloaded
                .map { (image: $0.image, score: score($0.image) - Double($0.index) * 0.05) }
                .max { $0.score < $1.score }?
                .image
        }.value
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
