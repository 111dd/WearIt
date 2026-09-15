//
//  GarmentEnrichmentService.swift
//  WearIt
//
//  Fills recommendation-critical garment attributes without user effort:
//  1. Instant offline pass — ItemTypeDefaults per garment type.
//  2. On-device AI refinement — Foundation Models (when available) infers
//     warmth/formality/season/style/occasion/material from the garment facts.
//  Provenance rules: enrichment only ever writes fields the user has not set
//  (tracked via Garment.aiEnrichedFields); a manual edit is final.
//

import Foundation
import SwiftData

@MainActor
enum GarmentEnrichmentService {
    private static let retroPassKey = "wardrobeEnrichmentPassV1Done"
    /// Bound the per-launch AI cost of the retroactive pass.
    private static let retroAILimit = 60

    // MARK: - Instant defaults (offline)

    /// Apply per-type defaults to unset fields and record provenance.
    static func applyDefaults(to garment: Garment, userEditedFields: Set<String> = []) {
        let applied = ItemTypeDefaults.apply(to: garment, userEditedFields: userEditedFields)
        garment.markEnriched(applied)
    }

    // MARK: - AI refinement (on-device, async)

    /// Refine attributes with Foundation Models. Only fields currently owned
    /// by enrichment (in `aiEnrichedFields`) or still empty are written.
    /// Silent no-op when the model is unavailable or generation fails.
    static func enrichWithAI(_ garment: Garment, context: ModelContext) async {
        guard #available(iOS 26.0, *) else { return }
        guard LookExplanationAvailability.isSupported else { return }

        let request = GarmentAttributesRequest(
            category: garment.category.rawValue,
            itemType: garment.itemType?.rawValue,
            colors: garment.safeColorTags.prefix(3).map(\.rawValue),
            pattern: garment.patternTag?.rawValue,
            brand: garment.brand
        )
        guard let result = await LookExplanationService.shared.enrichAttributes(for: request) else {
            return
        }

        apply(result, to: garment)
        try? context.save()
    }

    /// Write validated AI attributes respecting provenance. Internal so unit
    /// tests can exercise the overwrite rules without a model call.
    static func apply(_ result: GarmentAttributesResult, to garment: Garment) {
        let owned = garment.aiEnrichedFields
        var newlyEnriched: [String] = []
        typealias Key = ItemTypeDefaults.FieldKey

        // Writable when enrichment already owns the field, or it is still at
        // the generic default (never user-confirmed).
        func canWrite(_ key: String, isGenericValue: Bool) -> Bool {
            owned.contains(key) || isGenericValue
        }

        if let warmth = result.warmth, canWrite(Key.warmth, isGenericValue: garment.warmth == 3) {
            garment.warmth = warmth
            newlyEnriched.append(Key.warmth)
        }
        if let formality = result.formality, canWrite(Key.formality, isGenericValue: garment.formality == 3) {
            garment.formality = formality
            newlyEnriched.append(Key.formality)
        }
        if let season = result.season, canWrite(Key.season, isGenericValue: garment.seasonSuitability == nil) {
            garment.seasonSuitability = season
            newlyEnriched.append(Key.season)
        }
        if !result.styleTags.isEmpty,
           canWrite(Key.styleTags, isGenericValue: (garment.styleTags ?? []).isEmpty) {
            garment.styleTags = result.styleTags
            newlyEnriched.append(Key.styleTags)
        }
        if !result.occasionTags.isEmpty,
           canWrite(Key.occasionTags, isGenericValue: (garment.occasionTags ?? []).isEmpty) {
            garment.occasionTags = result.occasionTags
            newlyEnriched.append(Key.occasionTags)
        }
        if let material = result.material,
           canWrite(Key.materialTags, isGenericValue: (garment.materialTags ?? []).isEmpty) {
            garment.materialTags = [material]
            newlyEnriched.append(Key.materialTags)
        }

        garment.markEnriched(newlyEnriched)
    }

    // MARK: - Retroactive wardrobe pass (one-time)

    /// Upgrade the existing wardrobe: offline defaults for every garment,
    /// then AI refinement for a bounded batch. Runs once (per flag version).
    static func runRetroactivePassIfNeeded(context: ModelContext) async {
        guard !UserDefaults.standard.bool(forKey: retroPassKey) else { return }

        let garments = (try? context.fetch(FetchDescriptor<Garment>())) ?? []
        guard !garments.isEmpty else {
            // Nothing to migrate; don't burn the flag before a wardrobe exists.
            return
        }

        // Pass 1 — instant defaults. Legacy garments have no edit tracking, so
        // `apply` only touches values still at the generic defaults.
        for garment in garments {
            applyDefaults(to: garment)
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: retroPassKey)

        // Pass 2 — AI refinement, serialized by the service, bounded per launch.
        guard #available(iOS 26.0, *), LookExplanationAvailability.isSupported else { return }
        let candidates = garments
            .filter { !$0.aiEnrichedFields.isEmpty || ($0.styleTags ?? []).isEmpty }
            .prefix(retroAILimit)
        for garment in candidates {
            guard !Task.isCancelled else { return }
            await enrichWithAI(garment, context: context)
        }
    }
}
