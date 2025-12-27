// DeepLabSegmenter.swift
import UIKit
import Vision
import CoreML
import CoreImage
import CoreImage.CIFilterBuiltins

// יוצר CGImage מגווני אפור (למסכה) – אין extension על CGImage!
private func makeGrayCGImage(bytes: [UInt8], width: Int, height: Int) -> CGImage? {
    let bitsPerComponent = 8
    let bytesPerRow = width
    var data = bytes
    guard let provider = CGDataProvider(data: NSData(bytes: &data, length: data.count)) else { return nil }
    return CGImage(
        width: width, height: height,
        bitsPerComponent: bitsPerComponent, bitsPerPixel: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: 0),
        provider: provider, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent
    )
}

// עוזרים קלים
private func normalize(_ img: UIImage) -> UIImage {
    let fmt = UIGraphicsImageRendererFormat()
    fmt.scale = img.scale; fmt.opaque = false
    return UIGraphicsImageRenderer(size: img.size, format: fmt).image { _ in
        img.draw(in: CGRect(origin: .zero, size: img.size))
    }
}
private func downscale(_ img: UIImage, maxSide: CGFloat) -> UIImage {
    let w = img.size.width, h = img.size.height, s = max(w, h)
    guard s > maxSide, s > 0 else { return img }
    let r = maxSide / s, newSize = CGSize(width: w*r, height: h*r)
    let fmt = UIGraphicsImageRendererFormat()
    fmt.scale = img.scale; fmt.opaque = false
    return UIGraphicsImageRenderer(size: newSize, format: fmt).image { _ in
        img.draw(in: CGRect(origin: .zero, size: newSize))
    }
}

final class DeepLabSegmenter {
    static let shared = DeepLabSegmenter()

    private let vnModel: VNCoreMLModel
    private let ciContext = CIContext()

    private init() {
        // ודא שהוספת DeepLabV3.mlmodel לפרויקט (Xcode יוצר את המחלקה DeepLabV3 אוטומטית)
        let coreML = try! DeepLabV3(configuration: MLModelConfiguration()).model
        vnModel = try! VNCoreMLModel(for: coreML)
        // אם הקומפילר מתלונן על inputImageFeatureName – פשוט תמחק את השורה הזו.
        // vnModel.inputImageFeatureName = "image"
    }

    /// מחזיר UIImage עם רקע שקוף (PNG) על בסיס DeepLabV3
    func cutout(_ uiImage: UIImage) throws -> UIImage {
        // תקן פורמט + הקטן (ביצועים)
        let safe = downscale(normalize(uiImage), maxSide: 1024)
        guard let cg = safe.cgImage else { throw NSError(domain: "seg", code: -1) }

        let req = VNCoreMLRequest(model: vnModel)
        req.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(
            cgImage: cg,
            orientation: CGImagePropertyOrientation(safe.imageOrientation),
            options: [:]
        )
        try handler.perform([req])

        // נסה פלט כ־PixelBuffer קודם
        if let pix = req.results?.compactMap({ $0 as? VNPixelBufferObservation }).first {
            return try compose(input: safe, maskPixelBuffer: pix.pixelBuffer)
        }

        // או כפיצ’ר מלא (MLMultiArray) – נייצר ממנו מסכה ע"י argmax
        if let obs = req.results?.compactMap({ $0 as? VNCoreMLFeatureValueObservation }).first,
           let arr = obs.featureValue.multiArrayValue {
            let (maskW, maskH, bytes) = try argmaxToBytes(arr)
            guard let maskCG = makeGrayCGImage(bytes: bytes, width: maskW, height: maskH) else {
                throw NSError(domain: "seg", code: -3)
            }
            return try compose(input: safe, maskCGSmall: maskCG)
        }

        throw NSError(domain: "seg", code: -2, userInfo: [NSLocalizedDescriptionKey: "No segmentation output"])
    }

    // המרה מ-MLMultiArray למסכת אפור (0 רקע, 255 קדמה)
    private func argmaxToBytes(_ array: MLMultiArray) throws -> (Int, Int, [UInt8]) {
        let shape = array.shape.map { $0.intValue } // 3D: [C,H,W] או [H,W,C]
        guard shape.count == 3 else { throw NSError(domain: "seg", code: -10) }

        let cFirst = (shape[0] > 10) // בד"כ #classes>10 כאשר C ראשון
        let C = cFirst ? shape[0] : shape[2]
        let H = cFirst ? shape[1] : shape[0]
        let W = cFirst ? shape[2] : shape[1]

        let ptr = UnsafeMutablePointer<Float32>(OpaquePointer(array.dataPointer))
        let strideC = cFirst ? (H*W) : 1
        let strideX = cFirst ? 1 : C
        let strideY = cFirst ? W : (C*W)

        var out = [UInt8](repeating: 0, count: W*H)
        for y in 0..<H {
            for x in 0..<W {
                var maxVal: Float32 = -Float.greatestFiniteMagnitude
                var maxIdx = 0
                let base = cFirst ? (y*W + x) : (y*strideY + x*strideX)
                for cls in 0..<C {
                    let idx = cFirst ? (cls*strideC + base) : (base + cls)
                    let v = ptr[idx]
                    if v > maxVal { maxVal = v; maxIdx = cls }
                }
                out[y*W + x] = (maxIdx == 0) ? 0 : 255 // 0=רקע, כל היתר=קדמה
            }
        }
        return (W, H, out)
    }

    // קומפוזיט כאשר המסכה הגיעה כ-pixelBuffer
    private func compose(input: UIImage, maskPixelBuffer: CVPixelBuffer) throws -> UIImage {
        let inputCI = CIImage(cgImage: input.cgImage!)
        let maskCI  = CIImage(cvPixelBuffer: maskPixelBuffer)

        let sx = inputCI.extent.width / maskCI.extent.width
        let sy = inputCI.extent.height / maskCI.extent.height
        let resized = maskCI.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                            .cropped(to: inputCI.extent)

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = resized; blur.radius = 1.5
        let softMask = (blur.outputImage ?? resized).clampedToExtent().cropped(to: inputCI.extent)

        let transparent = CIImage(color: .clear).cropped(to: inputCI.extent)
        let blend = CIFilter(name: "CIBlendWithMask")!
        blend.setValue(inputCI, forKey: kCIInputImageKey)
        blend.setValue(transparent, forKey: kCIInputBackgroundImageKey)
        blend.setValue(softMask, forKey: kCIInputMaskImageKey)

        let ctx = CIContext()
        guard let out = blend.outputImage,
              let cgOut = ctx.createCGImage(out, from: out.extent) else {
            throw NSError(domain: "seg", code: -6)
        }
        return UIImage(cgImage: cgOut, scale: input.scale, orientation: input.imageOrientation)
    }

    // קומפוזיט כאשר המסכה הגיעה כ-CGImage קטן (מה-MLMultiArray)
    private func compose(input: UIImage, maskCGSmall: CGImage) throws -> UIImage {
        let inputCI = CIImage(cgImage: input.cgImage!)
        let maskSmallCI = CIImage(cgImage: maskCGSmall)

        let sx = inputCI.extent.width / maskSmallCI.extent.width
        let sy = inputCI.extent.height / maskSmallCI.extent.height
        let resized = maskSmallCI.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                                  .cropped(to: inputCI.extent)

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = resized; blur.radius = 1.5
        let softMask = (blur.outputImage ?? resized).clampedToExtent().cropped(to: inputCI.extent)

        let transparent = CIImage(color: .clear).cropped(to: inputCI.extent)
        let blend = CIFilter(name: "CIBlendWithMask")!
        blend.setValue(inputCI, forKey: kCIInputImageKey)
        blend.setValue(transparent, forKey: kCIInputBackgroundImageKey)
        blend.setValue(softMask, forKey: kCIInputMaskImageKey)

        let ctx = CIContext()
        guard let out = blend.outputImage,
              let cgOut = ctx.createCGImage(out, from: out.extent) else {
            throw NSError(domain: "seg", code: -7)
        }
        return UIImage(cgImage: cgOut, scale: input.scale, orientation: input.imageOrientation)
    }
}

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

