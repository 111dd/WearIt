import UIKit
import Vision
import CoreML
import os.log

private let logger = Logger(subsystem: "WearIt", category: "AIPipeline")

enum ClothingCategory: String, Codable {
    case tshirt, shirt, hoodie, sweater, jacket
    case pants, jeans, shorts, skirt, dress
    case shoes, bag, hat
    case other
}

struct ClothingAIResult {
    let cutoutPNGData: Data          // transparent PNG
    let previewJPEGData: Data        // cropped preview JPEG
    let category: ClothingCategory
    let confidence: Float
    let debugMask: UIImage?          // For developer overlay
}

enum ClothingAIError: Error, LocalizedError {
    case noItemDetected
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noItemDetected:
            return "We couldn't clearly detect a single item.\n\nTry a plain background and one item per photo."
        case .processingFailed(let message):
            return "Processing failed: \(message)"
        }
    }
}

protocol ClothingAIPipelineProtocol {
    func process(image: UIImage, includeDebugData: Bool) async throws -> ClothingAIResult
}

final class ClothingAIPipeline: ClothingAIPipelineProtocol {
    private let segmentationService: SegmentationService
    private let classificationService: ClassificationService
    
    init(segmentationService: SegmentationService = SegmentationService(),
         classificationService: ClassificationService = ClassificationService()) {
        self.segmentationService = segmentationService
        self.classificationService = classificationService
    }
    
    func process(image: UIImage, includeDebugData: Bool = false) async throws -> ClothingAIResult {
        logger.info("Starting AI pipeline for image: \(Int(image.size.width))x\(Int(image.size.height))")
        
        // Run heavy processing on background thread
        return try await Task.detached(priority: .userInitiated) { [segmentationService, classificationService] in
            // 1. Normalize and resize image (max 1024px)
            let resizedImage = image.fixOrientation().resized(toMaxDimension: 1024)
            logger.debug("Resized to: \(Int(resizedImage.size.width))x\(Int(resizedImage.size.height))")
            
            // 2. Run segmentation to get mask
            let mask: CGImage
            do {
                mask = try segmentationService.generateMask(for: resizedImage)
                logger.debug("Mask generated: \(mask.width)x\(mask.height)")
            } catch {
                logger.error("Segmentation failed: \(error.localizedDescription)")
                throw error
            }
            
            // 3. Apply mask and crop
            let cutout: UIImage
            let preview: UIImage
            do {
                let result = try ImageMasking.applyMaskAndCrop(image: resizedImage, mask: mask, debug: includeDebugData)
                cutout = result.cutout
                preview = result.preview
                
                if let debugInfo = result.debugInfo {
                    logger.info("""
                        Debug Info:
                        - Original: \(Int(debugInfo.originalSize.width))x\(Int(debugInfo.originalSize.height))
                        - Mask: \(Int(debugInfo.maskSize.width))x\(Int(debugInfo.maskSize.height))
                        - BBox: \(Int(debugInfo.boundingBox.minX)),\(Int(debugInfo.boundingBox.minY)) \(Int(debugInfo.boundingBox.width))x\(Int(debugInfo.boundingBox.height))
                        - Foreground: \(String(format: "%.1f", debugInfo.foregroundRatio * 100))%
                        """)
                }
            } catch {
                logger.error("Masking/cropping failed: \(error.localizedDescription)")
                throw error
            }
            
            // 4. Classify the cropped preview
            let category: ClothingCategory
            let confidence: Float
            do {
                (category, confidence) = try classificationService.classify(image: preview)
                logger.debug("Classification: \(category.rawValue) (\(String(format: "%.1f", confidence * 100))%)")
            } catch {
                logger.warning("Classification failed, defaulting to .other: \(error.localizedDescription)")
                category = .other
                confidence = 0.0
            }
            
            guard let cutoutPNG = cutout.pngData(),
                  let previewJPEG = preview.jpegData(compressionQuality: 0.85) else {
                throw ClothingAIError.processingFailed("Failed to generate image data")
            }
            
            let debugMask = includeDebugData ? UIImage(cgImage: mask) : nil
            
            logger.info("Pipeline completed successfully")
            
            return ClothingAIResult(
                cutoutPNGData: cutoutPNG,
                previewJPEGData: previewJPEG,
                category: category,
                confidence: confidence,
                debugMask: debugMask
            )
        }.value
    }
}

// MARK: - UIImage Extensions

extension UIImage {
    func fixOrientation() -> UIImage {
        if imageOrientation == .up { return self }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return normalizedImage ?? self
    }

    func resized(toMaxDimension maxDim: CGFloat) -> UIImage {
        let aspectRatio = size.width / size.height
        var newSize: CGSize
        if aspectRatio > 1 {
            if size.width <= maxDim { return self }
            newSize = CGSize(width: maxDim, height: maxDim / aspectRatio)
        } else {
            if size.height <= maxDim { return self }
            newSize = CGSize(width: maxDim * aspectRatio, height: maxDim)
        }
        
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
