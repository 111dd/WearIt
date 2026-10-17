import Foundation
import SwiftData

// Shared with the widget: keep in sync with `WearItWidget/WidgetShared.swift`.
struct WidgetCommand: Codable, Sendable {
    static let confirmWorn = "confirmWorn"
    static let queueKey = "widgetCommandsV2"
    /// Single command written by older builds; still read once.
    static let legacyKey = "widgetCommand"

    let type: String
    let date: String
    /// `WidgetLook.kindDay` / `kindEvening`. Missing in legacy commands (= day).
    var look: String?
    let timestamp: Date

    var lookKind: String { look ?? WidgetLook.kindDay }
}

enum WidgetCommandService {
    /// Queues "mark today's look worn" for the app to apply (App Shortcut path).
    static func enqueueConfirmWorn(for date: Date) {
        append(WidgetCommand(
            type: WidgetCommand.confirmWorn,
            date: DateFormatter.widgetDate.string(from: date),
            look: WidgetLook.kindDay,
            timestamp: Date()
        ))
    }

    /// Commands written by the widget that the app has not applied yet.
    static func pendingCommands() -> [WidgetCommand] {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshotService.appGroupID) else { return [] }
        var commands: [WidgetCommand] = []
        if let data = defaults.data(forKey: WidgetCommand.queueKey),
           let queued = try? JSONDecoder().decode([WidgetCommand].self, from: data) {
            commands = queued
        }
        if let data = defaults.data(forKey: WidgetCommand.legacyKey),
           let legacy = try? JSONDecoder().decode(WidgetCommand.self, from: data) {
            commands.append(legacy)
        }
        return commands
    }

    /// Applies every queued widget tap (oldest first), then rebuilds the widget, so it
    /// also catches up after midnight or a sync from another device. Runs on app activation.
    @MainActor static func consumeIfNeeded(context: ModelContext) {
        let commands = pendingCommands().sorted { $0.timestamp < $1.timestamp }

        for command in commands where command.type == WidgetCommand.confirmWorn {
            guard let date = DateFormatter.widgetDate.date(from: command.date) else { continue }
            markWorn(date: date, isEvening: command.lookKind == WidgetLook.kindEvening, context: context, refreshWidget: false)
        }

        if let defaults = UserDefaults(suiteName: WidgetSnapshotService.appGroupID) {
            defaults.removeObject(forKey: WidgetCommand.queueKey)
            defaults.removeObject(forKey: WidgetCommand.legacyKey)
        }
        WidgetSnapshotService.refresh(context: context)
    }

    /// Marks a day's day or evening look worn through `LookWearStatus`, records the
    /// wear once, and tells an open planner. Used by the widget and the notification action.
    @MainActor static func markWorn(
        date: Date,
        isEvening: Bool,
        context: ModelContext,
        refreshWidget: Bool = true
    ) {
        let day = Calendar.current.startOfDay(for: date)
        let plan = DayPlanService.shared.planFor(date: day, context: context)
        let alreadyWorn = isEvening
            ? plan.eveningLookWearStatus == .worn
            : plan.resolvedDayLookWearStatus == .worn
        let garmentIDs = Array(isEvening ? plan.eveningSlotAssignments.values : plan.slotAssignments.values)

        if !alreadyWorn, !garmentIDs.isEmpty {
            if isEvening {
                plan.applyEveningLookWearStatus(.worn)
            } else {
                plan.applyDayLookWearStatus(.worn)
            }
            WearHistoryService.recordWorn(
                date: day,
                garmentIDs: garmentIDs,
                source: isEvening ? .plannerEvening : .planner,
                context: context,
                outfitID: nil,
                incrementTimesWorn: true,
                loveScoreDelta: 1
            )
            try? context.save()
            NotificationCenter.default.post(
                name: .lookMarkedWornOutside,
                object: nil,
                userInfo: ["date": day, "isEvening": isEvening]
            )
        }

        if refreshWidget {
            WidgetSnapshotService.refresh(context: context)
        }
    }

    private static func append(_ command: WidgetCommand) {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshotService.appGroupID) else { return }
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
}

extension DateFormatter {
    static let widgetDate: DateFormatter = {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()
}
