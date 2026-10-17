//
//  AppIntent.swift
//  WearItWidget
//
//  Created by Dor David on 03/02/2026.
//

import WidgetKit
import AppIntents

/// The widget's "I wore it" button. The widget can't write the app's store, so it
/// marks the look in the snapshot right away and queues a command the app applies
/// (wear status, history, iCloud) the next time it opens or comes to the foreground.
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
        if var snapshot = WidgetSnapshotReader.loadSnapshot(),
           let index = snapshot.looks.firstIndex(where: { $0.date == dateString && $0.kind == look }) {
            snapshot.looks[index].status = "worn"
            WidgetSnapshotReader.saveSnapshot(snapshot)
        }

        WidgetSnapshotReader.appendCommand(
            WidgetCommand(type: WidgetCommand.confirmWorn, date: dateString, look: look, timestamp: Date())
        )

        WidgetCenter.shared.reloadTimelines(ofKind: "WearItWidget")
        return .result()
    }
}
