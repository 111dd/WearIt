import Foundation
import SwiftData

@Model
final class NotificationPreferences {
    var id: String = "global"

    var morningEnabled: Bool = true
    var morningHour: Int = 7
    var morningMinute: Int = 30

    var weatherEnabled: Bool = true

    var confirmEnabled: Bool = true
    var confirmHour: Int = 20
    var confirmMinute: Int = 30

    var quietStartHour: Int = 22
    var quietStartMinute: Int = 0
    var quietEndHour: Int = 7
    var quietEndMinute: Int = 0

    var lastSentMorning: Date?
    var lastSentWeather: Date?
    var lastSentConfirm: Date?

    var lastInteractionMorning: Date?
    var lastInteractionWeather: Date?
    var lastInteractionConfirm: Date?

    var ignoreStreakMorning: Int = 0
    var ignoreStreakWeather: Int = 0
    var ignoreStreakConfirm: Int = 0

    init(
        id: String = "global",
        morningEnabled: Bool = true,
        morningHour: Int = 7,
        morningMinute: Int = 30,
        weatherEnabled: Bool = true,
        confirmEnabled: Bool = true,
        confirmHour: Int = 20,
        confirmMinute: Int = 30,
        quietStartHour: Int = 22,
        quietStartMinute: Int = 0,
        quietEndHour: Int = 7,
        quietEndMinute: Int = 0,
        lastSentMorning: Date? = nil,
        lastSentWeather: Date? = nil,
        lastSentConfirm: Date? = nil,
        lastInteractionMorning: Date? = nil,
        lastInteractionWeather: Date? = nil,
        lastInteractionConfirm: Date? = nil,
        ignoreStreakMorning: Int = 0,
        ignoreStreakWeather: Int = 0,
        ignoreStreakConfirm: Int = 0
    ) {
        self.id = id
        self.morningEnabled = morningEnabled
        self.morningHour = morningHour
        self.morningMinute = morningMinute
        self.weatherEnabled = weatherEnabled
        self.confirmEnabled = confirmEnabled
        self.confirmHour = confirmHour
        self.confirmMinute = confirmMinute
        self.quietStartHour = quietStartHour
        self.quietStartMinute = quietStartMinute
        self.quietEndHour = quietEndHour
        self.quietEndMinute = quietEndMinute
        self.lastSentMorning = lastSentMorning
        self.lastSentWeather = lastSentWeather
        self.lastSentConfirm = lastSentConfirm
        self.lastInteractionMorning = lastInteractionMorning
        self.lastInteractionWeather = lastInteractionWeather
        self.lastInteractionConfirm = lastInteractionConfirm
        self.ignoreStreakMorning = ignoreStreakMorning
        self.ignoreStreakWeather = ignoreStreakWeather
        self.ignoreStreakConfirm = ignoreStreakConfirm
    }
}
