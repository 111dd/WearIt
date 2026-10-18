import UIKit

/// Display-only framing. Never edits the stored photograph or crops opaque
/// backgrounds heuristically: pale clothes on a pale backdrop must stay intact.
enum GarmentPhotoFraming {
    /// A bounded, upright working copy for native subject analysis. Off-main.
    static func workingImage(_ image: UIImage, maxPixel: CGFloat = 2400) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return image }
        let scale = min(1, maxPixel / (longest * image.scale))
        if scale == 1, image.imageOrientation == .up { return image }
        let size = CGSize(width: image.size.width * image.scale * scale,
                          height: image.size.height * image.scale * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    struct Advice {
        let canIsolateSubject: Bool
        let isLowResolution: Bool
        var suggestsImprovement: Bool { canIsolateSubject || isLowResolution }
    }

    static func advice(for image: UIImage) -> Advice {
        Advice(canIsolateSubject: alphaBounds(image)?.hasTransparency != true,
               isLowResolution: max(image.size.width * image.scale, image.size.height * image.scale) < 600)
    }

    /// Remove transparent padding already present in a cutout, with a small
    /// safety margin. Opaque photos retain their full frame until user selection.
    static func trimmed(_ image: UIImage) -> UIImage {
        guard image.imageOrientation == .up, let cg = image.cgImage,
              let result = alphaBounds(image), result.hasTransparency,
              result.bounds.width > 0.03, result.bounds.height > 0.03 else { return image }
        let box = result.bounds.insetBy(dx: -0.015, dy: -0.015)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixels = CGRect(x: box.minX * CGFloat(cg.width), y: box.minY * CGFloat(cg.height),
                            width: box.width * CGFloat(cg.width), height: box.height * CGFloat(cg.height)).integral
        guard let cropped = cg.cropping(to: pixels) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }

    private static func alphaBounds(_ image: UIImage) -> (bounds: CGRect, hasTransparency: Bool)? {
        guard let cg = image.cgImage else { return nil }
        let side = 96
        let bytesPerRow = side * 4
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * bytesPerRow)
        var minX = side, minY = side, maxX = -1, maxY = -1
        var transparent = 0
        for y in 0..<side {
            for x in 0..<side {
                let alpha = bytes[y * bytesPerRow + x * 4 + 3]
                if alpha < 16 { transparent += 1; continue }
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return (CGRect(x: CGFloat(minX) / CGFloat(side), y: CGFloat(minY) / CGFloat(side),
                       width: CGFloat(maxX - minX + 1) / CGFloat(side), height: CGFloat(maxY - minY + 1) / CGFloat(side)),
                transparent > side * side / 100)
    }
}
