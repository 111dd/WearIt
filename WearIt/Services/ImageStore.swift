//
//  ImageStore.swift
//  WearIt
//
//  Created by Dor David on 21/10/2025.
//

import Foundation
import UIKit
import ImageIO
import os

/// אחסון תמונות בקבצים תחת Documents/WearItImages.
/// שומר/טוען לפי מזהה ייחודי (UUID-String).
///
/// All load APIs are synchronous by design. Call disk I/O and decoding from
/// `Task.detached` (or another background executor) and assign results to
/// SwiftUI `@State` on the main actor.
enum ImageStore {
    private static let folderName = "WearItImages"
    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        // Byte-based eviction: without a totalCostLimit, NSCache evicts by
        // count only and can hold hundreds of decoded bitmaps in memory.
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    /// Tracks cache keys created per relative path so `delete(path:)` can evict
    /// every variant (full image + downsampled thumbs). Loads run off-main, so
    /// access is lock-guarded.
    private static let cacheKeyRegistryLock = NSLock()
    private static var cacheKeysByPath: [String: Set<String>] = [:]

    private static func registerCacheKey(_ key: String, for path: String) {
        cacheKeyRegistryLock.lock()
        cacheKeysByPath[path, default: []].insert(key)
        cacheKeyRegistryLock.unlock()
    }

    private static func evictCacheKeys(for path: String) {
        cacheKeyRegistryLock.lock()
        let keys = cacheKeysByPath.removeValue(forKey: path) ?? []
        cacheKeyRegistryLock.unlock()
        for key in keys {
            imageCache.removeObject(forKey: NSString(string: key))
        }
    }
    private static let signposter = OSSignposter(
        subsystem: WearItPerformance.subsystem,
        category: WearItPerformance.SignpostCategory.images
    )

    static let thumbnailMaxPixelSize: CGFloat = 420

    /// URL לתיקיית האחסון (נוצרה אם לא קיימת)
    private static func baseURL() throws -> URL {
        // שומרים ב-Application Support (גיבוי טוב יותר מ-Documents לפריטי מטא)
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: true)
        let dir = appSupport.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// URL מלא לקובץ שמור לפי path יחסי (לשיתוף עם ShareLink וכד').
    static func fileURL(path: String) -> URL? {
        guard let url = try? baseURL().appendingPathComponent(path),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// שומר Data ומחזיר path יחסי (string) לשמירה במסד.
    @discardableResult
    static func save(data: Data, preferredExt: String = "jpg") throws -> String {
        let id = UUID().uuidString
        let filename = id + "." + preferredExt.lowercased()
        let url = try baseURL().appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return filename
    }

    /// שומר UIImage (עם דחיסה) ומחזיר path יחסי.
    @discardableResult
    static func save(image: UIImage, quality: CGFloat = 0.9) throws -> String {
        if let jpg = image.jpegData(compressionQuality: quality) {
            return try save(data: jpg, preferredExt: "jpg")
        } else if let png = image.pngData() {
            return try save(data: png, preferredExt: "png")
        } else {
            throw NSError(domain: "ImageStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported image"])
        }
    }

    /// קורא Data לפי path יחסי.
    static func loadData(path: String) -> Data? {
        guard let url = try? baseURL().appendingPathComponent(path) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Absolute file URL for a stored relative path
    static func absoluteURL(path: String) -> URL? {
        try? baseURL().appendingPathComponent(path)
    }

    /// Check if a stored relative path exists on disk
    static func fileExists(path: String) -> Bool {
        guard let url = absoluteURL(path: path) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Write Data to a specific stored relative path
    @discardableResult
    static func write(data: Data, toRelativePath path: String) -> Bool {
        guard let url = absoluteURL(path: path) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// קורא UIImage לפי path יחסי.
    static func loadImage(path: String) -> UIImage? {
        let key = NSString(string: path)
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        guard let data = loadData(path: path) else { return nil }
        let image = UIImage(data: data)
        if let image {
            imageCache.setObject(image, forKey: key, cost: image.wearItApproximateByteCost)
            registerCacheKey(path, for: path)
        }
        return image
    }

    /// Load a stored thumbnail image (small file) with separate cache
    static func loadStoredThumbnail(path: String, cacheKey: String) -> UIImage? {
        let key = NSString(string: "thumb|\(cacheKey)")
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        guard let data = loadData(path: path),
              let image = UIImage(data: data) else { return nil }
        thumbnailCache.setObject(image, forKey: key, cost: image.wearItApproximateByteCost)
        return image
    }

    /// Memory-only lookup — safe to call on the main thread during scroll.
    static func cachedThumbnail(cacheKey: String) -> UIImage? {
        thumbnailCache.object(forKey: NSString(string: "thumb|\(cacheKey)"))
    }

    /// Load a downsampled thumbnail to avoid decoding full-res images.
    /// Prefer calling from a background executor; results are cached.
    static func loadThumbnail(path: String, maxPixelSize: CGFloat) -> UIImage? {
        let key = NSString(string: "\(path)|thumb|\(Int(maxPixelSize))")
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        guard let url = try? baseURL().appendingPathComponent(path) else { return nil }
        guard let image = downsample(url: url, maxPixelSize: maxPixelSize) else { return nil }
        imageCache.setObject(image, forKey: key, cost: image.wearItApproximateByteCost)
        registerCacheKey(key as String, for: path)
        return image
    }

    /// ImageIO downsample from an absolute file URL. Safe off the main actor.
    static func downsample(url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let state = signposter.beginInterval("downsample")
        defer { signposter.endInterval("downsample", state) }
        guard maxPixelSize > 0 else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return makeThumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    /// ImageIO downsample from in-memory data (legacy `imageData`). Safe off the main actor.
    static func downsample(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let state = signposter.beginInterval("downsample-data")
        defer { signposter.endInterval("downsample-data", state) }
        guard maxPixelSize > 0 else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return makeThumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    private static func makeThumbnail(from source: CGImageSource, maxPixelSize: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// Generate and save a thumbnail file for an existing image path
    @discardableResult
    static func generateAndSaveThumbnail(for path: String, maxPixelSize: CGFloat = thumbnailMaxPixelSize) -> String? {
        guard let url = try? baseURL().appendingPathComponent(path) else { return nil }
        guard let image = downsample(url: url, maxPixelSize: maxPixelSize) else { return nil }
        return try? save(image: image, quality: 0.85)
    }

    /// מוחק קובץ תמונה (לא חובה להשתמש בזה ביום-יום).
    static func delete(path: String) {
        evictCacheKeys(for: path)
        guard let url = try? baseURL().appendingPathComponent(path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Evicts a stored-thumbnail cache entry (keyed by garment cache key).
    static func evictStoredThumbnail(cacheKey: String) {
        thumbnailCache.removeObject(forKey: NSString(string: "thumb|\(cacheKey)"))
    }
}
