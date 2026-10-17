//
//  Notifications.swift
//  WearIt
//
//  Common notification names.
//

import Foundation

extension Notification.Name {
    // Garment lifecycle
    static let garmentAdded = Notification.Name("GarmentAdded")
    static let garmentUpdated = Notification.Name("GarmentUpdated")
    static let garmentDeleted = Notification.Name("GarmentDeleted")
    
    // Wardrobe sync
    static let wardrobeDidSync = Notification.Name("WardrobeDidSync")

    // Widget actions
    static let confirmWornFromWidget = Notification.Name("ConfirmWornFromWidget")
    /// The widget or a notification changed a day's plan in the store (worn, not worn,
    /// another look). `userInfo["date"]` is the start of day. The planner reloads that day
    /// so a later save doesn't undo it.
    static let dayPlanChangedOutside = Notification.Name("DayPlanChangedOutside")
    /// Widget reactions (😍🥶🥵) are waiting in `WidgetCommandService.takePlannerFeedback()`.
    static let widgetFeedbackPending = Notification.Name("WidgetFeedbackPending")

    /// Calendar → planner hand-off. `userInfo["date"]` is the start-of-day to focus.
    static let openPlannerDay = Notification.Name("OpenPlannerDay")

    // Planner debounced persistence
    static let plannerFlushDirtyPlans = Notification.Name("PlannerFlushDirtyPlans")

    // Profile pref save (debounced)
    static let profileFlushPrefsSave = Notification.Name("ProfileFlushPrefsSave")
    static let profileScheduleNotifications = Notification.Name("ProfileScheduleNotifications")
    static let wardrobeRebuildVisible = Notification.Name("WardrobeRebuildVisible")
}

