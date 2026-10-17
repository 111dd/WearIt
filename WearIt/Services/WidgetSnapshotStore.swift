import Foundation
import UIKit
import os
import SwiftData
#if canImport(WidgetKit)
import WidgetKit
#endif

// Shared with the widget: keep in sync with `WearItWidget/WidgetShared.swift`.

struct WidgetLookItem: Codable, Sendable {
    let slot: String
    let garmentID: String
    let title: String
    let thumbFilename: String
}

/// One look the widget can show: today's day or evening look, or tomorrow's.
struct WidgetLook: Codable, Sendable {
    static let kindDay = "day"
    static let kindEvening = "evening"

    let date: String           // yyyy-MM-dd
    let kind: String           // kindDay / kindEvening
    var status: String?        // LookWearStatus.rawValue, nil = undecided
    let lowTempC: Double?
    let highTempC: Double?
    let rainChance: Double?    // 0...1
    var reason: String?
    let items: [WidgetLookItem]
}

struct WidgetSnapshot: Codable, Sendable {
    let savedAt: Date
    let locationName: String?
    var looks: [WidgetLook]

    func look(date: String, kind: String) -> WidgetLook? {
        looks.first { $0.date == date && $0.kind == kind }
    }
}

/// Sendable garment image inputs for off-main widget thumbnail work.
private struct WidgetThumbSource: Sendable {
    let slotRaw: String
    let garmentID: UUID
    let title: String
    let imagePath: String?
    let imageData: Data?
}

private struct WidgetLookDraft: Sendable {
    let date: String
    let kind: String
    let status: String?
    let lowTempC: Double?
    let highTempC: Double?
    let rainChance: Double?
    let reason: String?
    let sources: [WidgetThumbSource]
}

private struct WidgetSnapshotDraft: Sendable {
    let locationName: String?
    let looks: [WidgetLookDraft]
    /// False when the caller has no reasons (e.g. a notification action): keep the last ones.
    let reasonsAreFresh: Bool
}

enum WidgetSnapshotService {
    static let appGroupID = "group.com.dordavid.WearIt"
    static let snapshotKey = "widgetSnapshotV2"
    fileprivate static let legacySnapshotKey = "todaySnapshotV1"
    static let widgetKind = "WearItWidget"
    fileprivate static let imageFolder = "Thumbs"
    fileprivate static let thumbMaxPixel: CGFloat = 400

    /// Writes today's and tomorrow's looks (day + evening) for the widget.
    /// Captures plan state on the calling actor, then makes thumbnails off-main.
    /// `dayReasons` (keyed by start of day) is the planner's top "why this look" line;
    /// pass nil to keep the reasons already in the widget.
    @MainActor static func saveSnapshot(
        plans: [DayPlan],
        garments: [Garment],
        forecasts: [DayForecast],
        locationName: String?,
        dayReasons: [Date: String]? = nil
    ) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let garmentsByID = Dictionary(garments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var looks: [WidgetLookDraft] = []
        for plan in plans.sorted(by: { $0.date < $1.date }) {
            let day = calendar.startOfDay(for: plan.date)
            guard day == today || day == tomorrow else { continue }
            let forecast = forecasts.first { calendar.isDate($0.date, inSameDayAs: day) }
            let date = DateFormatter.widgetDate.string(from: day)

            let daySources = thumbSources(plan.slotAssignments, garmentsByID: garmentsByID)
            if !daySources.isEmpty {
                looks.append(WidgetLookDraft(
                    date: date,
                    kind: WidgetLook.kindDay,
                    status: plan.resolvedDayLookWearStatus?.rawValue,
                    lowTempC: forecast?.lowTempC,
                    highTempC: forecast?.highTempC,
                    rainChance: forecast?.rainProbability,
                    reason: dayReasons?[day],
                    sources: daySources
                ))
            }

            let eveningSources = plan.eveningEnabled == true
                ? thumbSources(plan.eveningSlotAssignments, garmentsByID: garmentsByID)
                : []
            if !eveningSources.isEmpty {
                looks.append(WidgetLookDraft(
                    date: date,
                    kind: WidgetLook.kindEvening,
                    status: plan.eveningLookWearStatus?.rawValue,
                    lowTempC: forecast?.lowTempC,
                    highTempC: forecast?.highTempC,
                    rainChance: forecast?.rainProbability,
                    reason: nil,
                    sources: eveningSources
                ))
            }
        }

        let draft = WidgetSnapshotDraft(
            locationName: locationName,
            looks: looks,
            reasonsAreFresh: dayReasons != nil
        )
        Task(priority: .utility) {
            await WidgetSnapshotCoordinator.shared.save(draft)
        }
    }

    /// Rebuilds the snapshot from the store, for callers outside the planner.
    @MainActor static func refresh(context: ModelContext) {
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        let plans = DayPlanService.shared.plans(from: today, to: tomorrow, context: context)
        let ids = Array(Set(plans.flatMap { Array($0.slotAssignments.values) + Array($0.eveningSlotAssignments.values) }))
        let descriptor = FetchDescriptor<Garment>(predicate: #Predicate { ids.contains($0.id) })
        let garments = ids.isEmpty ? [] : ((try? context.fetch(descriptor)) ?? [])
        saveSnapshot(
            plans: plans,
            garments: garments,
            forecasts: ForecastService.shared.forecasts,
            locationName: ForecastService.shared.locationName
        )
    }

    static func loadSnapshot() -> WidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func imageURL(for filename: String) -> URL? {
        thumbFolderURL()?.appendingPathComponent(filename)
    }

    // MARK: - Internal

    private static func thumbSources(
        _ assignments: [OutfitSlot: UUID],
        garmentsByID: [UUID: Garment]
    ) -> [WidgetThumbSource] {
        OutfitSlot.allCases.compactMap { slot in
            guard let id = assignments[slot], let garment = garmentsByID[id] else { return nil }
            return WidgetThumbSource(
                slotRaw: slot.rawValue,
                garmentID: garment.id,
                title: garment.displayTitle,
                imagePath: garment.imagePath,
                imageData: garment.imagePath == nil ? garment.imageData : nil
            )
        }
    }

    fileprivate static func thumbFolderURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(imageFolder, isDirectory: true)
    }

    fileprivate static func writeSnapshot(_ snapshot: WidgetSnapshot) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: snapshotKey)
        }
        defaults.removeObject(forKey: legacySnapshotKey)
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

        let previous = WidgetSnapshotService.loadSnapshot()
        // A tap in the widget the app hasn't applied yet still counts, so a save
        // made before the command is consumed doesn't flip the look back.
        let pending = WidgetCommandService.pendingCommands()

        var referenced = Set<String>()
        let looks: [WidgetLook] = draft.looks.map { look in
            let items: [WidgetLookItem] = look.sources.map { source in
                let filename = ensureThumbnail(for: source) ?? ""
                if !filename.isEmpty { referenced.insert(filename) }
                return WidgetLookItem(
                    slot: source.slotRaw,
                    garmentID: source.garmentID.uuidString,
                    title: source.title,
                    thumbFilename: filename
                )
            }
            let confirmedInWidget = pending.contains {
                $0.type == WidgetCommand.confirmWorn && $0.date == look.date && $0.lookKind == look.kind
            }
            let reason = draft.reasonsAreFresh
                ? look.reason
                : previous?.look(date: look.date, kind: look.kind)?.reason
            return WidgetLook(
                date: look.date,
                kind: look.kind,
                status: confirmedInWidget ? LookWearStatus.worn.rawValue : look.status,
                lowTempC: look.lowTempC,
                highTempC: look.highTempC,
                rainChance: look.rainChance,
                reason: reason,
                items: items
            )
        }

        WidgetSnapshotService.writeSnapshot(
            WidgetSnapshot(savedAt: Date(), locationName: draft.locationName, looks: looks)
        )
        removeUnusedThumbnails(keeping: referenced)
        scheduleReload()
    }

    /// Downsamples the garment photo into `Thumbs/{uuid}-{version}.png`. The version
    /// follows the source file's modification date, so a new photo gets a new thumb.
    /// PNG keeps a cutout's transparency for the widget's flat-lay.
    private func ensureThumbnail(for source: WidgetThumbSource) -> String? {
        let thumbState = signposter.beginInterval("widget-thumb")
        defer { signposter.endInterval("widget-thumb", thumbState) }

        guard let folderURL = WidgetSnapshotService.thumbFolderURL() else { return nil }
        if !FileManager.default.fileExists(atPath: folderURL.path) {
            do {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }

        let fileURL = source.imagePath.flatMap { ImageStore.absoluteURL(path: $0) }
        let version: Int
        if let fileURL {
            let modified = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
            version = Int(modified?.timeIntervalSince1970 ?? 0)
        } else if let data = source.imageData {
            version = data.count
        } else {
            return nil
        }

        let filename = "\(source.garmentID.uuidString)-\(version).png"
        let url = folderURL.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: url.path) {
            return filename
        }

        let maxPixel = WidgetSnapshotService.thumbMaxPixel
        let downsampled: UIImage?
        if let fileURL {
            downsampled = ImageStore.downsample(url: fileURL, maxPixelSize: maxPixel)
        } else if let data = source.imageData {
            downsampled = ImageStore.downsample(data: data, maxPixelSize: maxPixel)
        } else {
            downsampled = nil
        }

        guard let data = downsampled?.pngData() else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    private func removeUnusedThumbnails(keeping referenced: Set<String>) {
        guard let folderURL = WidgetSnapshotService.thumbFolderURL(),
              let files = try? FileManager.default.contentsOfDirectory(atPath: folderURL.path) else { return }
        for file in files where !referenced.contains(file) {
            try? FileManager.default.removeItem(at: folderURL.appendingPathComponent(file))
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
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotService.widgetKind)
            #endif
        }
    }
}
