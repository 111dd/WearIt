import Foundation
import SwiftData
import UserNotifications

enum NotificationType: String, CaseIterable {
    case morningPlan = "wearit.morningPlan"
    case weatherUpdate = "wearit.weatherUpdate"
    case confirmWorn = "wearit.confirmWorn"
}

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    private override init() {}

    private var container: ModelContainer?

    func configure(container: ModelContainer) {
        self.container = container
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategories()
        Task { await requestAuthorization() }
    }

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    private func registerCategories() {
        let openPlanner = UNNotificationAction(
            identifier: "openPlanner",
            title: String(localized: "notif_action_open_planner"),
            options: [.foreground]
        )
        let updateOutfit = UNNotificationAction(
            identifier: "updateOutfit",
            title: String(localized: "notif_action_update_outfit"),
            options: [.foreground]
        )
        let markWorn = UNNotificationAction(
            identifier: "markWorn",
            title: String(localized: "notif_action_mark_worn"),
            options: []
        )
        let skip = UNNotificationAction(
            identifier: "skip",
            title: String(localized: "notif_action_skip"),
            options: []
        )

        let morning = UNNotificationCategory(
            identifier: NotificationType.morningPlan.rawValue,
            actions: [openPlanner],
            intentIdentifiers: []
        )
        let weather = UNNotificationCategory(
            identifier: NotificationType.weatherUpdate.rawValue,
            actions: [updateOutfit],
            intentIdentifiers: []
        )
        let confirm = UNNotificationCategory(
            identifier: NotificationType.confirmWorn.rawValue,
            actions: [markWorn, skip],
            intentIdentifiers: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([morning, weather, confirm])
    }

    // MARK: - Scheduling

    @MainActor
    func scheduleDailyNotifications(context: ModelContext) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let prefs = ensurePreferences(context: context)

        updateIgnoreStreaks(prefs)
        try? context.save()

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: NotificationType.allCases.map { $0.rawValue })

        let today = Calendar.current.startOfDay(for: Date())
        let plan = DayPlanService.shared.planFor(date: today, context: context)
        let hasOutfit = plan.hasSelectedItems || !plan.slotAssignments.isEmpty

        var scheduledCount = 0

        if prefs.morningEnabled,
           hasOutfit,
           prefs.ignoreStreakMorning < 3,
           shouldSchedule(type: .morningPlan, prefs: prefs),
           !isQuietTime(hour: prefs.morningHour, minute: prefs.morningMinute, prefs: prefs) {
            if scheduleMorning(plan: plan, prefs: prefs) {
                prefs.lastSentMorning = Date()
                scheduledCount += 1
            }
        }

        var weatherScheduled = false
        let now = Date()
        let nowComponents = Calendar.current.dateComponents([.hour, .minute], from: now)
        let isQuietNow = isQuietTime(hour: nowComponents.hour ?? 0, minute: nowComponents.minute ?? 0, prefs: prefs)

        if prefs.weatherEnabled,
           prefs.ignoreStreakWeather < 3,
           scheduledCount < 2,
           !isQuietNow,
           hasOutfit,
           shouldSchedule(type: .weatherUpdate, prefs: prefs),
           await shouldSendWeatherUpdate(plan: plan, context: context) {
            if scheduleWeatherUpdate() {
                prefs.lastSentWeather = Date()
                scheduledCount += 1
                weatherScheduled = true
            }
        }

        if prefs.confirmEnabled,
           hasOutfit,
           !plan.wasWornConfirmed,
           prefs.ignoreStreakConfirm < 3,
           scheduledCount < 2,
           !weatherScheduled,
           shouldSchedule(type: .confirmWorn, prefs: prefs),
           !isQuietTime(hour: prefs.confirmHour, minute: prefs.confirmMinute, prefs: prefs) {
            if scheduleConfirmWorn(prefs: prefs) {
                prefs.lastSentConfirm = Date()
                scheduledCount += 1
            }
        }

        try? context.save()
    }

    @MainActor private func scheduleMorning(plan: DayPlan, prefs: NotificationPreferences) -> Bool {
        let content = UNMutableNotificationContent()
        let location = ForecastService.shared.locationName ?? String(localized: "location_unavailable")
        if let forecast = ForecastService.shared.forecast(for: 0) {
            content.title = String(
                format: NSLocalizedString("notif_morning_title", comment: ""),
                location,
                Int(forecast.lowTempC),
                Int(forecast.highTempC)
            )
        } else {
            content.title = String(localized: "notif_morning_title_fallback")
        }
        content.body = String(localized: "notif_morning_body")
        content.categoryIdentifier = NotificationType.morningPlan.rawValue

        return scheduleNotification(
            id: NotificationType.morningPlan.rawValue,
            hour: prefs.morningHour,
            minute: prefs.morningMinute,
            content: content
        )
    }

    private func scheduleWeatherUpdate() -> Bool {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "notif_weather_title")
        content.body = String(localized: "notif_weather_body")
        content.categoryIdentifier = NotificationType.weatherUpdate.rawValue

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
        let request = UNNotificationRequest(identifier: NotificationType.weatherUpdate.rawValue, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
        return true
    }

    private func scheduleConfirmWorn(prefs: NotificationPreferences) -> Bool {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "notif_confirm_title")
        content.body = String(localized: "notif_confirm_body")
        content.categoryIdentifier = NotificationType.confirmWorn.rawValue

        return scheduleNotification(
            id: NotificationType.confirmWorn.rawValue,
            hour: prefs.confirmHour,
            minute: prefs.confirmMinute,
            content: content
        )
    }

    private func scheduleNotification(id: String, hour: Int, minute: Int, content: UNMutableNotificationContent) -> Bool {
        guard let nextDate = nextDateFor(hour: hour, minute: minute) else { return false }
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: nextDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
        return true
    }

    // MARK: - Weather Update Logic

    @MainActor
    private func shouldSendWeatherUpdate(plan: DayPlan, context: ModelContext) async -> Bool {
        guard let forecast = await ForecastService.shared.forecast(for: 0) else { return false }
        let profile = DayTemperatureProfile(from: forecast)

        let prevHigh = plan.contextTempHigh ?? profile.highTemp
        let prevLow = plan.contextTempLow ?? profile.lowTemp
        let prevRange = prevHigh - prevLow
        let newRange = profile.highTemp - profile.lowTemp
        let rangeChanged = abs(newRange - prevRange) >= 6

        let prevEvening = plan.contextEveningTemp ?? profile.eveningTemp
        let prevAfternoon = plan.contextAfternoonTemp ?? profile.afternoonTemp
        let eveningColdNow = profile.eveningTemp < 15 || (profile.afternoonTemp - profile.eveningTemp) >= 5
        let eveningWasWarm = prevEvening >= 15 && (prevAfternoon - prevEvening) < 5
        let eveningChanged = eveningColdNow && eveningWasWarm

        let prevRain = plan.contextRainProbability ?? 0
        let rainNow = profile.rainProbability >= 0.4
        let rainChanged = rainNow && prevRain < 0.4

        let needsOuter = !outfitHasRainProtection(plan: plan, context: context)

        let shouldSend = (rangeChanged || eveningChanged || (rainChanged && needsOuter))

        plan.setWeatherProfile(profile)
        try? context.save()

        return shouldSend
    }

    @MainActor
    private func outfitHasRainProtection(plan: DayPlan, context: ModelContext) -> Bool {
        let ids = Set(plan.slotAssignments.values)
        let garments = (try? context.fetch(FetchDescriptor<Garment>())) ?? []
        return garments.contains { garment in
            guard ids.contains(garment.id) else { return false }
            if garment.category == .outer { return true }
            if let tags = garment.weatherTags {
                return tags.contains(.rainFriendly) || tags.contains(.waterproof)
            }
            return false
        }
    }

    // MARK: - Helpers

    @MainActor
    private func ensurePreferences(context: ModelContext) -> NotificationPreferences {
        if let prefs = try? context.fetch(FetchDescriptor<NotificationPreferences>()).first {
            return prefs
        }
        let prefs = NotificationPreferences()
        context.insert(prefs)
        try? context.save()
        return prefs
    }

    private func isQuietTime(hour: Int, minute: Int, prefs: NotificationPreferences) -> Bool {
        let start = prefs.quietStartHour * 60 + prefs.quietStartMinute
        let end = prefs.quietEndHour * 60 + prefs.quietEndMinute
        let current = hour * 60 + minute
        if start < end {
            return current >= start && current < end
        }
        return current >= start || current < end
    }

    private func nextDateFor(hour: Int, minute: Int) -> Date? {
        let calendar = Calendar.current
        let now = Date()
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        if let today = calendar.date(from: components), today > now {
            return today
        }
        return calendar.date(byAdding: .day, value: 1, to: calendar.date(from: components) ?? now)
    }

    private func shouldSchedule(type: NotificationType, prefs: NotificationPreferences) -> Bool {
        let calendar = Calendar.current
        let last: Date?
        switch type {
        case .morningPlan: last = prefs.lastSentMorning
        case .weatherUpdate: last = prefs.lastSentWeather
        case .confirmWorn: last = prefs.lastSentConfirm
        }
        if let last, calendar.isDateInToday(last) {
            return false
        }
        return true
    }

    private func updateIgnoreStreaks(_ prefs: NotificationPreferences) {
        if let sent = prefs.lastSentMorning,
           (prefs.lastInteractionMorning == nil || sent > prefs.lastInteractionMorning!) {
            prefs.ignoreStreakMorning += 1
        }
        if let sent = prefs.lastSentWeather,
           (prefs.lastInteractionWeather == nil || sent > prefs.lastInteractionWeather!) {
            prefs.ignoreStreakWeather += 1
        }
        if let sent = prefs.lastSentConfirm,
           (prefs.lastInteractionConfirm == nil || sent > prefs.lastInteractionConfirm!) {
            prefs.ignoreStreakConfirm += 1
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let container else { return }
        let context = ModelContext(container)
        let prefs = await ensurePreferences(context: context)

        switch response.notification.request.identifier {
        case NotificationType.morningPlan.rawValue:
            prefs.lastInteractionMorning = Date()
            prefs.ignoreStreakMorning = 0
        case NotificationType.weatherUpdate.rawValue:
            prefs.lastInteractionWeather = Date()
            prefs.ignoreStreakWeather = 0
        case NotificationType.confirmWorn.rawValue:
            prefs.lastInteractionConfirm = Date()
            prefs.ignoreStreakConfirm = 0
            if response.actionIdentifier == "markWorn" {
                await markTodayWorn(context: context)
            }
        default:
            break
        }

        try? context.save()
    }

    @MainActor private func markTodayWorn(context: ModelContext) async {
        let today = Calendar.current.startOfDay(for: Date())
        let plan = DayPlanService.shared.planFor(date: today, context: context)
        plan.wasWornConfirmed = true

        let ids = plan.slotAssignments.values
        let garments = (try? context.fetch(FetchDescriptor<Garment>())) ?? []
        for garment in garments where ids.contains(garment.id) {
            if garment.lastWorn == nil || garment.lastWorn! < today {
                garment.lastWorn = today
                garment.timesWorn += 1
                garment.loveScore = min(100, garment.loveScore + 1)
            }
        }

        WidgetSnapshotService.saveTodaySnapshot(
            plan: plan,
            garments: garments,
            forecast: ForecastService.shared.forecast(for: 0),
            locationName: ForecastService.shared.locationName
        )
    }
}
