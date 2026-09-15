//
//  AutoFillService.swift
//  WearIt
//
//  Best-effort on-device autofill for Add Garment:
//  cutout → dominant colors → category/item type (when a model is available).
//

import Foundation
import UIKit

struct AutoFillSuggestion: Equatable {
    var displayImage: UIImage
    var cutoutImage: UIImage?
    var category: Category?
    var itemType: ItemType?
    var colorTags: [ColorTag]
    var confidence: Float
    var usedCutout: Bool

    static func empty(from image: UIImage) -> AutoFillSuggestion {
        AutoFillSuggestion(
            displayImage: image,
            cutoutImage: nil,
            category: nil,
            itemType: nil,
            colorTags: [],
            confidence: 0,
            usedCutout: false
        )
    }
}

enum AutoFillService {
    /// Runs cutout + color extraction + optional classification off the main actor.
    static func suggest(from image: UIImage) async -> AutoFillSuggestion {
        await Task.detached(priority: .userInitiated) {
            await buildSuggestion(from: image)
        }.value
    }

    private static func buildSuggestion(from image: UIImage) async -> AutoFillSuggestion {
        var cutout: UIImage?
        var category: Category?
        var itemType: ItemType?
        var confidence: Float = 0

        do {
            let result = try await ClothingAIPipeline().process(image: image, includeDebugData: false)
            cutout = UIImage(data: result.cutoutPNGData)
            let mapped = AutoFillMapper.mapClothingCategory(result.category)
            category = mapped.category
            itemType = mapped.itemType
            confidence = result.confidence
        } catch {
            cutout = try? ImageCutout.removeBackground(from: image)
        }

        let analyzeImage = cutout ?? image
        if confidence < 0.35, let prediction = await GarmentMLClassifier.classify(analyzeImage) {
            let mapped = AutoFillMapper.mapClassifierLabel(prediction.label)
            if let mappedCategory = mapped.category {
                category = mappedCategory
                itemType = mapped.itemType
                confidence = max(confidence, prediction.confidence)
            }
        }

        let dominant = ColorExtractor.extract(from: analyzeImage, maxColors: 3)
        let colors = AutoFillMapper.colorTags(from: dominant)

        let usedCutout = cutout != nil
        return AutoFillSuggestion(
            displayImage: cutout ?? image,
            cutoutImage: cutout,
            category: category,
            itemType: itemType,
            colorTags: colors,
            confidence: confidence,
            usedCutout: usedCutout
        )
    }
}

enum AutoFillMapper {
    static func mapClothingCategory(_ value: ClothingCategory) -> (category: Category?, itemType: ItemType?) {
        switch value {
        case .tshirt: return (.top, .tshirt)
        case .shirt: return (.top, .shirt)
        case .hoodie: return (.top, .hoodie)
        case .sweater: return (.top, .sweater)
        case .jacket: return (.outer, .jacket)
        case .pants: return (.bottom, .trousers)
        case .jeans: return (.bottom, .jeans)
        case .shorts: return (.bottom, .shorts)
        case .skirt: return (.bottom, .skirt)
        case .dress: return (.top, .blouse)
        case .shoes: return (.shoes, .sneakers)
        case .bag: return (.accessory, .bag)
        case .hat: return (.accessory, .hat)
        case .other: return (nil, nil)
        }
    }

    static func mapClassifierLabel(_ label: String) -> (category: Category?, itemType: ItemType?) {
        let path = label
        let category = ProductFieldMapper.mapCategory(path: path, title: nil)
        let itemType = ProductFieldMapper.mapItemType(path: path, title: nil, category: category)
        return (category, itemType)
    }

    static func colorTags(from dominant: [DominantColor]) -> [ColorTag] {
        var tags: [ColorTag] = []
        var seen = Set<ColorTag>()
        for color in dominant {
            guard let tag = colorTag(fromDominantName: color.name) else { continue }
            if seen.insert(tag).inserted {
                tags.append(tag)
            }
            if tags.count >= 3 { break }
        }
        if tags.count >= 2 {
            let topRatio = dominant.first?.ratio ?? 0
            if topRatio < 0.45, !seen.contains(.multicolor) {
                // Multiple strong colors → hint multicolor without replacing primaries
            }
        }
        return tags
    }

    static func colorTag(fromDominantName name: String) -> ColorTag? {
        ProductFieldMapper.matchColor(name)
    }
}
