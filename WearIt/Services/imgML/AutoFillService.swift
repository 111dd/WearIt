//
//  AutoFillService.swift
//  WearIt
//
//  Best-effort on-device autofill for Add Garment, in two speeds:
//  1. `suggest` (instant): smart cutout with choices (`GarmentCutoutService`),
//     built-in Vision classifier for category/type, dominant colors.
//  2. `refine` (a few seconds, iOS 27 + Apple Intelligence): Foundation Models
//     looks at the cutout and returns category, type, colors, pattern, sleeve
//     length and fit, validated against the app's vocabulary.
//

import Foundation
import UIKit

struct AutoFillSuggestion {
    var displayImage: UIImage
    var cutoutImage: UIImage?
    var category: Category?
    var itemType: ItemType?
    var colorTags: [ColorTag]
    var confidence: Float
    var usedCutout: Bool
    /// Every way the photo can be cut (several items, top / bottom / shoes of a selfie).
    var candidates: [CutoutCandidate] = []
    var selectedCandidateIndex = 0
    var qualityIssues: [CutoutQualityIssue] = []

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

/// What Foundation Models saw, already mapped to the app's vocabulary.
struct AutoFillRefinement {
    var category: Category?
    var itemType: ItemType?
    var colorTags: [ColorTag]
    var pattern: PatternTag?
    var sleeveLength: SleeveLength?
    var fit: FitTag?
}

enum AutoFillService {
    /// Cutout + classification + colors off the main actor.
    static func suggest(from image: UIImage, preferredCategory: Category? = nil) async -> AutoFillSuggestion {
        await Task.detached(priority: .userInitiated) {
            buildSuggestion(from: image, preferredCategory: preferredCategory)
        }.value
    }

    /// Re-describe one cutout choice (the user tapped a different item).
    static func describe(_ candidate: CutoutCandidate, in suggestion: AutoFillSuggestion) async -> AutoFillSuggestion {
        await Task.detached(priority: .userInitiated) {
            var result = describe(candidate.image, categoryHint: candidate.categoryHint, usedCutout: true)
            result.candidates = suggestion.candidates
            result.selectedCandidateIndex = suggestion.candidates.firstIndex { $0.id == candidate.id } ?? 0
            result.qualityIssues = suggestion.qualityIssues
            return result
        }.value
    }

    private static func buildSuggestion(from image: UIImage, preferredCategory: Category?) -> AutoFillSuggestion {
        if let cutout = GarmentCutoutService.analyze(image, preferredCategory: preferredCategory) {
            var result = describe(cutout.selected.image, categoryHint: cutout.selected.categoryHint, usedCutout: true)
            result.candidates = cutout.candidates
            result.selectedCandidateIndex = cutout.selectedIndex
            result.qualityIssues = cutout.issues
            return result
        }
        // Simulator / no subject found: chroma-key fallback, then the photo itself.
        let fallback = try? ImageCutout.removeBackground(from: image)
        return describe(fallback ?? image, categoryHint: nil, usedCutout: fallback != nil)
    }

    private static func describe(_ image: UIImage, categoryHint: Category?, usedCutout: Bool) -> AutoFillSuggestion {
        let guess = GarmentVisionClassifier.classify(image, categoryHint: categoryHint)
        let colors = AutoFillMapper.colorTags(from: ColorExtractor.extract(from: image, maxColors: 3))
        return AutoFillSuggestion(
            displayImage: image,
            cutoutImage: usedCutout ? image : nil,
            category: guess?.category,
            itemType: guess?.itemType,
            colorTags: colors,
            confidence: guess?.confidence ?? 0,
            usedCutout: usedCutout
        )
    }

    // MARK: - Foundation Models refinement

    /// nil when the on-device model can't see images here (before iOS 27, no
    /// Apple Intelligence) or isn't sure. Never blocks the instant result.
    static func refine(_ image: UIImage, categoryHint: Category?) async -> AutoFillRefinement? {
        guard #available(iOS 27.0, *) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wearit-understand-\(UUID().uuidString).jpg")
        let written: Bool = await Task.detached(priority: .utility) {
            guard let cg = GarmentVisionClassifier.onWhite(image, maxSide: 1024),
                  let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85) else { return false }
            return (try? data.write(to: url)) != nil
        }.value
        guard written else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }

        guard let raw = await GarmentImageUnderstandingService.shared.analyze(
            imageURL: url, vocabulary: vocabulary(categoryHint: categoryHint)
        ) else { return nil }
        return map(raw, categoryHint: categoryHint)
    }

    private static func vocabulary(categoryHint: Category?) -> String {
        let categories = categoryHint.map { [$0] } ?? Category.allCases
        let types = categories.flatMap { category in
            category.itemTypes.filter { $0 != .other }.map { "\(category.rawValue): \($0.rawValue)" }
        }
        return """
        Allowed categories: \(categories.map(\.rawValue).joined(separator: ", ")), unknown.
        Allowed item types (category: type): \(types.joined(separator: "; ")), unknown.
        Allowed colors: \(ColorTag.allCases.map(\.rawValue).joined(separator: ", ")).
        Allowed patterns: \(PatternTag.allCases.map(\.rawValue).joined(separator: ", ")), unknown.
        Allowed sleeve lengths: \(SleeveLength.allCases.map(\.rawValue).joined(separator: ", ")), unknown.
        Allowed fits: \(FitTag.allCases.map(\.rawValue).joined(separator: ", ")), unknown.
        """
    }

    @available(iOS 27.0, *)
    private static func map(_ raw: GarmentImageUnderstandingResult, categoryHint: Category?) -> AutoFillRefinement? {
        var category = Category(rawValue: raw.category)
        if let categoryHint, category != categoryHint { category = categoryHint }
        var itemType = ItemType(rawValue: raw.itemType)
        if let type = itemType, type == .other || !(category?.itemTypes.contains(type) ?? false) {
            itemType = nil
        }
        var colors: [ColorTag] = []
        for color in raw.colors.compactMap({ ColorTag(rawValue: $0) }) where !colors.contains(color) {
            colors.append(color)
        }
        let refinement = AutoFillRefinement(
            category: category,
            itemType: itemType,
            colorTags: Array(colors.prefix(3)),
            pattern: PatternTag(rawValue: raw.pattern),
            sleeveLength: category == .top ? SleeveLength(rawValue: raw.sleeveLength) : nil,
            fit: FitTag(rawValue: raw.fit)
        )
        let saidNothing = refinement.category == nil && refinement.colorTags.isEmpty && refinement.pattern == nil
        return saidNothing ? nil : refinement
    }
}

enum AutoFillMapper {
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
        return tags
    }

    static func colorTag(fromDominantName name: String) -> ColorTag? {
        ProductFieldMapper.matchColor(name)
    }
}
