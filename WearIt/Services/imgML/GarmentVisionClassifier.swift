//
//  GarmentVisionClassifier.swift
//  WearIt
//
//  Instant garment category / type from Apple's built-in image classifier
//  (`VNClassifyImageRequest`, ~1,300 labels such as jeans, sneaker, coat,
//  handbag). No bundled model, works on every supported device. Labels are
//  mapped through `ProductFieldMapper` like any other product text.
//

import UIKit
import Vision

struct GarmentVisionGuess {
    let category: Category
    let itemType: ItemType?
    let confidence: Float
}

enum GarmentVisionClassifier {
    private static let minimumConfidence: Float = 0.12
    /// Labels too generic to say which garment this is.
    private static let genericLabels: Set<String> = [
        "clothing", "apparel", "textile", "fabric", "adult", "people", "person", "costume", "fashion"
    ]

    /// `image` may be a transparent cutout; it is classified on white.
    static func classify(_ image: UIImage, categoryHint: Category? = nil) -> GarmentVisionGuess? {
        guard let cg = onWhite(image) else { return nil }
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return nil }

        var fallback: GarmentVisionGuess?
        for observation in observations.prefix(40) where observation.confidence >= minimumConfidence {
            let label = observation.identifier.replacingOccurrences(of: "_", with: " ").lowercased()
            guard !genericLabels.contains(label),
                  let category = ProductFieldMapper.mapCategory(path: label, title: nil),
                  !label.contains("clothing") else { continue }
            let guess = GarmentVisionGuess(
                category: category,
                itemType: ProductFieldMapper.mapItemType(path: label, title: nil, category: category),
                confidence: observation.confidence
            )
            // A body band already says top / bottom / shoes; take the best label that agrees.
            if let categoryHint, category != categoryHint {
                if fallback == nil, categoryHint == .top, category == .outer { fallback = guess }
                continue
            }
            return guess
        }
        if let categoryHint {
            return fallback ?? GarmentVisionGuess(category: categoryHint, itemType: nil, confidence: 0.3)
        }
        return nil
    }

    static func onWhite(_ image: UIImage, maxSide: CGFloat = 512) -> CGImage? {
        let longSide = max(image.size.width, image.size.height)
        guard longSide > 0 else { return nil }
        let scale = min(1, maxSide / longSide)
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
