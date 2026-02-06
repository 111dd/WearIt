import Foundation
import SwiftData

struct WidgetCommand: Codable {
    let type: String
    let date: String
    let timestamp: Date
}

enum WidgetCommandService {
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

        let garmentIDs = plan.slotAssignments.values
        let garments = (try? context.fetch(FetchDescriptor<Garment>())) ?? []
        for garment in garments where garmentIDs.contains(garment.id) {
            if garment.lastWorn == nil || garment.lastWorn! < day {
                garment.lastWorn = day
                garment.timesWorn += 1
                garment.loveScore = min(100, garment.loveScore + 1)
            }
        }

        try? context.save()

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
