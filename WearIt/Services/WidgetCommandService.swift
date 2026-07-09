import Foundation
import SwiftData

struct WidgetCommand: Codable {
    let type: String
    let date: String
    let timestamp: Date
}

enum WidgetCommandService {
    static func enqueueConfirmWorn(for date: Date) {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshotService.appGroupID) else {
            return
        }

        let command = WidgetCommand(
            type: "confirmWorn",
            date: DateFormatter.widgetDate.string(from: date),
            timestamp: Date()
        )

        guard let data = try? JSONEncoder().encode(command) else {
            return
        }

        defaults.set(data, forKey: WidgetSnapshotService.commandKey)
    }

    @MainActor static func consumeIfNeeded(context: ModelContext) {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshotService.appGroupID),
              let data = defaults.data(forKey: WidgetSnapshotService.commandKey),
              let command = try? JSONDecoder().decode(WidgetCommand.self, from: data) else {
            return
        }

        if command.type == "confirmWorn" {
            applyConfirmWorn(dateString: command.date, context: context)
        }

        defaults.removeObject(forKey: WidgetSnapshotService.commandKey)
    }

    @MainActor private static func applyConfirmWorn(dateString: String, context: ModelContext) {
        let date = DateFormatter.widgetDate.date(from: dateString) ?? Date()
        let day = Calendar.current.startOfDay(for: date)
        let plan = DayPlanService.shared.planFor(date: day, context: context)
        plan.wasWornConfirmed = true

        let garmentIDs = Array(plan.slotAssignments.values)
        WearHistoryService.recordWorn(
            date: day,
            garmentIDs: garmentIDs,
            source: .planner,
            context: context,
            outfitID: plan.id,
            incrementTimesWorn: true,
            loveScoreDelta: 1
        )

        let garments = (try? context.fetch(FetchDescriptor<Garment>())) ?? []

        WidgetSnapshotService.saveTodaySnapshot(
            plan: plan,
            garments: garments,
            forecast: ForecastService.shared.forecast(for: 0),
            locationName: ForecastService.shared.locationName
        )
    }
}

extension DateFormatter {
    static let widgetDate: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()
}
