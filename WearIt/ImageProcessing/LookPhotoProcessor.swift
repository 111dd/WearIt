//
//  LookPhotoProcessor.swift
//  WearIt
//
//  Turns a raw look photo (mirror selfie, tripod shot, a photo from the library)
//  into a grid-ready post photo, all on device:
//  - a 4:5 crop framed around the person, so the profile grid looks even;
//  - optional "hide face" (soft heavy blur over every detected face);
//  - optional background blur (person segmentation), to keep the home private;
//  - a fresh pixel-only JPEG: no EXIF, no GPS, nothing but the picture.
//
//  `analyze` runs Vision once; `render` is cheap enough to re-run while the user
//  flips the options. Both are synchronous: call them from a background task.
//  On the Simulator Vision may find nothing; the photo is then center-cropped.
//

import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

enum LookPhotoProcessor {
    static let outputSize = CGSize(width: 1080, height: 1350)
    private static let aspect: CGFloat = 4.0 / 5.0
    /// Working size for Vision and Core Image; larger photos are scaled down first.
    private static let workingMaxSide: CGFloat = 2400
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    struct Options: Equatable {
        var hideFace = false
        var blurBackground = false
    }

    /// What Vision found, in the upright working image's coordinates (bottom-left origin).
    struct Analysis: @unchecked Sendable {
        let image: CIImage
        let cropRect: CGRect
        let faceRects: [CGRect]
        let personMask: CIImage?

        var hasFace: Bool { !faceRects.isEmpty }
        var hasPerson: Bool { personMask != nil }
    }

    /// Analyze + render with the given options in one go (used for quick adds).
    static func process(_ image: UIImage, options: Options = Options()) -> UIImage? {
        guard let analysis = analyze(image) else { return nil }
        return render(analysis, options: options)
    }

    static func analyze(_ uiImage: UIImage) -> Analysis? {
        guard let cgImage = uprightCGImage(uiImage) else { return nil }
        let image = CIImage(cgImage: cgImage)
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let faces = VNDetectFaceRectanglesRequest()
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        try? handler.perform([humans, faces, segmentation])

        let toImage: (CGRect) -> CGRect = { VNImageRectForNormalizedRect($0, Int(width), Int(height)) }
        let faceRects = (faces.results ?? []).map { toImage($0.boundingBox) }
        let bodyRect = (humans.results ?? [])
            .max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
            .map { toImage($0.boundingBox) }

        var mask: CIImage?
        if let buffer = segmentation.results?.first?.pixelBuffer {
            let raw = CIImage(cvPixelBuffer: buffer)
            let sx = width / raw.extent.width
            let sy = height / raw.extent.height
            let scaled = raw.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            // An empty mask (no person) would blur the whole photo; treat it as no person.
            if bodyRect != nil || !faceRects.isEmpty { mask = scaled }
        }

        let subject = bodyRect ?? faceRects.reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
        let crop = cropRect(around: subject, in: CGSize(width: width, height: height))
        return Analysis(image: image, cropRect: crop, faceRects: faceRects, personMask: mask)
    }

    static func render(_ analysis: Analysis, options: Options) -> UIImage? {
        let extent = analysis.image.extent
        var output = analysis.image

        if options.blurBackground, let mask = analysis.personMask {
            let blurred = output.clampedToExtent().applyingGaussianBlur(sigma: 30).cropped(to: extent)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = output
            blend.backgroundImage = blurred
            blend.maskImage = mask
            output = blend.outputImage ?? output
        }

        if options.hideFace, let largest = analysis.faceRects.map({ max($0.width, $0.height) }).max() {
            // Strong enough that the face can't be read, soft-edged so it doesn't look like a sticker.
            let sigma = max(16, Double(largest) * 0.16)
            let blurred = output.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
            var faceMask: CIImage?
            for face in analysis.faceRects {
                let area = face.insetBy(dx: -face.width * 0.3, dy: -face.height * 0.4)
                let radius = max(area.width, area.height) / 2
                let spot = CIFilter.radialGradient()
                spot.center = CGPoint(x: area.midX, y: area.midY)
                spot.radius0 = Float(radius * 0.8)
                spot.radius1 = Float(radius * 1.1)
                spot.color0 = CIColor.white
                spot.color1 = CIColor.black
                guard let spotImage = spot.outputImage?.cropped(to: extent) else { continue }
                if let existing = faceMask {
                    let combine = CIFilter.maximumCompositing()
                    combine.inputImage = spotImage
                    combine.backgroundImage = existing
                    faceMask = combine.outputImage
                } else {
                    faceMask = spotImage
                }
            }
            if let faceMask {
                let blend = CIFilter.blendWithMask()
                blend.inputImage = blurred
                blend.backgroundImage = output
                blend.maskImage = faceMask
                output = blend.outputImage ?? output
            }
        }

        let crop = analysis.cropRect
        let scale = outputSize.width / crop.width
        let framed = output
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = ciContext.createCGImage(framed, from: CGRect(origin: .zero, size: outputSize)) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// The post's JPEG. Built from pixels only, so no camera metadata or location survives.
    static func jpegData(_ image: UIImage) -> Data? {
        image.jpegData(compressionQuality: 0.85)
    }

    // MARK: - Helpers

    /// The largest useful 4:5 frame around the subject (with room for shoes and hair), kept inside the photo.
    private static func cropRect(around subject: CGRect?, in size: CGSize) -> CGRect {
        let maxFrame: CGSize = size.width / size.height > aspect
            ? CGSize(width: size.height * aspect, height: size.height)
            : CGSize(width: size.width, height: size.width / aspect)

        var frameSize = maxFrame
        var center = CGPoint(x: size.width / 2, y: size.height / 2)
        if let subject {
            let padded = subject.insetBy(dx: -subject.width * 0.12, dy: -subject.height * 0.08)
            let height = max(padded.height, padded.width / aspect)
            frameSize = CGSize(width: min(height * aspect, maxFrame.width), height: min(height, maxFrame.height))
            center = CGPoint(x: subject.midX, y: subject.midY)
        }
        let x = min(max(center.x - frameSize.width / 2, 0), size.width - frameSize.width)
        let y = min(max(center.y - frameSize.height / 2, 0), size.height - frameSize.height)
        return CGRect(x: x, y: y, width: frameSize.width, height: frameSize.height)
    }

    private static func uprightCGImage(_ image: UIImage) -> CGImage? {
        let side = max(image.size.width, image.size.height)
        guard side > 0 else { return nil }
        let scale = min(1, workingMaxSide / side)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }
}
