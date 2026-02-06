#if DEBUG
import Foundation
import SwiftData

enum DebugOutfitDiagnostics {
    static func sampleLines(context: ModelContext, limit: Int = 8) -> [String] {
        let descriptor = FetchDescriptor<Outfit>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let outfits = (try? context.fetch(descriptor)) ?? []
        let samples = outfits.prefix(max(0, min(limit, outfits.count)))
        return samples.map { outfit in
            let sampleIDs = outfit.itemIDs.prefix(3).map { $0.uuidString }.joined(separator: "|")
            return "OUTFIT_SAMPLE,id=\(outfit.id.uuidString),itemCount=\(outfit.itemIDs.count),sampleItemIDs=[\(sampleIDs)]"
        }
    }

    static func logSampleLinesOnce(context: ModelContext, limit: Int = 8) {
        for line in sampleLines(context: context, limit: limit) {
            print(line)
        }
    }

    static func runDiagnostics(context: ModelContext, limit: Int = 8) {
        let outfits = (try? context.fetch(FetchDescriptor<Outfit>())) ?? []
        let garments = (try? context.fetch(FetchDescriptor<Garment>())) ?? []
        let garmentsByID = Dictionary(uniqueKeysWithValues: garments.map { ($0.id, $0) })

        var legacyOutfitToItems: [UUID: [UUID]] = [:]
        for outfit in outfits {
            if !outfit.legacyItemIDStrings.isEmpty {
                let ids = outfit.legacyItemIDStrings.compactMap { UUID(uuidString: $0) }
                if !ids.isEmpty {
                    legacyOutfitToItems[outfit.id] = ids
                }
            }
        }

        logVerification(
            outfits: outfits,
            garmentsByID: garmentsByID,
            legacyOutfitToItems: legacyOutfitToItems
        )

        for line in sampleLines(context: context, limit: limit) {
            print(line)
        }
    }

    static func logVerification(
        outfits: [Outfit],
        garmentsByID: [UUID: Garment],
        legacyOutfitToItems: [UUID: [UUID]]
    ) {
        for outfit in outfits {
            let itemIDs = outfit.itemIDs
            let uniqueCount = Set(itemIDs).count
            let duplicates = max(0, itemIDs.count - uniqueCount)

            var orphanIDs = 0
            var missingOutfitBackrefCount = 0
            for garmentID in itemIDs {
                if let garment = garmentsByID[garmentID] {
                    if !garment.outfitIDs.contains(outfit.id) {
                        missingOutfitBackrefCount += 1
                    }
                } else {
                    orphanIDs += 1
                }
            }

            let legacyIDs = legacyOutfitToItems[outfit.id] ?? []
            let legacyPresent = !legacyIDs.isEmpty
            let legacyMatch: String
            if legacyPresent {
                let legacySet = Set(legacyIDs)
                let itemSet = Set(itemIDs)
                legacyMatch = (legacySet == itemSet) ? "true" : "false"
            } else {
                legacyMatch = "na"
            }

            print(
                "OUTFIT_VERIFY,id=\(outfit.id.uuidString),legacyPresent=\(legacyPresent ? "true" : "false"),legacyMatch=\(legacyMatch),duplicates=\(duplicates),orphanIDs=\(orphanIDs),missingOutfitBackrefCount=\(missingOutfitBackrefCount)"
            )
        }
    }
}
#endif
