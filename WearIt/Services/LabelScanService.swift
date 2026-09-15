//
//  LabelScanService.swift
//  WearIt
//
//  Care-label scanning: point the camera at a garment's label and extract
//  brand, size and materials without typing. Vision OCR provides the text;
//  a deterministic parser handles materials/size, and Foundation Models
//  (when available) improves brand detection from the raw label text.
//

import Foundation
import UIKit
import Vision

struct LabelScanResult: Sendable, Equatable {
    var brand: String?
    var size: SizeOption?
    var materials: [MaterialTag]

    var isEmpty: Bool {
        brand == nil && size == nil && materials.isEmpty
    }
}

enum LabelScanService {
    /// Full pipeline: OCR → deterministic parse → optional AI brand pass.
    static func scan(image: UIImage) async -> LabelScanResult {
        let lines = await recognizeText(in: image)
        guard !lines.isEmpty else { return LabelScanResult(brand: nil, size: nil, materials: []) }

        var result = parse(lines: lines)

        // Brand is the one field heuristics can't reliably find — a label's
        // brand is an arbitrary proper noun. Let the on-device model try.
        if result.brand == nil, #available(iOS 26.0, *), LookExplanationAvailability.isSupported {
            let text = lines.joined(separator: "\n")
            if let brand = await LookExplanationService.shared.extractBrandFromLabel(text: text) {
                result.brand = brand
            }
        }
        return result
    }

    // MARK: - OCR

    static func recognizeText(in image: UIImage) async -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            do {
                try handler.perform([request])
            } catch {
                return []
            }
            let observations = request.results ?? []
            return observations.compactMap { $0.topCandidates(1).first?.string }
        }.value
    }

    // MARK: - Deterministic parsing (unit-testable)

    /// Extracts materials and size from OCR lines using keyword matching.
    static func parse(lines: [String]) -> LabelScanResult {
        let joined = lines.joined(separator: " ").lowercased()

        var materials: [MaterialTag] = []
        for material in MaterialTag.allCases where joined.contains(material.rawValue) {
            materials.append(material)
        }
        // Common label spellings that differ from our raw values.
        if joined.contains("elastane") || joined.contains("lycra") {
            if !materials.contains(.spandex) { materials.append(.spandex) }
        }
        if joined.contains("viscose") || joined.contains("rayon") {
            if !materials.contains(.polyester) { materials.append(.polyester) }
        }

        return LabelScanResult(
            brand: nil,
            size: detectSize(in: lines),
            materials: Array(materials.prefix(3))
        )
    }

    private static func detectSize(in lines: [String]) -> SizeOption? {
        let letterSizes: [String: SizeOption] = [
            "xs": .xs, "s": .s, "m": .m, "l": .l, "xl": .xl, "xxl": .xxl, "2xl": .xxl
        ]
        for line in lines {
            let tokens = line
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            // A size letter is only trustworthy standing alone or next to
            // the word "size", otherwise every "L" in "LAVAGE" would match.
            for (index, token) in tokens.enumerated() {
                if let size = letterSizes[token] {
                    let isIsolated = tokens.count <= 2
                    let followsSizeWord = index > 0 && (tokens[index - 1] == "size" || tokens[index - 1] == "taille")
                    if isIsolated || followsSizeWord {
                        return size
                    }
                }
                // Waist sizes: W32, 32W
                if token.hasPrefix("w"), let value = Int(token.dropFirst()),
                   let size = SizeOption(rawValue: "w\(value)") {
                    return size
                }
                // EU shoe sizes: EU 42 / EUR42
                if token == "eu" || token == "eur", index + 1 < tokens.count,
                   let value = Int(tokens[index + 1]),
                   let size = SizeOption(rawValue: "eu\(value)") {
                    return size
                }
            }
        }
        return nil
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
