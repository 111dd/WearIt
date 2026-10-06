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
    /// Short personal style tagline shown on the profile page.
    var bio: String?
    /// ImageStore-relative path for a photo avatar; falls back to `avatarEmoji`.
    var avatarImagePath: String?
    /// `WorkDressCode` raw value; nil until the user answers the work question.
    var workDressCodeRaw: String?
    /// Usual clothing sizes (`SizeOption` raw values), filled on "My sizes".
    var topSizeRaw: String?
    var bottomSizeRaw: String?
    var shoeSizeRaw: String?
    /// Body measurements in centimeters, all optional.
    var heightCm: Double?
    var chestCm: Double?
    var waistCm: Double?
    var hipsCm: Double?
    var inseamCm: Double?
    var garmentIDs: [UUID] = []
    var outfitIDs: [UUID] = []
    var dayPlanIDs: [UUID] = []
    var dailyLookIDs: [UUID] = []

    var workDressCode: WorkDressCode? {
        get { workDressCodeRaw.flatMap(WorkDressCode.init(rawValue:)) }
        set { workDressCodeRaw = newValue?.rawValue }
    }

    /// The size the user usually wears in a category (tops and outerwear share one).
    func usualSize(for category: Category) -> SizeOption? {
        let raw: String?
        switch category {
        case .top, .outer: raw = topSizeRaw
        case .bottom: raw = bottomSizeRaw
        case .shoes: raw = shoeSizeRaw
        case .accessory: raw = nil
        }
        return raw.flatMap(SizeOption.init(rawValue:))
    }

    func setUsualSize(_ size: SizeOption?, for category: Category) {
        switch category {
        case .top, .outer: topSizeRaw = size?.rawValue
        case .bottom: bottomSizeRaw = size?.rawValue
        case .shoes: shoeSizeRaw = size?.rawValue
        case .accessory: break
        }
    }

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

/// What the user wears to work, so a work day on the calendar is dressed right.
enum WorkDressCode: String, CaseIterable, Identifiable {
    /// A uniform or the same work clothes every day: the app plans around it.
    case uniform
    case business
    case smartCasual
    /// No dress code: work changes nothing.
    case free

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uniform: return String(localized: "work_dress_uniform")
        case .business: return String(localized: "work_dress_business")
        case .smartCasual: return String(localized: "work_dress_smart_casual")
        case .free: return String(localized: "work_dress_free")
        }
    }

    var icon: String {
        switch self {
        case .uniform: return "lanyardcard.fill"
        case .business: return "briefcase.fill"
        case .smartCasual: return "tshirt.fill"
        case .free: return "figure.walk"
        }
    }

    /// Added to the day's formality on a work day.
    var formalityBoost: Int {
        switch self {
        case .uniform, .free: return 0
        case .business: return 2
        case .smartCasual: return 1
        }
    }
}
