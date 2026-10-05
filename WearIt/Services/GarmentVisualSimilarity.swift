import Foundation
import Vision

/// On-device visual "fingerprints" of garment photos (Vision feature prints),
/// so the recommender can tell that two pieces look alike even when their
/// tags differ. Prints are cached as small files in Application Support and
/// never synced through CloudKit. Work runs off the main thread, in small
/// batches, from deferred bootstrap.
final class GarmentVisualSimilarity: @unchecked Sendable {
    static let shared = GarmentVisualSimilarity()

    struct Item: Sendable {
        let garmentID: UUID
        let imagePath: String
    }

    private let lock = NSLock()
    private var prints: [UUID: VNFeaturePrintObservation] = [:]
    /// Max new prints per launch, to stay light on battery.
    private let batchLimit = 40

    private init() {}

    // MARK: - Lookup (cheap, synchronous)

    /// 0...1 visual similarity between two garments, nil until both prints exist.
    func similarity(_ a: UUID, _ b: UUID) -> Double? {
        lock.lock()
        let first = prints[a]
        let second = prints[b]
        lock.unlock()
        guard let first, let second else { return nil }
        var distance: Float = 0
        guard (try? first.computeDistance(&distance, to: second)) != nil else { return nil }
        // Feature-print distances are roughly 0 (identical) ... 1.5+ (unrelated).
        return max(0, min(1, 1 - Double(distance) / 1.2))
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return prints.isEmpty
    }

    // MARK: - Warm-up

    /// Loads cached prints and computes a batch of missing ones in the background.
    func warmUp(_ items: [Item]) async {
        await Task.detached(priority: .background) { [self] in
            var computed = 0
            for item in items {
                if Task.isCancelled { return }
                if self.hasPrint(item.garmentID) { continue }
                let cacheURL = self.cacheURL(for: item)
                if let cacheURL, let cached = Self.loadPrint(from: cacheURL) {
                    self.store(cached, for: item.garmentID)
                    continue
                }
                guard computed < self.batchLimit,
                      let imageURL = ImageStore.fileURL(path: item.imagePath),
                      let print = Self.makePrint(imageURL: imageURL) else { continue }
                self.store(print, for: item.garmentID)
                if let cacheURL { Self.savePrint(print, to: cacheURL) }
                computed += 1
                await Task.yield()
            }
        }.value
    }

    private func hasPrint(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return prints[id] != nil
    }

    private func store(_ print: VNFeaturePrintObservation, for id: UUID) {
        lock.lock()
        prints[id] = print
        lock.unlock()
    }

    // MARK: - Vision

    private static func makePrint(imageURL: URL) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(url: imageURL, options: [:])
        do {
            try handler.perform([request])
            return request.results?.first as? VNFeaturePrintObservation
        } catch {
            return nil
        }
    }

    // MARK: - Disk cache

    /// One file per garment + image, so a new photo gets a new print.
    private func cacheURL(for item: Item) -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("WearItFeaturePrints", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let imageKey = item.imagePath.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(item.garmentID.uuidString)-\(imageKey).fp")
    }

    private static func loadPrint(from url: URL) -> VNFeaturePrintObservation? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    private static func savePrint(_ print: VNFeaturePrintObservation, to url: URL) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: print, requiringSecureCoding: true) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
