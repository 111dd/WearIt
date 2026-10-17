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
    /// A look was marked worn from the widget or a notification. `userInfo["date"]` is the
    /// start of day, `userInfo["isEvening"]` a Bool. The planner updates its board so a
    /// later save doesn't undo it.
    static let lookMarkedWornOutside = Notification.Name("LookMarkedWornOutside")

    /// Calendar → planner hand-off. `userInfo["date"]` is the start-of-day to focus.
    static let openPlannerDay = Notification.Name("OpenPlannerDay")

    // Planner debounced persistence
    static let plannerFlushDirtyPlans = Notification.Name("PlannerFlushDirtyPlans")

    // Profile pref save (debounced)
    static let profileFlushPrefsSave = Notification.Name("ProfileFlushPrefsSave")
    static let profileScheduleNotifications = Notification.Name("ProfileScheduleNotifications")
    static let wardrobeRebuildVisible = Notification.Name("WardrobeRebuildVisible")
}

