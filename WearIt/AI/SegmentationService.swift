import UIKit
import Vision
import CoreML
import CoreImage
import os.log

private let logger = Logger(subsystem: "WearIt", category: "Segmentation")

enum SegmentationError: Error, LocalizedError {
    case noMaskDetected
    case invalidImage
    case processingFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noMaskDetected:
            return "Could not detect a clothing item. Try a plain background and one item per photo."
        case .invalidImage:
            return "Invalid image provided for segmentation."
        case .processingFailed(let message):
            return "Segmentation failed: \(message)"
        }
    }
}

final class SegmentationService {
    private var cachedModel: VNCoreMLModel?
    private let ciContext = CIContext()

    init() {
        // Pre-load custom model if available
        if let model = try? ClothingSegmentation(configuration: MLModelConfiguration()).model {
            self.cachedModel = try? VNCoreMLModel(for: model)
            logger.info("Custom ClothingSegmentation model loaded")
        }
    }

    func generateMask(for image: UIImage) throws -> CGImage {
        guard let cgImage = image.cgImage else {
            throw SegmentationError.invalidImage
        }
        
        logger.debug("Generating mask for image: \(cgImage.width)x\(cgImage.height)")

        // 1. Try ClothingSegmentation Core ML model first (if available)
        if let model = cachedModel {
            if let mask = try? generateMaskWithCoreML(cgImage: cgImage, model: model) {
                logger.info("Used custom Core ML model for segmentation")
                return mask
            }
        }

        // 2. Use iOS 17+ Foreground Instance Mask (primary fallback)
        if #available(iOS 17.0, *) {
            do {
                let mask = try generateForegroundMask(cgImage: cgImage)
                logger.info("Used VNGenerateForegroundInstanceMaskRequest")
                return mask
            } catch {
                logger.warning("Foreground mask failed: \(error.localizedDescription)")
            }
        }

        // 3. Fallback to Person Segmentation (less ideal for standalone clothes)
        do {
            let mask = try generatePersonSegmentationMask(cgImage: cgImage)
            logger.info("Used VNGeneratePersonSegmentationRequest fallback")
            return mask
        } catch {
            logger.error("All segmentation methods failed")
            throw SegmentationError.noMaskDetected
        }
    }

    // MARK: - iOS 17+ Foreground Instance Mask (Primary)

    @available(iOS 17.0, *)
    private func generateForegroundMask(cgImage: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first else {
            throw SegmentationError.noMaskDetected
        }

        // Generate scaled mask that matches original image dimensions
        let allInstances = observation.allInstances
        let maskPixelBuffer = try observation.generateScaledMaskForImage(
            forInstances: allInstances,
            from: handler
        )
        
        let maskImage = CIImage(cvPixelBuffer: maskPixelBuffer)

        guard let outputCGImage = ciContext.createCGImage(maskImage, from: maskImage.extent) else {
            throw SegmentationError.processingFailed("Failed to render foreground mask")
        }

        logger.debug("Foreground mask created: \(outputCGImage.width)x\(outputCGImage.height)")
        return outputCGImage
    }

    // MARK: - Person Segmentation Fallback (iOS 15+)

    private func generatePersonSegmentationMask(cgImage: CGImage) throws -> CGImage {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let pixelBuffer = request.results?.first?.pixelBuffer else {
            throw SegmentationError.noMaskDetected
        }

        let maskImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Scale mask to match original image size
        let scaleX = CGFloat(cgImage.width) / maskImage.extent.width
        let scaleY = CGFloat(cgImage.height) / maskImage.extent.height

        let scaledMask = maskImage.transformed(
            by: CGAffineTransform(scaleX: scaleX, y: scaleY)
        )

        guard let outputCGImage = ciContext.createCGImage(scaledMask, from: scaledMask.extent) else {
            throw SegmentationError.processingFailed("Failed to render person mask")
        }

        return outputCGImage
    }

    // MARK: - Custom Core ML Model (Optional)

    private func generateMaskWithCoreML(cgImage: CGImage, model: VNCoreMLModel) throws -> CGImage {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let result = request.results?.first as? VNPixelBufferObservation else {
            throw SegmentationError.noMaskDetected
        }

        let maskImage = CIImage(cvPixelBuffer: result.pixelBuffer)

        // Scale to original image size if needed
        let scaleX = CGFloat(cgImage.width) / maskImage.extent.width
        let scaleY = CGFloat(cgImage.height) / maskImage.extent.height

        let scaledMask = maskImage.transformed(
            by: CGAffineTransform(scaleX: scaleX, y: scaleY)
        )

        guard let outputCGImage = ciContext.createCGImage(scaledMask, from: scaledMask.extent) else {
            throw SegmentationError.processingFailed("Failed to render Core ML mask")
        }

        return outputCGImage
    }
}

// MARK: - Model Stub (Remove when adding real .mlmodel)

/// Placeholder for ClothingSegmentation.mlmodel
/// Xcode will auto-generate this class when you add the model file.
class ClothingSegmentation {
    let model: MLModel
    init(configuration: MLModelConfiguration) throws {
        throw NSError(domain: "ClothingSegmentation", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Model not available. Add ClothingSegmentation.mlmodel to enable."])
    }
}

