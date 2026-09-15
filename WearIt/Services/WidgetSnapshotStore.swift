import Foundation
import UIKit
import os
#if canImport(WidgetKit)
import WidgetKit
#endif

struct TodaySnapshotItem: Codable {
    let slot: String
    let garmentID: String
    let title: String
    let thumbFilename: String
}

struct TodaySnapshot: Codable {
    let date: String
    let locationName: String?
    let lowTempC: Double?
    let highTempC: Double?
    let confirmedWorn: Bool
    let items: [TodaySnapshotItem]
}

/// Sendable garment image inputs for off-main widget thumbnail work.
private struct WidgetThumbSource: Sendable {
    let slotRaw: String
    let garmentID: UUID
    let title: String
    let imagePath: String?
    let imageData: Data?
}

private struct WidgetSnapshotDraft: Sendable {
    let date: String
    let locationName: String?
    let lowTempC: Double?
    let highTempC: Double?
    let confirmedWorn: Bool
    let sources: [WidgetThumbSource]
}

enum WidgetSnapshotService {
    static let appGroupID = "group.com.dordavid.WearIt"
    static let snapshotKey = "todaySnapshotV1"
    static let commandKey = "widgetCommand"
    fileprivate static let imageFolder = "Thumbs"
    fileprivate static let thumbPixelSize = CGSize(width: 300, height: 375)

    /// Captures plan state on the calling actor, then generates thumbnails and
    /// writes the App Group snapshot via a serial coordinator.
    static func saveTodaySnapshot(
        plan: DayPlan,
        garments: [Garment],
        forecast: DayForecast?,
        locationName: String?
    ) {
        let draft = WidgetSnapshotDraft(
            date: dateString(from: plan.date),
            locationName: locationName,
            lowTempC: forecast?.lowTempC,
            highTempC: forecast?.highTempC,
            confirmedWorn: plan.wasWornConfirmed,
            sources: buildThumbSources(plan: plan, garments: garments)
        )

        Task(priority: .utility) {
            await WidgetSnapshotCoordinator.shared.save(draft)
        }
    }

    static func loadSnapshot() -> TodaySnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(TodaySnapshot.self, from: data)
    }

    static func imageURL(for filename: String) -> URL? {
        guard let base = appGroupURL() else { return nil }
        return base.appendingPathComponent(imageFolder, isDirectory: true).appendingPathComponent(filename)
    }

    // MARK: - Internal

    private static func buildThumbSources(plan: DayPlan, garments: [Garment]) -> [WidgetThumbSource] {
        let assignments = plan.slotAssignments
        var sources: [WidgetThumbSource] = []

        for (slot, id) in assignments {
            guard let garment = garments.first(where: { $0.id == id }) else { continue }
            sources.append(
                WidgetThumbSource(
                    slotRaw: slot.rawValue,
                    garmentID: garment.id,
                    title: garment.displayTitle,
                    imagePath: garment.imagePath,
                    imageData: garment.imageData
                )
            )
        }

        return sources
    }

    fileprivate static func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    fileprivate static func appGroupURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    fileprivate static func writeSnapshot(_ snapshot: TodaySnapshot) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: snapshotKey)
        }
    }
}

/// Serializes snapshot writes and coalesces timeline reloads.
private actor WidgetSnapshotCoordinator {
    static let shared = WidgetSnapshotCoordinator()

    private var pendingReloadTask: Task<Void, Never>?
    private let coalesceNanoseconds: UInt64 = 250_000_000 // 250ms
    private let signposter = OSSignposter(
        subsystem: WearItPerformance.subsystem,
        category: WearItPerformance.SignpostCategory.widget
    )

    func save(_ draft: WidgetSnapshotDraft) {
        let state = signposter.beginInterval("save-snapshot")
        defer { signposter.endInterval("save-snapshot", state) }

        let items: [TodaySnapshotItem] = draft.sources.map { source in
            let filename = ensureThumbnail(for: source) ?? ""
            return TodaySnapshotItem(
                slot: source.slotRaw,
                garmentID: source.garmentID.uuidString,
                title: source.title,
                thumbFilename: filename
            )
        }

        let snapshot = TodaySnapshot(
            date: draft.date,
            locationName: draft.locationName,
            lowTempC: draft.lowTempC,
            highTempC: draft.highTempC,
            confirmedWorn: draft.confirmedWorn,
            items: items
        )
        WidgetSnapshotService.writeSnapshot(snapshot)
        scheduleReload()
    }

    /// Downsamples from the garment file URL (or legacy data) into the App Group
    /// thumb contract: `Thumbs/thumb-{slot}-{uuid}.jpg` at 300×375.
    private func ensureThumbnail(for source: WidgetThumbSource) -> String? {
        let thumbState = signposter.beginInterval("widget-thumb")
        defer { signposter.endInterval("widget-thumb", thumbState) }

        guard let base = WidgetSnapshotService.appGroupURL() else { return nil }
        let folderURL = base.appendingPathComponent(WidgetSnapshotService.imageFolder, isDirectory: true)
        if !FileManager.default.fileExists(atPath: folderURL.path) {
            do {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }

        let filename = "thumb-\(source.slotRaw)-\(source.garmentID.uuidString).jpg"
        let url = folderURL.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: url.path) {
            return filename
        }

        let size = WidgetSnapshotService.thumbPixelSize
        let maxPixel = max(size.width, size.height)
        let downsampled: UIImage?
        if let imagePath = source.imagePath,
           let fileURL = ImageStore.absoluteURL(path: imagePath) {
            downsampled = ImageStore.downsample(url: fileURL, maxPixelSize: maxPixel)
        } else if let data = source.imageData {
            downsampled = ImageStore.downsample(data: data, maxPixelSize: maxPixel)
        } else {
            downsampled = nil
        }

        guard let image = downsampled else { return nil }

        let renderer = UIGraphicsImageRenderer(size: size)
        let thumbnail = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }

        guard let data = thumbnail.jpegData(compressionQuality: 0.85) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    private func scheduleReload() {
        pendingReloadTask?.cancel()
        pendingReloadTask = Task {
            try? await Task.sleep(nanoseconds: coalesceNanoseconds)
            guard !Task.isCancelled else { return }
            let state = signposter.beginInterval("timeline-reload")
            defer { signposter.endInterval("timeline-reload", state) }
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: "WearItWidget")
            #endif
        }
    }
}
