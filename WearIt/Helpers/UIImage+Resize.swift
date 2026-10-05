import UIKit

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
