import Foundation
import SwiftData
import UIKit

/// Creates, deletes and repairs `LookPost`s. The photo lives twice: a local file for
/// fast display and `photoData` for CloudKit, so a post made on the iPhone shows on the iPad.
@MainActor
enum LookPostStore {
    // MARK: - Create / delete

    /// Saves an already processed photo (see `LookPhotoProcessor`) as a private post.
    /// When `garmentIDs` is nil the worn items are read from that day's plan.
    @discardableResult
    static func create(
        jpeg: Data,
        lookDate: Date,
        isEvening: Bool,
        garmentIDs: [UUID]? = nil,
        caption: String? = nil,
        options: LookPhotoProcessor.Options = LookPhotoProcessor.Options(),
        context: ModelContext
    ) throws -> LookPost {
        let path = try ImageStore.save(data: jpeg, preferredExt: "jpg")
        let plan = existingPlan(on: lookDate, context: context)
        let worn = garmentIDs ?? plan.map { wornGarmentIDs(in: $0, isEvening: isEvening) } ?? []
        let post = LookPost(
            lookDate: lookDate,
            isEvening: isEvening,
            photoPath: path,
            photoData: jpeg,
            garmentIDs: worn,
            ownerID: CurrentUser.activeProfile(in: context, createIfNeeded: false)?.id,
            dayPlanID: plan?.id
        )
        let trimmed = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        post.caption = trimmed.isEmpty ? nil : trimmed
        post.faceHidden = options.hideFace
        post.backgroundBlurred = options.blurBackground
        context.insert(post)
        try? context.save()
        return post
    }

    static func delete(_ post: LookPost, context: ModelContext) {
        if let path = post.photoPath { ImageStore.delete(path: path) }
        context.delete(post)
        try? context.save()
    }

    static func setPinned(_ pinned: Bool, for post: LookPost, context: ModelContext) {
        post.isPinned = pinned
        post.pinnedAt = pinned ? Date() : nil
        try? context.save()
    }

    /// Pinned first (newest pin first), then newest look first.
    static func gridOrder(_ posts: [LookPost]) -> [LookPost] {
        posts.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            if a.isPinned { return (a.pinnedAt ?? .distantPast) > (b.pinnedAt ?? .distantPast) }
            if a.lookDate != b.lookDate { return a.lookDate > b.lookDate }
            return a.createdAt > b.createdAt
        }
    }

    // MARK: - Local files

    /// The post's photo on disk, written from the synced `photoData` when this device doesn't have it yet.
    static func localPhotoPath(for post: LookPost) -> String? {
        if let path = post.photoPath, ImageStore.fileExists(path: path) { return path }
        guard let data = post.photoData else { return nil }
        if let path = post.photoPath {
            return ImageStore.write(data: data, toRelativePath: path) ? path : nil
        }
        guard let path = try? ImageStore.save(data: data, preferredExt: "jpg") else { return nil }
        post.photoPath = path
        return path
    }

    // MARK: - Legacy calendar photos

    /// Calendar day photos used to be `DailyLook.photoPaths` (local files only, never synced).
    /// Each one this device still has becomes a private post; the file is kept as is.
    static func importLegacyDayPhotos(context: ModelContext) {
        let looks = (try? context.fetch(FetchDescriptor<DailyLook>())) ?? []
        var changed = false
        for look in looks where !look.photoPaths.isEmpty {
            var remaining: [String] = []
            for path in look.photoPaths {
                guard let data = ImageStore.loadData(path: path) else {
                    remaining.append(path)
                    continue
                }
                let plan = existingPlan(on: look.date, context: context)
                let post = LookPost(
                    lookDate: look.date,
                    photoPath: path,
                    photoData: data,
                    garmentIDs: plan.map { wornGarmentIDs(in: $0, isEvening: false) } ?? [],
                    ownerID: look.ownerID,
                    dayPlanID: plan?.id
                )
                context.insert(post)
                changed = true
            }
            look.photoPaths = remaining
        }
        if changed { try? context.save() }
    }

    // MARK: - "Snap the look" prompt

    private static let dismissedPromptsKey = "lookPost.dismissedPrompts"

    static func isPromptDismissed(on date: Date, isEvening: Bool) -> Bool {
        let keys = UserDefaults.standard.stringArray(forKey: dismissedPromptsKey) ?? []
        return keys.contains(promptKey(date, isEvening))
    }

    static func dismissPrompt(on date: Date, isEvening: Bool) {
        var keys = UserDefaults.standard.stringArray(forKey: dismissedPromptsKey) ?? []
        keys.append(promptKey(date, isEvening))
        UserDefaults.standard.set(Array(keys.suffix(30)), forKey: dismissedPromptsKey)
    }

    private static func promptKey(_ date: Date, _ isEvening: Bool) -> String {
        let day = Calendar.current.startOfDay(for: date).timeIntervalSince1970
        return "\(Int(day))-\(isEvening ? "evening" : "day")"
    }

    // MARK: - Helpers

    private static func existingPlan(on date: Date, context: ModelContext) -> DayPlan? {
        let day = Calendar.current.startOfDay(for: date)
        var descriptor = FetchDescriptor<DayPlan>(predicate: #Predicate { $0.date == day })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func wornGarmentIDs(in plan: DayPlan, isEvening: Bool) -> [UUID] {
        let slots = isEvening ? plan.eveningSlotAssignments : plan.slotAssignments
        return OutfitSlot.allCases.compactMap { slots[$0] }
    }
}
