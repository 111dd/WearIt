import Foundation
import SwiftUI

// Shared with the app: keep in sync with `WearIt/Services/WidgetSnapshotStore.swift`
// and `WearIt/Services/WidgetCommandService.swift`.

struct WidgetLookItem: Codable {
    let slot: String
    let garmentID: String
    let title: String
    let thumbFilename: String
}

/// One look the widget can show: today's day or evening look, or tomorrow's.
struct WidgetLook: Codable {
    static let kindDay = "day"
    static let kindEvening = "evening"

    let date: String           // yyyy-MM-dd
    let kind: String           // kindDay / kindEvening
    var status: String?        // "planned" / "worn" / "notWorn", nil = undecided
    let lowTempC: Double?
    let highTempC: Double?
    let rainChance: Double?    // 0...1
    var reason: String?
    let items: [WidgetLookItem]

    var isWorn: Bool { status == "worn" }
    var isNotWorn: Bool { status == "notWorn" }
    /// Undecided or only "I'll wear this": the user can still say they wore it.
    var isOpen: Bool { status == nil || status == "planned" }
}

struct WidgetSnapshot: Codable {
    let savedAt: Date
    let locationName: String?
    var looks: [WidgetLook]

    func look(date: String, kind: String) -> WidgetLook? {
        looks.first { $0.date == date && $0.kind == kind }
    }
}

struct WidgetCommand: Codable {
    static let confirmWorn = "confirmWorn"
    static let queueKey = "widgetCommandsV2"

    let type: String
    let date: String
    var look: String?
    let timestamp: Date
}

enum WidgetSnapshotReader {
    static let appGroupID = "group.com.dordavid.WearIt"
    static let snapshotKey = "widgetSnapshotV2"
    private static let imageFolder = "Thumbs"

    static func loadSnapshot() -> WidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func saveSnapshot(_ snapshot: WidgetSnapshot) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: snapshotKey)
        }
    }

    /// Appends to the queue the app applies on its next launch or activation,
    /// so several taps before opening the app are all kept.
    static func appendCommand(_ command: WidgetCommand) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        var queue: [WidgetCommand] = []
        if let data = defaults.data(forKey: WidgetCommand.queueKey),
           let decoded = try? JSONDecoder().decode([WidgetCommand].self, from: data) {
            queue = decoded
        }
        queue.append(command)
        if let data = try? JSONEncoder().encode(queue) {
            defaults.set(data, forKey: WidgetCommand.queueKey)
        }
    }

    static func image(for filename: String) -> Image? {
        guard !filename.isEmpty,
              let url = imageURL(for: filename),
              let uiImage = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: uiImage)
    }

    private static func imageURL(for filename: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(imageFolder, isDirectory: true)
            .appendingPathComponent(filename)
    }
}

extension DateFormatter {
    /// Same format as the app's: Gregorian and POSIX, whatever the device calendar.
    static let widgetDate: DateFormatter = {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()
}
