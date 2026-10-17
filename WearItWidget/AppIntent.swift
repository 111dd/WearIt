//
//  AppIntent.swift
//  WearItWidget
//
//  Created by Dor David on 03/02/2026.
//

import WidgetKit
import AppIntents

// The widget can't write the app's store, so every button updates the snapshot (or the
// widget's own UI state) right away and queues a command the app applies (wear status,
// history, learning, iCloud) the next time it opens or comes to the foreground.

private enum WidgetActions {
    static func queue(_ type: String, date: String, look: String, slots: [String: String]? = nil, value: String? = nil) {
        WidgetSnapshotReader.appendCommand(
            WidgetCommand(type: type, date: date, look: look, slots: slots, value: value, timestamp: Date())
        )
    }

    static func updateLook(date: String, look: String, _ change: (inout WidgetLook) -> Void) {
        guard var snapshot = WidgetSnapshotReader.loadSnapshot(),
              let index = snapshot.looks.firstIndex(where: { $0.date == date && $0.kind == look }) else { return }
        change(&snapshot.looks[index])
        WidgetSnapshotReader.saveSnapshot(snapshot)
    }

    static var todayKey: String { DateFormatter.widgetDate.string(from: Date()) }
}

/// "I wore it".
struct ConfirmWornIntent: AppIntent {
    static var title: LocalizedStringResource { "widget_intent_confirm_title" }
    static var description: IntentDescription { IntentDescription("widget_intent_confirm_description") }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "widget_intent_param_date")
    var dateString: String

    @Parameter(title: "widget_intent_param_look")
    var look: String

    init() {
        self.dateString = DateFormatter.widgetDate.string(from: Date())
        self.look = WidgetLook.kindDay
    }

    init(dateString: String, look: String) {
        self.dateString = dateString
        self.look = look
    }

    func perform() async throws -> some IntentResult {
        WidgetActions.updateLook(date: dateString, look: look) { $0.status = "worn" }
        WidgetActions.queue(WidgetCommand.confirmWorn, date: dateString, look: look)
        WidgetCenter.shared.reloadTimelines(ofKind: "WearItWidget")
        return .result()
    }
}

/// "Not today".
struct NotWornIntent: AppIntent {
    static var title: LocalizedStringResource { "widget_intent_not_worn_title" }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "widget_intent_param_date")
    var dateString: String

    @Parameter(title: "widget_intent_param_look")
    var look: String

    init() {
        self.dateString = DateFormatter.widgetDate.string(from: Date())
        self.look = WidgetLook.kindDay
    }

    init(dateString: String, look: String) {
        self.dateString = dateString
        self.look = look
    }

    func perform() async throws -> some IntentResult {
        WidgetActions.updateLook(date: dateString, look: look) { $0.status = "notWorn" }
        WidgetActions.queue(WidgetCommand.notWorn, date: dateString, look: look)
        WidgetCenter.shared.reloadTimelines(ofKind: "WearItWidget")
        return .result()
    }
}

/// ↻: shows the next ready look and queues it as the day's look.
struct NextLookIntent: AppIntent {
    static var title: LocalizedStringResource { "widget_intent_next_look_title" }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "widget_intent_param_date")
    var dateString: String

    @Parameter(title: "widget_intent_param_look")
    var look: String

    init() {
        self.dateString = DateFormatter.widgetDate.string(from: Date())
        self.look = WidgetLook.kindDay
    }

    init(dateString: String, look: String) {
        self.dateString = dateString
        self.look = look
    }

    func perform() async throws -> some IntentResult {
        guard let current = WidgetSnapshotReader.loadSnapshot()?.look(date: dateString, kind: look) else {
            return .result()
        }
        var state = WidgetUIState.load(today: WidgetActions.todayKey)
        let options = current.allOptions
        guard options.count > 1 else { return .result() }
        let next = options[(current.shownIndex(in: state) + 1) % options.count]
        state.shown[WidgetUIState.lookKey(current)] = next.map(\.garmentID)
        state.save()

        let slots = Dictionary(next.map { ($0.slot, $0.garmentID) }, uniquingKeysWith: { first, _ in first })
        WidgetActions.queue(WidgetCommand.chooseLook, date: dateString, look: look, slots: slots)
        WidgetCenter.shared.reloadTimelines(ofKind: "WearItWidget")
        return .result()
    }
}

/// Today / This evening / Tomorrow tabs.
struct SelectLookTabIntent: AppIntent {
    static var title: LocalizedStringResource { "widget_intent_tab_title" }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "widget_intent_param_look")
    var role: String

    init() {
        self.role = "today"
    }

    init(role: String) {
        self.role = role
    }

    func perform() async throws -> some IntentResult {
        var state = WidgetUIState.load(today: WidgetActions.todayKey)
        state.tab = role
        state.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "WearItWidget")
        return .result()
    }
}

/// 😍 / 🥶 / 🥵 after "I wore it".
struct LookFeedbackIntent: AppIntent {
    static var title: LocalizedStringResource { "widget_intent_feedback_title" }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "widget_intent_param_date")
    var dateString: String

    @Parameter(title: "widget_intent_param_feedback")
    var value: String

    init() {
        self.dateString = DateFormatter.widgetDate.string(from: Date())
        self.value = WidgetCommand.feedbackLoved
    }

    init(dateString: String, value: String) {
        self.dateString = dateString
        self.value = value
    }

    func perform() async throws -> some IntentResult {
        WidgetActions.updateLook(date: dateString, look: WidgetLook.kindDay) { $0.reaction = value }
        WidgetActions.queue(WidgetCommand.feedback, date: dateString, look: WidgetLook.kindDay, value: value)
        WidgetCenter.shared.reloadTimelines(ofKind: "WearItWidget")
        return .result()
    }
}
