//
//  Untitled.swift
//  WearIt
//
//  Created by Dor David on 21/10/2025.
//

import Foundation

extension Garment {
    /// האם כרגע לא זמין (כביסה) – נעלם אוטומטית אחרי התאריך
    var isCurrentlyUnavailable: Bool {
        if let until = unavailableUntil {
            return until > Date()
        }
        return false
    }

    /// זמן שנותר עד שיהיה זמין, בדקות
    var minutesUntilAvailable: Int? {
        guard let until = unavailableUntil else { return nil }
        let left = Int(until.timeIntervalSince(Date()) / 60)
        return left > 0 ? left : nil
    }

    /// הפוך ללא זמין ל־48 שעות מהעכשיו
    func markUnavailableForTwoDays() {
        unavailableUntil = Date().addingTimeInterval(48 * 3600)
    }

    /// בטל כביסה (זמין מיד)
    func markAvailableNow() {
        unavailableUntil = nil
    }
}
