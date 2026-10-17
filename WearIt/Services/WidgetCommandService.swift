import Foundation
import SwiftData

// Shared with the widget: keep in sync with `WearItWidget/WidgetShared.swift`.
struct WidgetCommand: Codable, Sendable {
    static let confirmWorn = "confirmWorn"
    static let notWorn = "notWorn"
    /// The user picked another of the prepared looks (`slots`: slot rawValue → garment UUID).
    static let chooseLook = "chooseLook"
    /// A reaction after wearing (`value`: `feedbackLoved` / `feedbackTooCold` / `feedbackTooWarm`).
    static let feedback = "feedback"
    static let feedbackLoved = "loved"
    static let feedbackTooCold = "tooCold"
    static let feedbackTooWarm = "tooWarm"

    static let queueKey = "widgetCommandsV2"
    /// Single command written by older builds; still read once.
    static let legacyKey = "widgetCommand"

    let type: String
    let date: String
    /// `WidgetLook.kindDay` / `kindEvening`. Missing in legacy commands (= day).
    var look: String?
    var slots: [String: String]? = nil
    var value: String? = nil
    let timestamp: Date

    var lookKind: String { look ?? WidgetLook.kindDay }
}

enum WidgetCommandService {
    /// Reactions waiting for the planner, which owns the learning behind them.
    private static let plannerFeedbackKey = "widget.pendingPlannerFeedback"

    /// Queues "mark today's look worn" for the app to apply (App Shortcut path).
    static func enqueueConfirmWorn(for date: Date) {
        append(WidgetCommand(
            type: WidgetCommand.confirmWorn,
            date: DateFormatter.widgetDate.string(from: date),
            look: WidgetLook.kindDay,
            timestamp: Date()
        ))
    }

    /// Commands written by the widget that the app has not applied yet, plus reactions
    /// already taken from the widget but not yet learned by the planner.
    static func pendingCommands() -> [WidgetCommand] {
        var commands = decodeQueue(UserDefaults(suiteName: WidgetSnapshotService.appGroupID), key: WidgetCommand.queueKey)
        if let data = UserDefaults(suiteName: WidgetSnapshotService.appGroupID)?.data(forKey: WidgetCommand.legacyKey),
           let legacy = try? JSONDecoder().decode(WidgetCommand.self, from: data) {
            commands.append(legacy)
        }
        commands += decodeQueue(.standard, key: plannerFeedbackKey)
        return commands
    }

    /// Applies every queued widget tap (oldest first), then rebuilds the widget, so it
    /// also catches up after midnight or a sync from another device. Runs on app activation.
    @MainActor static func consumeIfNeeded(context: ModelContext) {
        let shared = UserDefaults(suiteName: WidgetSnapshotService.appGroupID)
        var commands = decodeQueue(shared, key: WidgetCommand.queueKey)
        if let data = shared?.data(forKey: WidgetCommand.legacyKey),
           let legacy = try? JSONDecoder().decode(WidgetCommand.self, from: data) {
            commands.append(legacy)
        }
        shared?.removeObject(forKey: WidgetCommand.queueKey)
        shared?.removeObject(forKey: WidgetCommand.legacyKey)

        var plannerFeedback: [WidgetCommand] = []
        for command in commands.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let date = DateFormatter.widgetDate.date(from: command.date) else { continue }
            let isEvening = command.lookKind == WidgetLook.kindEvening
            switch command.type {
            case WidgetCommand.confirmWorn:
                markWorn(date: date, isEvening: isEvening, context: context, refreshWidget: false)
            case WidgetCommand.notWorn:
                markNotWorn(date: date, isEvening: isEvening, context: context)
            case WidgetCommand.chooseLook:
                chooseLook(date: date, slots: command.slots ?? [:], context: context)
            case WidgetCommand.feedback:
                plannerFeedback.append(command)
            default:
                break
            }
        }

        if !plannerFeedback.isEmpty {
            let stored = decodeQueue(.standard, key: plannerFeedbackKey) + plannerFeedback
            if let data = try? JSONEncoder().encode(stored) {
                UserDefaults.standard.set(data, forKey: plannerFeedbackKey)
            }
            NotificationCenter.default.post(name: .widgetFeedbackPending, object: nil)
        }
        WidgetSnapshotService.refresh(context: context)
    }

    /// Hands the queued reactions to the planner (which applies its own learning) and clears them.
    static func takePlannerFeedback() -> [WidgetCommand] {
        let feedback = decodeQueue(.standard, key: plannerFeedbackKey)
        UserDefaults.standard.removeObject(forKey: plannerFeedbackKey)
        return feedback
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
            postDayChanged(day)
        }

        if refreshWidget {
            WidgetSnapshotService.refresh(context: context)
        }
    }

    /// Same as the planner's "not worn": status only, no history or learning.
    @MainActor private static func markNotWorn(date: Date, isEvening: Bool, context: ModelContext) {
        let day = Calendar.current.startOfDay(for: date)
        let plan = DayPlanService.shared.planFor(date: day, context: context)
        let current = isEvening ? plan.eveningLookWearStatus : plan.resolvedDayLookWearStatus
        // A look already confirmed worn is undone in the planner, not from the widget.
        guard current != .worn, current != .notWorn else { return }
        if isEvening {
            plan.applyEveningLookWearStatus(.notWorn)
        } else {
            plan.applyDayLookWearStatus(.notWorn)
        }
        try? context.save()
        postDayChanged(day)
    }

    /// Puts one of the widget's prepared looks on the day, keeping locked slots.
    /// Neutral like the planner's swipe-to-replace: no taste or feedback signal.
    @MainActor private static func chooseLook(date: Date, slots: [String: String], context: ModelContext) {
        let day = Calendar.current.startOfDay(for: date)
        let plan = DayPlanService.shared.planFor(date: day, context: context)
        guard plan.resolvedDayLookWearStatus != .worn else { return }
        let chosen: [OutfitSlot: UUID] = slots.reduce(into: [:]) { result, pair in
            if let slot = OutfitSlot(rawValue: pair.key), let id = UUID(uuidString: pair.value) {
                result[slot] = id
            }
        }
        guard !chosen.isEmpty else { return }
        let current = plan.slotAssignments
        let locked = plan.lockedSlots
        var assignments: [OutfitSlot: UUID?] = [:]
        for slot in OutfitSlot.allCases {
            assignments[slot] = locked.contains(slot) ? current[slot] : chosen[slot]
        }
        guard assignments.compactMapValues({ $0 }) != current else { return }
        plan.setSlotAssignments(assignments, lockedSlots: locked)
        try? context.save()
        postDayChanged(day)
    }

    @MainActor private static func postDayChanged(_ day: Date) {
        NotificationCenter.default.post(name: .dayPlanChangedOutside, object: nil, userInfo: ["date": day])
    }

    private static func decodeQueue(_ defaults: UserDefaults?, key: String) -> [WidgetCommand] {
        guard let data = defaults?.data(forKey: key),
              let queue = try? JSONDecoder().decode([WidgetCommand].self, from: data) else { return [] }
        return queue
    }

    private static func append(_ command: WidgetCommand) {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshotService.appGroupID) else { return }
        let queue = decodeQueue(defaults, key: WidgetCommand.queueKey) + [command]
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
