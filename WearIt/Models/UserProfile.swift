import Foundation
import SwiftData

@Model
final class UserProfile {
    var id: UUID = Foundation.UUID()
    var userIdentifier: String?
    var createdAt: Date = Foundation.Date()
    var displayName: String = "Me"
    var avatarEmoji: String?
    var preferredFormality: Int = 3
    var warmthSensitivity: Int = 3
    var rainTolerance: Int = 3
    var email: String?
    var phone: String?
    var garmentIDs: [UUID] = []
    var outfitIDs: [UUID] = []
    var dayPlanIDs: [UUID] = []
    var dailyLookIDs: [UUID] = []

    init(
        id: UUID? = nil,
        userIdentifier: String? = nil,
        createdAt: Date? = nil,
        displayName: String = "Me",
        avatarEmoji: String? = "🧑🏻",
        preferredFormality: Int = 3,
        warmthSensitivity: Int = 3,
        rainTolerance: Int = 3,
        email: String? = nil,
        phone: String? = nil
    ) {
        self.id = id ?? Foundation.UUID()
        self.userIdentifier = userIdentifier
        self.createdAt = createdAt ?? Foundation.Date()
        self.displayName = displayName
        self.avatarEmoji = avatarEmoji
        self.preferredFormality = preferredFormality
        self.warmthSensitivity = warmthSensitivity
        self.rainTolerance = rainTolerance
        self.email = email
        self.phone = phone
    }
}
