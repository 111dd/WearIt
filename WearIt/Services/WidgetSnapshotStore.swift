import Foundation
import UIKit
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

enum WidgetSnapshotService {
    static let appGroupID = "group.com.dordavid.WearIt"
    static let snapshotKey = "todaySnapshotV1"
    static let commandKey = "widgetCommand"
    private static let imageFolder = "Thumbs"

    static func saveTodaySnapshot(
        plan: DayPlan,
        garments: [Garment],
        forecast: DayForecast?,
        locationName: String?
    ) {
        let items = buildItems(plan: plan, garments: garments)
        let snapshot = TodaySnapshot(
            date: dateString(from: plan.date),
            locationName: locationName,
            lowTempC: forecast?.lowTempC,
            highTempC: forecast?.highTempC,
            confirmedWorn: plan.wasWornConfirmed,
            items: items
        )

        writeSnapshot(snapshot)
        reloadTimelines()
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

    private static func buildItems(plan: DayPlan, garments: [Garment]) -> [TodaySnapshotItem] {
        let assignments = plan.slotAssignments
        var items: [TodaySnapshotItem] = []

        for (slot, id) in assignments {
            guard let garment = garments.first(where: { $0.id == id }) else { continue }
            let filename = ensureThumbnail(for: garment, slot: slot)
            let item = TodaySnapshotItem(
                slot: slot.rawValue,
                garmentID: garment.id.uuidString,
                title: garment.displayTitle,
                thumbFilename: filename ?? ""
            )
            items.append(item)
        }

        return items
    }

    private static func ensureThumbnail(for garment: Garment, slot: OutfitSlot) -> String? {
        guard let image = garment.resolvedImage else { return nil }
        guard let base = appGroupURL() else { return nil }
        let folderURL = base.appendingPathComponent(imageFolder, isDirectory: true)
        if !FileManager.default.fileExists(atPath: folderURL.path) {
            try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }

        let filename = "thumb-\(slot.rawValue)-\(garment.id.uuidString).jpg"
        let url = folderURL.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: url.path) {
            return filename
        }

        let size = CGSize(width: 300, height: 375)
        let renderer = UIGraphicsImageRenderer(size: size)
        let thumbnail = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }

        if let data = thumbnail.jpegData(compressionQuality: 0.85) {
            try? data.write(to: url, options: .atomic)
            return filename
        }
        return nil
    }

    private static func writeSnapshot(_ snapshot: TodaySnapshot) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: snapshotKey)
        }
    }

    private static func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func appGroupURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private static func reloadTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "WearItWidget")
        #endif
    }
}
