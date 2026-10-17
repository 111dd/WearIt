import Foundation
import UIKit
import os

/// Serial media work away from the main actor. Only image inputs and file paths
/// cross this boundary; SwiftData models and UI state stay with the caller.
actor GarmentImagePersistence {
    static let shared = GarmentImagePersistence()

    struct Files: Sendable {
        let image: String
        let original: String
        let thumbnail: String

        var paths: [String] { [image, original, thumbnail] }
    }

    private let signposter = OSSignposter(
        subsystem: WearItPerformance.subsystem,
        category: WearItPerformance.SignpostCategory.images
    )

    /// All three files must exist before the caller can attach them to a garment.
    func persist(display: UIImage, original: UIImage) throws -> Files {
        let interval = signposter.beginInterval("persist-garment-images", id: signposter.makeSignpostID())
        defer { signposter.endInterval("persist-garment-images", interval) }
        var created: [String] = []
        do {
            return try autoreleasepool {
                try Task.checkCancellation()
                guard let originalData = original.jpegData(compressionQuality: 0.9) else {
                    throw PersistenceError.encoding
                }
                try Task.checkCancellation()
                let originalPath = try ImageStore.save(data: originalData, preferredExt: "jpg")
                created.append(originalPath)

                // Keep cutout transparency, matching the existing PNG-first policy.
                let displayData: Data
                let ext: String
                if let png = display.pngData() {
                    displayData = png
                    ext = "png"
                } else if let jpeg = display.jpegData(compressionQuality: 0.9) {
                    displayData = jpeg
                    ext = "jpg"
                } else {
                    throw PersistenceError.encoding
                }
                try Task.checkCancellation()
                let imagePath = try ImageStore.save(data: displayData, preferredExt: ext)
                created.append(imagePath)
                guard let thumbnailPath = ImageStore.generateAndSaveThumbnail(for: imagePath) else {
                    throw PersistenceError.encoding
                }
                created.append(thumbnailPath)
                try Task.checkCancellation()
                return Files(image: imagePath, original: originalPath, thumbnail: thumbnailPath)
            }
        } catch {
            remove(paths: created)
            throw error
        }
    }

    /// Fail atomically so a retry cannot silently lose an additional photo.
    func persistExtras(_ images: [UIImage]) throws -> [String] {
        var paths: [String] = []
        do {
            for image in images {
                try autoreleasepool {
                    try Task.checkCancellation()
                    guard let data = image.jpegData(compressionQuality: 0.88) else {
                        throw PersistenceError.encoding
                    }
                    try Task.checkCancellation()
                    paths.append(try ImageStore.save(data: data, preferredExt: "jpg"))
                }
            }
            try Task.checkCancellation()
            return paths
        } catch {
            remove(paths: paths)
            throw error
        }
    }

    /// Preserve an older inline photo before it participates in the path-based gallery.
    func persistLegacy(_ data: Data) throws -> Files {
        try Task.checkCancellation()
        guard let image = UIImage(data: data) else { throw PersistenceError.encoding }
        return try persist(display: image, original: image)
    }

    /// Prepares a newly selected cover without decoding or writing on the UI actor.
    func prepareThumbnail(for path: String) throws -> String {
        try Task.checkCancellation()
        guard let thumbnail = ImageStore.generateAndSaveThumbnail(for: path) else {
            throw PersistenceError.encoding
        }
        do {
            try Task.checkCancellation()
            return thumbnail
        } catch {
            remove(paths: [thumbnail])
            throw error
        }
    }

    /// Call only with uncommitted, request-owned paths, never persisted model paths.
    func remove(paths: [String]) {
        for path in paths { ImageStore.delete(path: path) }
    }

    private enum PersistenceError: Error {
        case encoding
    }
}
