//
//  DataMigrationService.swift
//  WearIt
//
//  One-time data migration for backward compatibility.
//  Runs safely on app launch without blocking.

import Foundation
import SwiftData
import os.log

final class DataMigrationService {
    static let shared = DataMigrationService()
    private init() {}
    
    private let logger = Logger(subsystem: "WearIt", category: "Migration")
    private let idsMigrationKey = "cloudKitIDsMigrationDone"
    private let wearHistoryBackfillKey = "wearHistoryBackfillDone"
    
    /// Run all pending migrations. Safe to call multiple times.
    /// Does not block app launch - runs in background.
    func runMigrationsIfNeeded(context: ModelContext) {
        Task { [weak self] in
            await self?.performMigrations(context: context)
        }
    }

    /// Run migrations and await completion (boot-time use).
    @MainActor
    func runMigrationsAndWait(context: ModelContext) async {
        await performMigrations(context: context)
    }
    
    @MainActor
    private func performMigrations(context: ModelContext) async {
        logger.info("Checking for data migrations...")
        
        do {
            // Fetch all garments
            let descriptor = FetchDescriptor<Garment>()
            let garments = try context.fetch(descriptor)
            
            var migratedCount = 0
            
            for garment in garments {
                if garment.needsMigration {
                    migrateGarment(garment)
                    migratedCount += 1
                }
            }
            
            if migratedCount > 0 {
                try context.save()
                logger.info("Migrated \(migratedCount) garments successfully")
            } else {
                logger.info("No migrations needed")
            }

            // Normalize and merge duplicate brands
            BrandStore.mergeDuplicateBrands(context: context)

            // CloudKit ID backfill (one-time)
            migrateCloudKitIDsIfNeeded(context: context)

            // Wear history backfill (one-time)
            migrateWearHistoryIfNeeded(context: context)
            
        } catch {
            // Log but don't crash - migration failures should not block the app
            logger.error("Migration failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func migrateCloudKitIDsIfNeeded(context: ModelContext) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: idsMigrationKey) {
            return
        }

        #if DEBUG
        logger.debug("Starting CloudKit ID migration...")
        #endif

        do {
            let garments = try context.fetch(FetchDescriptor<Garment>())
            let outfits = try context.fetch(FetchDescriptor<Outfit>())
            let plans = try context.fetch(FetchDescriptor<DayPlan>())
            let looks = try context.fetch(FetchDescriptor<DailyLook>())
            let profiles = try context.fetch(FetchDescriptor<UserProfile>())
            let wearEvents = try context.fetch(FetchDescriptor<WearEvent>())
            let feedbacks = try context.fetch(FetchDescriptor<OutfitFeedback>())

            let singleProfile = profiles.count == 1 ? profiles.first : nil
            if let profile = singleProfile {
                for garment in garments where garment.ownerID == nil {
                    garment.ownerID = profile.id
                }
                for outfit in outfits where outfit.ownerID == nil {
                    outfit.ownerID = profile.id
                }
                for plan in plans where plan.ownerID == nil {
                    plan.ownerID = profile.id
                }
                for look in looks where look.ownerID == nil {
                    look.ownerID = profile.id
                }
            }

            var legacyOutfitToItems: [UUID: [UUID]] = [:]
            var legacyOutfitSourceCount = 0
            for outfit in outfits {
                if !outfit.legacyItemIDStrings.isEmpty {
                    let ids = outfit.legacyItemIDStrings.compactMap { UUID(uuidString: $0) }
                    if !ids.isEmpty {
                        legacyOutfitToItems[outfit.id] = ids
                        legacyOutfitSourceCount += 1
                    }
                }
            }

            var backfilledOutfitItems = 0
            var backfilledProfileLinks = 0
            var backfilledGarmentOutfits = 0
            var backfilledPlanIDs = 0
            var backfilledEvents = 0
            var backfilledFeedback = 0
            var restoredFromLegacy = 0
            var reconstructedFromGarments = 0

            // Garment outfitIDs from legacy strings
            for garment in garments {
                for str in garment.outfitIDStrings {
                    if let id = UUID(uuidString: str) {
                        if !garment.outfitIDs.contains(id) {
                            garment.outfitIDs.append(id)
                            backfilledGarmentOutfits += 1
                        }
                    }
                }
            }

            // Build outfit -> garment map from garment.outfitIDs
            var outfitToItems: [UUID: [UUID]] = [:]
            for garment in garments {
                for outfitID in garment.outfitIDs {
                    var list = outfitToItems[outfitID] ?? []
                    appendUnique(&list, garment.id)
                    outfitToItems[outfitID] = list
                }
            }

            // Backfill outfit.itemIDs
            for outfit in outfits where outfit.itemIDs.isEmpty {
                if let legacyItems = legacyOutfitToItems[outfit.id], !legacyItems.isEmpty {
                    outfit.itemIDs = legacyItems
                    backfilledOutfitItems += 1
                    restoredFromLegacy += 1
                    #if DEBUG
                    print("OUTFIT_RESTORED,id=\(outfit.id.uuidString),items=\(legacyItems.count),source=legacyOutfitItems")
                    #endif
                    continue
                }

                let items = outfitToItems[outfit.id] ?? []
                if !items.isEmpty {
                    outfit.itemIDs = items
                    backfilledOutfitItems += 1
                    reconstructedFromGarments += 1
                    #if DEBUG
                    print("OUTFIT_RECONSTRUCTED,id=\(outfit.id.uuidString),items=\(items.count),source=garmentBackrefs")
                    #endif
                }
            }

            // Ensure garments include outfits that reference them
            let garmentsByID = Dictionary(uniqueKeysWithValues: garments.map { ($0.id, $0) })
            for outfit in outfits {
                for garmentID in outfit.itemIDs {
                    if let garment = garmentsByID[garmentID] {
                        if !garment.outfitIDs.contains(outfit.id) {
                            garment.outfitIDs.append(outfit.id)
                            backfilledGarmentOutfits += 1
                        }
                    }
                }
            }

            #if DEBUG
            DebugOutfitDiagnostics.logVerification(
                outfits: outfits,
                garmentsByID: garmentsByID,
                legacyOutfitToItems: legacyOutfitToItems
            )
            #endif

            // Backfill UserProfile ID arrays by ownerID scan
            for profile in profiles {
                var garmentIDs: [UUID] = []
                var outfitIDs: [UUID] = []
                var dayPlanIDs: [UUID] = []
                var dailyLookIDs: [UUID] = []

                for garment in garments where garment.ownerID == profile.id {
                    appendUnique(&garmentIDs, garment.id)
                }
                for outfit in outfits where outfit.ownerID == profile.id {
                    appendUnique(&outfitIDs, outfit.id)
                }
                for plan in plans where plan.ownerID == profile.id {
                    appendUnique(&dayPlanIDs, plan.id)
                }
                for look in looks where look.ownerID == profile.id {
                    appendUnique(&dailyLookIDs, look.id)
                }

                if profile.garmentIDs != garmentIDs {
                    profile.garmentIDs = garmentIDs
                    backfilledProfileLinks += 1
                }
                if profile.outfitIDs != outfitIDs {
                    profile.outfitIDs = outfitIDs
                    backfilledProfileLinks += 1
                }
                if profile.dayPlanIDs != dayPlanIDs {
                    profile.dayPlanIDs = dayPlanIDs
                    backfilledProfileLinks += 1
                }
                if profile.dailyLookIDs != dailyLookIDs {
                    profile.dailyLookIDs = dailyLookIDs
                    backfilledProfileLinks += 1
                }
            }

            // DayPlan UUID fields from legacy string fields
            for plan in plans {
                if plan.selectedGarmentIDs.isEmpty, !plan.selectedGarmentIDStrings.isEmpty {
                    plan.selectedGarmentIDs = plan.selectedGarmentIDStrings.compactMap { UUID(uuidString: $0) }
                    backfilledPlanIDs += 1
                }
                if plan.lockedGarmentIDs.isEmpty, !plan.lockedGarmentIDStrings.isEmpty {
                    plan.lockedGarmentIDs = plan.lockedGarmentIDStrings.compactMap { UUID(uuidString: $0) }
                    backfilledPlanIDs += 1
                }
                if plan.slotAssignmentIDs == nil, let raw = plan.slotAssignmentRaw {
                    var mapped: [String: UUID] = [:]
                    for (key, value) in raw {
                        if let id = UUID(uuidString: value) {
                            mapped[key] = id
                        }
                    }
                    plan.slotAssignmentIDs = mapped.isEmpty ? nil : mapped
                    backfilledPlanIDs += 1
                }
                if plan.eveningSlotAssignmentIDs == nil, let raw = plan.eveningSlotAssignmentRaw {
                    var mapped: [String: UUID] = [:]
                    for (key, value) in raw {
                        if let id = UUID(uuidString: value) {
                            mapped[key] = id
                        }
                    }
                    plan.eveningSlotAssignmentIDs = mapped.isEmpty ? nil : mapped
                    backfilledPlanIDs += 1
                }
            }

            // WearEvent UUID arrays from legacy strings
            for event in wearEvents where event.garmentIDs.isEmpty && !event.garmentIDStrings.isEmpty {
                event.garmentIDs = event.garmentIDStrings.compactMap { UUID(uuidString: $0) }
                backfilledEvents += 1
            }

            // OutfitFeedback UUID arrays from legacy strings
            for feedback in feedbacks where feedback.garmentIDs.isEmpty && !feedback.garmentIDStrings.isEmpty {
                feedback.garmentIDs = feedback.garmentIDStrings.compactMap { UUID(uuidString: $0) }
                backfilledFeedback += 1
            }

            var queuedUploads = 0
            for garment in garments {
                if let path = garment.imagePath {
                    CloudKitImageSyncService.shared.enqueueUpload(garmentID: garment.id, imagePath: path)
                    queuedUploads += 1
                }
            }

            try context.save()
            defaults.set(true, forKey: idsMigrationKey)

            #if DEBUG
            logger.debug("CloudKit ID migration done. Outfits: \(backfilledOutfitItems), GarmentOutfits: \(backfilledGarmentOutfits), Profiles: \(backfilledProfileLinks), Plans: \(backfilledPlanIDs), Events: \(backfilledEvents), Feedback: \(backfilledFeedback), UploadsQueued: \(queuedUploads), Reconstructed: \(reconstructedFromGarments), LegacyOutfitSources: \(legacyOutfitSourceCount)")
            print("MIGRATION_COUNTS,OutfitsBackfilled=\(backfilledOutfitItems),GarmentOutfitsBackfilled=\(backfilledGarmentOutfits),ProfilesBackfilled=\(backfilledProfileLinks),PlansBackfilled=\(backfilledPlanIDs),EventsBackfilled=\(backfilledEvents),FeedbackBackfilled=\(backfilledFeedback),UploadsQueued=\(queuedUploads),ReconstructedFromGarments=\(reconstructedFromGarments),RestoredFromLegacy=\(restoredFromLegacy),LegacyOutfitSources=\(legacyOutfitSourceCount)")
            DebugOutfitDiagnostics.logSampleLinesOnce(context: context, limit: 8)
            #endif
        } catch {
            logger.error("CloudKit ID migration failed: \(error.localizedDescription)")
        }
    }

    private func appendUnique(_ array: inout [UUID], _ id: UUID) {
        if !array.contains(id) {
            array.append(id)
        }
    }

    @MainActor
    private func migrateWearHistoryIfNeeded(context: ModelContext) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: wearHistoryBackfillKey) {
            return
        }

        do {
            let garments = try context.fetch(FetchDescriptor<Garment>())
            let events = try context.fetch(FetchDescriptor<WearEvent>())
            let existingWearIDs = Set(events.flatMap { $0.garmentIDs })

            var backfillByDate: [Date: [UUID]] = [:]
            for garment in garments {
                guard let last = garment.lastWorn else { continue }
                if existingWearIDs.contains(garment.id) { continue }
                let day = Calendar.current.startOfDay(for: last)
                backfillByDate[day, default: []].append(garment.id)
            }

            var backfilledCount = 0
            for (date, ids) in backfillByDate {
                WearHistoryService.recordWorn(
                    date: date,
                    garmentIDs: ids,
                    source: .migration,
                    context: context,
                    incrementTimesWorn: false,
                    loveScoreDelta: nil
                )
                backfilledCount += ids.count
            }

            defaults.set(true, forKey: wearHistoryBackfillKey)

            #if DEBUG
            logger.debug("Wear history backfill done. BackfilledEvents: \(backfilledCount)")
            #endif
        } catch {
            logger.error("Wear history backfill failed: \(error.localizedDescription)")
        }
    }
    
    private func migrateGarment(_ garment: Garment) {
        // Run the model's built-in migration
        garment.migrateIfNeeded()
        
        // Additional migration logic if needed
        
        // Ensure colorTags is not nil (even if empty)
        if garment.colorTags == nil {
            garment.colorTags = []
        }
        
        // If we have legacy colors but no colorTags, convert them
        if let legacyColors = garment.legacyColors, !legacyColors.isEmpty {
            if garment.colorTags?.isEmpty ?? true {
                garment.colorTags = legacyColors.compactMap { colorString in
                    ColorTag.allCases.first { 
                        $0.title.lowercased() == colorString.lowercased() ||
                        $0.rawValue.lowercased() == colorString.lowercased()
                    }
                }
            }
        }
        
        // If we still have no colors, try to infer from legacy name
        if garment.colorTags?.isEmpty ?? true {
            if let legacyName = garment.legacyName {
                let inferredColors = inferColorsFromName(legacyName)
                if !inferredColors.isEmpty {
                    garment.colorTags = inferredColors
                }
            }
        }

        if garment.thumbnailPath == nil, let imagePath = garment.imagePath {
            garment.thumbnailPath = ImageStore.generateAndSaveThumbnail(
                for: imagePath,
                maxPixelSize: ImageStore.thumbnailMaxPixelSize
            )
        }
        
        #if DEBUG
        logger.debug("Migrated garment: \(garment.displayTitle, privacy: .private)")
        #endif
    }
    
    /// Try to infer color tags from a garment name
    private func inferColorsFromName(_ name: String) -> [ColorTag] {
        let lowercased = name.lowercased()
        var found: [ColorTag] = []
        
        for color in ColorTag.allCases {
            if lowercased.contains(color.title.lowercased()) {
                found.append(color)
            }
        }
        
        return found
    }
}

// MARK: - App Entry Point Integration

extension DataMigrationService {
    /// Call this from your App's init or onAppear
    static func runOnLaunch(context: ModelContext) {
        shared.runMigrationsIfNeeded(context: context)
    }
}
