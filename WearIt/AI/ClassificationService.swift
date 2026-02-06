import UIKit
import Vision
import CoreML

final class ClassificationService {
    private var cachedModel: VNCoreMLModel?
    private let confidenceThreshold: Float = 0.35

    init() {
        if let model = try? ClothingClassifier(configuration: MLModelConfiguration()).model {
            self.cachedModel = try? VNCoreMLModel(for: model)
        }
    }

    func classify(image: UIImage) throws -> (ClothingCategory, Float) {
        guard let cgImage = image.cgImage else {
            throw ClothingAIError.processingFailed("Invalid image for classification")
        }

        guard let model = cachedModel else {
            // Fallback if model not present
            return (.other, 0.0)
        }

        let request = VNCoreMLRequest(model: model)
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let results = request.results as? [VNClassificationObservation],
              let topResult = results.first else {
            return (.other, 0.0)
        }

        if topResult.confidence < confidenceThreshold {
            return (.other, topResult.confidence)
        }

        let category = mapLabelToCategory(topResult.identifier)
        return (category, topResult.confidence)
    }

    private func mapLabelToCategory(_ label: String) -> ClothingCategory {
        let lower = label.lowercased()
        if lower.contains("t-shirt") || lower.contains("tee") { return .tshirt }
        if lower.contains("shirt") { return .shirt }
        if lower.contains("hoodie") { return .hoodie }
        if lower.contains("sweater") { return .sweater }
        if lower.contains("jacket") || lower.contains("coat") { return .jacket }
        if lower.contains("pants") || lower.contains("trousers") { return .pants }
        if lower.contains("jeans") { return .jeans }
        if lower.contains("shorts") { return .shorts }
        if lower.contains("skirt") { return .skirt }
        if lower.contains("dress") { return .dress }
        if lower.contains("shoe") || lower.contains("sneaker") || lower.contains("boot") { return .shoes }
        if lower.contains("bag") || lower.contains("handbag") { return .bag }
        if lower.contains("hat") || lower.contains("cap") { return .hat }
        return .other
    }
}

// MARK: - Model Stub (Remove when adding real .mlmodel)

/// Placeholder for ClothingClassifier.mlmodel
/// Xcode will auto-generate this class when you add the model file.
class ClothingClassifier {
    let model: MLModel
    init(configuration: MLModelConfiguration) throws {
        throw NSError(domain: "ClothingClassifier", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Model not available. Add ClothingClassifier.mlmodel to enable."])
    }
}
