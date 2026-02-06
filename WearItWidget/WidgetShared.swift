import Foundation
import SwiftUI

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

enum WidgetSnapshotReader {
    static let appGroupID = "group.com.dordavid.WearIt"
    static let snapshotKey = "todaySnapshotV1"
    private static let imageFolder = "Thumbs"

    static func loadSnapshot() -> TodaySnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(TodaySnapshot.self, from: data)
    }

    static func saveSnapshot(_ snapshot: TodaySnapshot) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: snapshotKey)
        }
    }

    static func writeCommand(_ command: WidgetCommand) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        if let data = try? JSONEncoder().encode(command) {
            defaults.set(data, forKey: WidgetCommand.commandKey)
        }
    }

    static func image(for filename: String) -> Image? {
        guard let url = imageURL(for: filename),
              let data = try? Data(contentsOf: url),
              let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
    }

    private static func imageURL(for filename: String) -> URL? {
        guard let base = appGroupURL() else { return nil }
        return base.appendingPathComponent(imageFolder, isDirectory: true).appendingPathComponent(filename)
    }

    private static func appGroupURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }
}

struct WidgetCommand: Codable {
    static let commandKey = "widgetCommand"
    let type: String
    let date: String
    let timestamp: Date
}
