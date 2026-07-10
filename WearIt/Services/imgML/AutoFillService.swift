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
        let lower = label.lowercased()

        if lower.contains("jean") { return (.bottom, .jeans) }
        if lower.contains("short") { return (.bottom, .shorts) }
        if lower.contains("skirt") { return (.bottom, .skirt) }
        if lower.contains("trouser") || lower.contains("pant") || lower.contains("chino") {
            return (.bottom, .trousers)
        }
        if lower.contains("hoodie") { return (.top, .hoodie) }
        if lower.contains("sweater") || lower.contains("pullover") { return (.top, .sweater) }
        if lower.contains("t-shirt") || lower.contains("tshirt") || lower.contains("tee") {
            return (.top, .tshirt)
        }
        if lower.contains("shirt") || lower.contains("blouse") { return (.top, .shirt) }
        if lower.contains("jacket") || lower.contains("coat") || lower.contains("blazer") || lower.contains("parka") {
            return (.outer, .jacket)
        }
        if lower.contains("shoe") || lower.contains("sneaker") || lower.contains("boot") || lower.contains("loafer") {
            return (.shoes, .sneakers)
        }
        if lower.contains("bag") || lower.contains("handbag") { return (.accessory, .bag) }
        if lower.contains("hat") || lower.contains("cap") { return (.accessory, .hat) }
        if lower.contains("scarf") { return (.accessory, .scarf) }
        if lower.contains("dress") { return (.top, .blouse) }

        return (nil, nil)
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
        switch name.lowercased() {
        case "black": return .black
        case "white": return .white
        case "gray", "grey": return .gray
        case "navy": return .navy
        case "blue", "teal": return .blue
        case "lightblue", "light_blue", "light blue": return .lightBlue
        case "red": return .red
        case "pink": return .pink
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "olive": return .olive
        case "brown": return .brown
        case "beige": return .beige
        case "cream": return .cream
        case "burgundy": return .burgundy
        case "purple": return .purple
        case "denim": return .denim
        default: return nil
        }
    }
}
