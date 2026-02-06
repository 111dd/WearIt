import UIKit
import CoreImage
import Vision
import os.log

private let logger = Logger(subsystem: "WearIt", category: "ImageMasking")

enum ImageMasking {
    private static let ciContext = CIContext()
    
    struct DebugInfo {
        let originalSize: CGSize
        let maskSize: CGSize
        let boundingBox: CGRect
        let foregroundRatio: Double
    }
    
    static func applyMaskAndCrop(
        image: UIImage,
        mask: CGImage,
        debug: Bool = false
    ) throws -> (cutout: UIImage, preview: UIImage, boundingBox: CGRect, debugInfo: DebugInfo?) {
        guard let inputCIImage = CIImage(image: image) else {
            throw ClothingAIError.processingFailed("Invalid input image")
        }
        
        let originalSize = inputCIImage.extent.size
        let maskSize = CGSize(width: mask.width, height: mask.height)
        
        logger.debug("Processing - Image: \(Int(originalSize.width))x\(Int(originalSize.height)), Mask: \(mask.width)x\(mask.height)")
        
        var ciMask = CIImage(cgImage: mask)
        
        // 1. Threshold and smooth the mask (relaxed threshold for better detection)
        ciMask = ciMask.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.3])
        ciMask = ciMask.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 1.5])
        ciMask = ciMask.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.4])

        // 2. Align mask to original image coordinates
        let scaleX = inputCIImage.extent.width / ciMask.extent.width
        let scaleY = inputCIImage.extent.height / ciMask.extent.height
        let resizedMask = ciMask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        // 3. Compute bounding box from mask pixels (primary method)
        let (boundingBox, foregroundRatio) = computeBoundingBoxFromPixels(
            mask: mask,
            targetSize: originalSize
        )
        
        logger.debug("Bounding box: \(Int(boundingBox.minX)),\(Int(boundingBox.minY)) \(Int(boundingBox.width))x\(Int(boundingBox.height)), foreground: \(String(format: "%.1f", foregroundRatio * 100))%")
        
        // Create debug info
        let debugInfo: DebugInfo? = debug ? DebugInfo(
            originalSize: originalSize,
            maskSize: maskSize,
            boundingBox: boundingBox,
            foregroundRatio: foregroundRatio
        ) : nil
        
        // 4. Validate detection (relaxed thresholds)
        let minSize: CGFloat = 30.0  // Reduced from 50
        let minForegroundRatio = 0.005  // At least 0.5% of image should be foreground
        
        if boundingBox.width < minSize || boundingBox.height < minSize {
            logger.warning("Bounding box too small: \(Int(boundingBox.width))x\(Int(boundingBox.height))")
            throw ClothingAIError.noItemDetected
        }
        
        if foregroundRatio < minForegroundRatio {
            logger.warning("Foreground ratio too low: \(String(format: "%.2f", foregroundRatio * 100))%")
            throw ClothingAIError.noItemDetected
        }
        
        // 5. Apply mask as alpha channel
        guard let blendFilter = CIFilter(name: "CIBlendWithAlphaMask") else {
            throw ClothingAIError.processingFailed("Filter not available")
        }
        blendFilter.setValue(inputCIImage, forKey: kCIInputImageKey)
        blendFilter.setValue(resizedMask, forKey: kCIInputMaskImageKey)
        
        guard let outputImage = blendFilter.outputImage else {
            throw ClothingAIError.processingFailed("Failed to apply mask")
        }
        
        // 6. Add padding (10%)
        let paddingX = boundingBox.width * 0.10
        let paddingY = boundingBox.height * 0.10
        let paddedBox = boundingBox.insetBy(dx: -paddingX, dy: -paddingY).intersection(inputCIImage.extent)
        
        // 7. Render cutout
        guard let cgImage = ciContext.createCGImage(outputImage, from: inputCIImage.extent) else {
            throw ClothingAIError.processingFailed("Failed to render output image")
        }
        let cutout = UIImage(cgImage: cgImage)
        
        // 8. Crop for preview
        guard let croppedCgImage = cgImage.cropping(to: paddedBox) else {
            throw ClothingAIError.processingFailed("Failed to crop image")
        }
        let preview = UIImage(cgImage: croppedCgImage)
        
        logger.info("Successfully processed image with bbox: \(Int(paddedBox.width))x\(Int(paddedBox.height))")
        
        return (cutout, preview, paddedBox, debugInfo)
    }
    
    // Convenience overload without debug
    static func applyMaskAndCrop(image: UIImage, mask: CGImage) throws -> (cutout: UIImage, preview: UIImage, boundingBox: CGRect) {
        let result = try applyMaskAndCrop(image: image, mask: mask, debug: false)
        return (result.cutout, result.preview, result.boundingBox)
    }
    
    // MARK: - Pixel-based Bounding Box (Primary & Most Reliable)
    
    private static func computeBoundingBoxFromPixels(mask: CGImage, targetSize: CGSize) -> (CGRect, Double) {
        let width = mask.width
        let height = mask.height
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return (CGRect(origin: .zero, size: targetSize), 0)
        }
        
        context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let data = context.data else {
            return (CGRect(origin: .zero, size: targetSize), 0)
        }
        
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        
        var minX = width
        var maxX = 0
        var minY = height
        var maxY = 0
        var foregroundCount = 0
        let totalPixels = width * height
        
        // Threshold for considering a pixel as foreground (relaxed)
        let threshold: UInt8 = 50
        
        for y in 0..<height {
            for x in 0..<width {
                let pixel = pixels[y * width + x]
                if pixel > threshold {
                    foregroundCount += 1
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        
        let foregroundRatio = Double(foregroundCount) / Double(totalPixels)
        
        // If no foreground found, return full size
        guard foregroundCount > 0, minX < maxX, minY < maxY else {
            logger.warning("No foreground pixels detected in mask")
            return (CGRect(origin: .zero, size: targetSize), 0)
        }
        
        // Convert mask coordinates to target image coordinates
        let scaleX = targetSize.width / CGFloat(width)
        let scaleY = targetSize.height / CGFloat(height)
        
        // Note: CGImage coordinates have origin at top-left
        // CIImage coordinates have origin at bottom-left
        // We need to flip Y for CIImage compatibility
        let flippedMinY = height - maxY - 1
        let flippedMaxY = height - minY - 1
        
        let bbox = CGRect(
            x: CGFloat(minX) * scaleX,
            y: CGFloat(flippedMinY) * scaleY,
            width: CGFloat(maxX - minX + 1) * scaleX,
            height: CGFloat(flippedMaxY - flippedMinY + 1) * scaleY
        )
        
        return (bbox, foregroundRatio)
    }
}
