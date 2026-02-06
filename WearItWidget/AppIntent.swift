//
//  AppIntent.swift
//  WearItWidget
//
//  Created by Dor David on 03/02/2026.
//

import WidgetKit
import AppIntents

struct ConfirmWornIntent: AppIntent {
    static var title: LocalizedStringResource { "Confirm Worn" }
    static var description: IntentDescription { "Mark today’s outfit as worn." }

    @Parameter(title: "Date (yyyy-mm-dd)")
    var dateString: String

    init() {
        self.dateString = DateFormatter.widgetDate.string(from: Date())
    }

    init(dateString: String) {
        self.dateString = dateString
    }

    func perform() async throws -> some IntentResult {
        let snapshot = WidgetSnapshotReader.loadSnapshot()
        let date = snapshot?.date ?? dateString

        // Update snapshot for immediate UI feedback
        if let snapshot {
            let updated = TodaySnapshot(
                date: snapshot.date,
                locationName: snapshot.locationName,
                lowTempC: snapshot.lowTempC,
                highTempC: snapshot.highTempC,
                confirmedWorn: true,
                items: snapshot.items
            )
            WidgetSnapshotReader.saveSnapshot(updated)
        }

        // Write command for app to consume
        let command = WidgetCommand(type: "confirmWorn", date: date, timestamp: Date())
        WidgetSnapshotReader.writeCommand(command)

        WidgetCenter.shared.reloadTimelines(ofKind: "WearItWidget")
        return .result()
    }
}

extension DateFormatter {
    static let widgetDate: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()
}
