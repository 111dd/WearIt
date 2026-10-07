import Foundation
import SwiftData
import UserNotifications
import WidgetKit
import os

/// "Export my data" and "Delete all my data" from Settings.
/// There is no WearIt server: the data lives on the device and in the user's private iCloud,
/// so deleting it there is deleting the account.
@MainActor
enum AccountDataService {
    private static let logger = Logger(subsystem: "com.dordavid.WearIt", category: "AccountData")
    private static let appGroupID = "group.com.dordavid.WearIt"

    // MARK: - Delete

    /// Step 1, synchronous: deletes the wardrobe, plans, wear history, learning and profile
    /// (SwiftData mirrors the deletes to iCloud, so other devices empty too), signs out, and clears
    /// preferences, notifications and photos on this device.
    /// Call it and reset the gate in the same main-actor turn, so no screen renders a deleted model.
    /// Returns the deleted garments' IDs for `deleteCloudPhotos`.
    static func deleteStoredData(context: ModelContext) -> [UUID] {
        let garmentIDs = ((try? context.fetch(FetchDescriptor<Garment>())) ?? []).map(\.id)

        deleteAll(Garment.self, in: context)
        deleteAll(Outfit.self, in: context)
        deleteAll(RecoState.self, in: context)
        deleteAll(RecommendationEvent.self, in: context)
        deleteAll(DismissedOutfit.self, in: context)
        deleteAll(UserProfile.self, in: context)
        deleteAll(TasteProfile.self, in: context)
        deleteAll(DailyLook.self, in: context)
        deleteAll(OutfitFeedback.self, in: context)
        deleteAll(DayPlan.self, in: context)
        deleteAll(NotificationPreferences.self, in: context)
        deleteAll(Brand.self, in: context)
        deleteAll(WearEvent.self, in: context)
        do {
            try context.save()
        } catch {
            logger.error("Delete save failed: \(error.localizedDescription, privacy: .public)")
        }
        AIRecommender.shared.clearStateCache()
        AuthManager.shared.signOut()

        // Preferences go now too, so a later reset can't undo a fresh intro the user already finished.
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        UserDefaults(suiteName: appGroupID)?.removePersistentDomain(forName: appGroupID)

        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()

        ImageStore.deleteAll()
        removeAppSupportFolder("WearItFeaturePrints")

        WidgetCenter.shared.reloadAllTimelines()
        return garmentIDs
    }

    /// Step 2, network: the garment photos stored in iCloud.
    static func deleteCloudPhotos(garmentIDs: [UUID]) async {
        await CloudKitImageSyncService.shared.deleteImages(garmentIDs: garmentIDs)
    }

    private static func deleteAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) {
        // Row by row (not a batch delete) so CloudKit mirroring sees each delete.
        for item in (try? context.fetch(FetchDescriptor<T>())) ?? [] {
            context.delete(item)
        }
    }

    private static func removeAppSupportFolder(_ name: String) {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        try? FileManager.default.removeItem(at: base.appendingPathComponent(name, isDirectory: true))
    }

    // MARK: - Export

    /// Builds "WearIt Export <date>.zip": `wearit-data.json` (profile, wardrobe, plans, wear history)
    /// plus the item photos. Returns the zip's URL in the temporary folder, ready to share.
    static func makeExportArchive(context: ModelContext) throws -> URL {
        let fileManager = FileManager.default
        let stamp = exportStamp()
        let root = fileManager.temporaryDirectory.appendingPathComponent("WearIt Export \(stamp)", isDirectory: true)
        try? fileManager.removeItem(at: root)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        try fileManager.createDirectory(at: photos, withIntermediateDirectories: true)

        let garments = (try? context.fetch(FetchDescriptor<Garment>())) ?? []
        var photoNames: [UUID: [String]] = [:]
        for garment in garments {
            let paths = [garment.imagePath].compactMap { $0 } + (garment.additionalImagePaths ?? [])
            for (index, path) in paths.enumerated() {
                guard let source = ImageStore.fileURL(path: path) else { continue }
                let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension
                let name = "\(garment.id.uuidString)-\(index + 1).\(ext)"
                if (try? fileManager.copyItem(at: source, to: photos.appendingPathComponent(name))) != nil {
                    photoNames[garment.id, default: []].append(name)
                }
            }
        }

        let payload: [String: Any] = [
            "exportedAt": iso(Date()),
            "app": "WearIt",
            "profile": profileJSON(CurrentUser.activeProfile(in: context, createIfNeeded: false)),
            "garments": garments.map { garmentJSON($0, photos: photoNames[$0.id] ?? []) },
            "dayPlans": ((try? context.fetch(FetchDescriptor<DayPlan>(sortBy: [SortDescriptor(\.date)]))) ?? []).map(dayPlanJSON),
            "wearHistory": ((try? context.fetch(FetchDescriptor<WearEvent>(sortBy: [SortDescriptor(\.date)]))) ?? []).map(wearEventJSON)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("wearit-data.json"))

        // Zip the folder with the system's own archiver (no third-party code).
        var coordinatorError: NSError?
        var zipURL: URL?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: root, options: .forUploading, error: &coordinatorError) { tempZip in
            let destination = fileManager.temporaryDirectory.appendingPathComponent("WearIt Export \(stamp).zip")
            try? fileManager.removeItem(at: destination)
            do {
                try fileManager.copyItem(at: tempZip, to: destination)
                zipURL = destination
            } catch {
                copyError = error
            }
        }
        try? fileManager.removeItem(at: root)
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        guard let zipURL else { throw CocoaError(.fileWriteUnknown) }
        return zipURL
    }

    private static func profileJSON(_ profile: UserProfile?) -> [String: Any] {
        guard let profile else { return [:] }
        var json: [String: Any] = [
            "name": profile.displayName,
            "createdAt": iso(profile.createdAt),
            "preferredFormality": profile.preferredFormality,
            "warmthSensitivity": profile.warmthSensitivity,
            "rainTolerance": profile.rainTolerance
        ]
        json["username"] = profile.username
        json["email"] = profile.email
        json["phone"] = profile.phone
        json["bio"] = profile.bio
        json["birthday"] = profile.birthday.map(iso)
        json["workDressCode"] = profile.workDressCodeRaw
        json["topSize"] = profile.topSizeRaw
        json["bottomSize"] = profile.bottomSizeRaw
        json["shoeSize"] = profile.shoeSizeRaw
        json["heightCm"] = profile.heightCm
        json["chestCm"] = profile.chestCm
        json["waistCm"] = profile.waistCm
        json["hipsCm"] = profile.hipsCm
        json["inseamCm"] = profile.inseamCm
        return json
    }

    private static func garmentJSON(_ garment: Garment, photos: [String]) -> [String: Any] {
        var json: [String: Any] = [
            "id": garment.id.uuidString,
            "title": garment.displayTitle,
            "category": garment.category.rawValue,
            "colors": garment.safeColorTags.map(\.rawValue),
            "warmth": garment.warmth,
            "formality": garment.formality,
            "isFavorite": garment.isFavorite,
            "timesWorn": garment.timesWorn,
            "photos": photos
        ]
        json["itemType"] = garment.itemType?.rawValue
        json["brand"] = garment.brand
        json["size"] = garment.sizeOption?.rawValue
        json["materials"] = garment.materialTags?.map(\.rawValue)
        json["styles"] = garment.styleTags?.map(\.rawValue)
        json["lastWorn"] = garment.lastWorn.map(iso)
        json["createdAt"] = garment.createdAt.map(iso)
        json["notes"] = garment.notes
        return json
    }

    private static func dayPlanJSON(_ plan: DayPlan) -> [String: Any] {
        var json: [String: Any] = [
            "date": iso(plan.date),
            "garmentIDs": plan.selectedGarmentIDs.map(\.uuidString)
        ]
        json["slots"] = plan.slotAssignmentIDs?.mapValues(\.uuidString)
        json["eveningSlots"] = plan.eveningSlotAssignmentIDs?.mapValues(\.uuidString)
        json["dayLookStatus"] = plan.dayLookWearStatusRaw
        json["eveningLookStatus"] = plan.eveningLookWearStatusRaw
        json["notes"] = plan.notes
        return json
    }

    private static func wearEventJSON(_ event: WearEvent) -> [String: Any] {
        var json: [String: Any] = [
            "date": iso(event.date),
            "garmentIDs": event.garmentIDs.map(\.uuidString),
            "source": event.sourceRaw
        ]
        json["occasion"] = event.occasionRaw
        json["notes"] = event.notes
        return json
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func exportStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
