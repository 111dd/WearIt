//
//  VisionAutoCropper.swift
//  WearIt
//
//  Best-effort auto-crop using Vision instance/rectangle detection.
//

import Foundation
import Vision
import UIKit

enum VisionAutoCropper {
    /// Attempts to find a bounding box of the foreground (person/object) and returns a cropped image.
    /// If nothing is detected, returns nil. Runs only on device (not simulator).
    static func autoCrop(_ image: UIImage) async -> UIImage? {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard let cg = image.cgImage else { return nil }
        let size = CGSize(width: cg.width, height: cg.height)

        if let box = await personMaskBoundingBox(for: cg, size: size) {
            return crop(cgImage: cg, to: box, orientation: image.imageOrientation, scale: image.scale)
        }
        if let box = await humanBoundingBox(for: cg, size: size) {
            return crop(cgImage: cg, to: box, orientation: image.imageOrientation, scale: image.scale)
        }
        return nil
        #endif
    }

    // MARK: - Person mask → bounding box
    private static func personMaskBoundingBox(for cg: CGImage, size: CGSize) async -> CGRect? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
            guard let obs = request.results?.first as? VNPixelBufferObservation else { return nil }
            let pb = obs.pixelBuffer
            guard var rect = boundingBox(in: pb, imageSize: size) else { return nil }

            // הרחבה קטנה כדי לא לחתוך שוליים
            rect = expand(rect, in: size, factor: 1.1)

            // סינון: לא קטן מדי ולא דק מדי
            let minArea = size.width * size.height * 0.02 // לפחות 2% מהתמונה
            if rect.width * rect.height < minArea { return nil }
            if rect.width < 32 || rect.height < 32 { return nil }
            return rect
        } catch {
            return nil
        }
    }

    // MARK: - Human rectangles fallback
    private static func humanBoundingBox(for cg: CGImage, size: CGSize) async -> CGRect? {
        let request = VNDetectHumanRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
            let boxes = request.results?.map { $0.boundingBox } ?? []
            guard var rect = union(boxes, imageSize: size) else { return nil }
            rect = expand(rect, in: size, factor: 1.1)
            let minArea = size.width * size.height * 0.02
            if rect.width * rect.height < minArea { return nil }
            return rect
        } catch {
            return nil
        }
    }

    // MARK: - Helpers
    private static func boundingBox(in pixelBuffer: CVPixelBuffer, imageSize: CGSize) -> CGRect? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var minX = width
        var maxX = 0
        var minY = height
        var maxY = 0
        var count: Int = 0

        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                if row[x] > 0 { // mask pixel present
                    count += 1
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }

        guard count > 0 else { return nil }

        // Convert mask coords to image coords
        let scaleX = imageSize.width / CGFloat(width)
        let scaleY = imageSize.height / CGFloat(height)
        let rect = CGRect(x: CGFloat(minX) * scaleX,
                          y: CGFloat(minY) * scaleY,
                          width: CGFloat(maxX - minX + 1) * scaleX,
                          height: CGFloat(maxY - minY + 1) * scaleY).integral
        return rect
    }

    private static func union(_ boxes: [CGRect], imageSize: CGSize) -> CGRect? {
        guard !boxes.isEmpty else { return nil }
        var rect = boxes[0]
        for b in boxes.dropFirst() { rect = rect.union(b) }
        // Convert normalized to pixel space
        let w = imageSize.width
        let h = imageSize.height
        let x = rect.minX * w
        let y = (1 - rect.maxY) * h
        let width = rect.width * w
        let height = rect.height * h
        return CGRect(x: x, y: y, width: width, height: height).integral
    }

    private static func expand(_ rect: CGRect, in size: CGSize, factor: CGFloat) -> CGRect {
        let cx = rect.midX, cy = rect.midY
        let nw = min(rect.width * factor, size.width)
        let nh = min(rect.height * factor, size.height)
        let nx = max(0, min(size.width - nw, cx - nw/2))
        let ny = max(0, min(size.height - nh, cy - nh/2))
        return CGRect(x: nx, y: ny, width: nw, height: nh).integral
    }

    private static func crop(cgImage: CGImage, to rect: CGRect, orientation: UIImage.Orientation, scale: CGFloat) -> UIImage? {
        guard let cropped = cgImage.cropping(to: rect.intersection(CGRect(origin: .zero, size: CGSize(width: cgImage.width, height: cgImage.height)))) else {
            return nil
        }
        return UIImage(cgImage: cropped, scale: scale, orientation: orientation)
    }
}

