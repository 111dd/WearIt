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

    // Planner debounced persistence
    static let plannerFlushDirtyPlans = Notification.Name("PlannerFlushDirtyPlans")

    // Profile pref save (debounced)
    static let profileFlushPrefsSave = Notification.Name("ProfileFlushPrefsSave")
    static let profileScheduleNotifications = Notification.Name("ProfileScheduleNotifications")
    static let wardrobeRebuildVisible = Notification.Name("WardrobeRebuildVisible")
}

