import Foundation
import SwiftData

/// Who may see a look post. Only `.onlyMe` exists in practice until the app has a
/// server (plan: `plans/profile-social-direction.md`, phase B); the other cases are
/// here so a post made today keeps its meaning once sharing ships.
enum LookPostVisibility: String, Codable, CaseIterable {
    case onlyMe = "private"
    case closeFriends
    case followers
    case everyone = "public"
}

/// A photo of a look the user actually wore: the profile grid is made of these.
/// Mirrors the future server `posts` table 1:1 so publishing later only fills
/// `remoteID` / `publishedAt`. The wardrobe never leaves the private iCloud: the
/// worn items stay in `garmentIDs` (private) and only `publicTaggedGarmentIDs`,
/// the tags the user turned on, would ever be shared.
@Model
final class LookPost {
    var id: UUID = Foundation.UUID()
    var ownerID: UUID?
    var createdAt: Date = Foundation.Date()
    /// Start of the day the look was worn.
    var lookDate: Date = Foundation.Date()
    var dayPlanID: UUID?
    var isEvening: Bool = false
    /// Local file under `ImageStore` (4:5, metadata stripped).
    var photoPath: String?
    /// The same JPEG, synced through CloudKit as an asset so the grid shows on every device.
    @Attribute(.externalStorage) var photoData: Data?
    var caption: String?
    var visibilityRaw: String = LookPostVisibility.onlyMe.rawValue
    /// Items worn in this look (private, from the day's slots).
    var garmentIDs: [UUID] = []
    /// Items the user chose to show as a tag (category + brand only).
    var publicTaggedGarmentIDs: [UUID] = []
    var isPinned: Bool = false
    var pinnedAt: Date?
    var faceHidden: Bool = false
    var backgroundBlurred: Bool = false
    /// Filled once the post is published to the server (phase B).
    var remoteID: String?
    var publishedAt: Date?

    init(
        lookDate: Date,
        isEvening: Bool = false,
        photoPath: String?,
        photoData: Data?,
        garmentIDs: [UUID] = [],
        ownerID: UUID? = nil,
        dayPlanID: UUID? = nil
    ) {
        self.id = Foundation.UUID()
        self.createdAt = Foundation.Date()
        self.lookDate = Calendar.current.startOfDay(for: lookDate)
        self.isEvening = isEvening
        self.photoPath = photoPath
        self.photoData = photoData
        self.garmentIDs = garmentIDs
        self.ownerID = ownerID
        self.dayPlanID = dayPlanID
    }

    var visibility: LookPostVisibility {
        get { LookPostVisibility(rawValue: visibilityRaw) ?? .onlyMe }
        set { visibilityRaw = newValue.rawValue }
    }
}
