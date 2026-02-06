import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

enum CutoutError: Error, LocalizedError {
    case notAvailableOnThisOS, cgImageMissing, requestFailed, noMask, outputFailed, notSupportedOnSimulator

    var errorDescription: String? {
        switch self {
        case .notAvailableOnThisOS: return "Background removal requires iOS 17+"
        case .cgImageMissing:       return "Invalid image data"
        case .requestFailed:        return "Vision request failed"
        case .noMask:               return "No subject mask detected"
        case .outputFailed:         return "Failed to render output image"
        case .notSupportedOnSimulator: return "Not supported on Simulator. Please run on a real device."
        }
    }
}

// MARK: - Utilities

private func normalizeImage(_ uiImage: UIImage) -> UIImage {
    let fmt = UIGraphicsImageRendererFormat()
    fmt.scale = uiImage.scale
    fmt.opaque = false
    return UIGraphicsImageRenderer(size: uiImage.size, format: fmt).image { _ in
        uiImage.draw(in: CGRect(origin: .zero, size: uiImage.size))
    }
}

private func downscale(_ image: UIImage, maxSide: CGFloat) -> UIImage {
    let w = image.size.width, h = image.size.height
    let longSide = max(w, h)
    guard longSide > maxSide, longSide > 0 else { return image }
    let r = maxSide / longSide
    let newSize = CGSize(width: w*r, height: h*r)
    let fmt = UIGraphicsImageRendererFormat()
    fmt.scale = image.scale
    fmt.opaque = false
    return UIGraphicsImageRenderer(size: newSize, format: fmt).image { _ in
        image.draw(in: CGRect(origin: .zero, size: newSize))
    }
}

// MARK: - API

struct ImageCutout {
    static func removeBackground(from uiImage: UIImage) throws -> UIImage {
        var img = normalizeImage(uiImage)
        img = downscale(img, maxSide: 1024)

        // נסיון Vision (מכשיר אמיתי בלבד)
        #if !targetEnvironment(simulator)
        if #available(iOS 17.0, *) {
            do { if let out = try performVisionMask(on: img) { return out } }
            catch { print("Vision failed → fallback:", error.localizedDescription) }
        }
        #endif

        // Fallback כרומת־קי (עובד גם בסימולטור)
        if let out = chromaKeyCutout(from: img) { return out }

        #if targetEnvironment(simulator)
        throw CutoutError.notSupportedOnSimulator
        #else
        throw CutoutError.outputFailed
        #endif
    }

    // MARK: Vision path
    @available(iOS 17.0, *)
    private static func performVisionMask(on image: UIImage) throws -> UIImage? {
        guard let cg = image.cgImage else { throw CutoutError.cgImageMissing }

        let handler = VNImageRequestHandler(
            cgImage: cg,
            orientation: CGImagePropertyOrientation(image.imageOrientation),
            options: [:]
        )
        let request = VNGenerateForegroundInstanceMaskRequest()

        // רוויזיה נתמכת מקסימלית
        if let best = Array(VNGenerateForegroundInstanceMaskRequest.supportedRevisions).sorted().last {
            request.revision = best
        }
        // אין שימוש ב-qualityLevel כאן.
        // אפשר להשאיר usesCPUOnly אם תרצה fallback איטי יותר:
        // request.usesCPUOnly = true  // (אזהרת דפריקציה מותרת; אפשר גם להשמיט)

        do { try handler.perform([request]) } catch { throw CutoutError.requestFailed }
        guard let obs = request.results?.first else { throw CutoutError.noMask }

        let maskPB = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)

        // CI pipeline
        let ctx = CIContext()
        let input = CIImage(cgImage: cg)
        var mask = CIImage(cvPixelBuffer: maskPB)

        // נרמול 0..255 → 0..1 + feather עדין
        let cm = CIFilter.colorMatrix()
        cm.inputImage = mask
        cm.rVector = CIVector(x: 1/255, y: 0, z: 0, w: 0)
        cm.gVector = CIVector(x: 0, y: 1/255, z: 0, w: 0)
        cm.bVector = CIVector(x: 0, y: 0, z: 1/255, w: 0)
        cm.aVector = CIVector(x: 0, y: 0, z: 0, w: 1/255)
        mask = cm.outputImage ?? mask

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = mask
        blur.radius = 1.5
        mask = (blur.outputImage ?? mask).clampedToExtent().cropped(to: input.extent)

        let transparent = CIImage(color: .clear).cropped(to: input.extent)
        guard let blend = CIFilter(name: "CIBlendWithMask") else { throw CutoutError.outputFailed }
        blend.setValue(input, forKey: kCIInputImageKey)
        blend.setValue(transparent, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)

        guard let out = blend.outputImage,
              let outCG = ctx.createCGImage(out, from: out.extent) else {
            throw CutoutError.outputFailed
        }
        return UIImage(cgImage: outCG, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: Chroma-key fallback (CPU)
    private static func chromaKeyCutout(
        from image: UIImage,
        border: Int = 12,
        thresholdSoft: CGFloat = 0.07,
        thresholdHard: CGFloat = 0.15
    ) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width, height = cg.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buf = ctx.data else { return nil }
        let p = buf.bindMemory(to: UInt8.self, capacity: width * height * bytesPerPixel)

        let b = max(1, min(border, min(width, height) / 4))
        var rSum = 0.0, gSum = 0.0, bSum = 0.0, count = 0.0
        @inline(__always) func sample(_ x: Int, _ y: Int) {
            let i = (y*width + x) * bytesPerPixel
            rSum += Double(p[i]); gSum += Double(p[i+1]); bSum += Double(p[i+2]); count += 1
        }
        for x in 0..<width {
            for y in 0..<b { sample(x, y) }
            for y in max(height-b, 0)..<height { sample(x, y) }
        }
        if width > 2*b {
            for y in b..<max(height-b, b) {
                for x in 0..<b { sample(x, y) }
                for x in max(width-b, 0)..<width { sample(x, y) }
            }
        }
        let bgR = rSum / max(count, 1), bgG = gSum / max(count, 1), bgB = bSum / max(count, 1)

        let t0 = max(0.0, Double(thresholdSoft)) * 255.0
        let t1 = max(t0 + 1.0, Double(thresholdHard) * 255.0)

        for y in 0..<height {
            for x in 0..<width {
                let i = (y*width + x) * bytesPerPixel
                let r = Double(p[i]), g = Double(p[i+1]), b = Double(p[i+2])
                let dr = r - bgR, dg = g - bgG, db = b - bgB
                let dist = sqrt(dr*dr + dg*dg + db*db)
                let a = max(0.0, min(1.0, (dist - t0) / (t1 - t0)))
                p[i+3] = UInt8(a * 255.0)
            }
        }

        guard let outCG = ctx.makeImage() else { return nil }
        return UIImage(cgImage: outCG, scale: image.scale, orientation: image.imageOrientation)
    }
}

// Vision צריך CGImagePropertyOrientation
private extension CGImagePropertyOrientation {
    init(_ ui: UIImage.Orientation) {
        switch ui {
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
