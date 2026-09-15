//
//  ItemTypeDefaults.swift
//  WearIt
//
//  Sensible per-ItemType defaults for recommendation-critical attributes.
//  Applied at save (and during retroactive enrichment) to any field the user
//  did not explicitly set — so a t-shirt never ships with the generic
//  "warmth 3" that used to poison temperature matching. Works fully offline;
//  Foundation Models enrichment refines these values when available.
//

import Foundation

struct ItemTypeDefaults {
    let warmth: Int          // 1...5
    let formality: Int       // 1...5
    let season: SeasonSuitability
    let layerRole: LayerRole?
    let weatherTags: [WeatherSuitability]
    let styleTags: [StyleTag]

    static func defaults(for type: ItemType) -> ItemTypeDefaults? {
        table[type]
    }

    private static let table: [ItemType: ItemTypeDefaults] = [
        // MARK: Tops
        .tshirt: .init(warmth: 1, formality: 2, season: .summer, layerRole: .base, weatherTags: [.breathable], styleTags: [.casual]),
        .shirt: .init(warmth: 2, formality: 4, season: .allSeason, layerRole: .base, weatherTags: [], styleTags: [.smart_casual]),
        .polo: .init(warmth: 1, formality: 3, season: .summer, layerRole: .base, weatherTags: [.breathable], styleTags: [.smart_casual]),
        .blouse: .init(warmth: 2, formality: 4, season: .allSeason, layerRole: .base, weatherTags: [], styleTags: [.smart_casual]),
        .tank: .init(warmth: 1, formality: 1, season: .summer, layerRole: .base, weatherTags: [.breathable], styleTags: [.casual, .sporty]),
        .sweater: .init(warmth: 4, formality: 3, season: .winter, layerRole: .mid, weatherTags: [.insulated], styleTags: [.casual]),
        .hoodie: .init(warmth: 3, formality: 1, season: .transitional, layerRole: .mid, weatherTags: [], styleTags: [.casual, .streetwear]),
        .cardigan: .init(warmth: 3, formality: 3, season: .transitional, layerRole: .mid, weatherTags: [], styleTags: [.smart_casual]),
        .vest: .init(warmth: 2, formality: 3, season: .transitional, layerRole: .mid, weatherTags: [], styleTags: [.smart_casual]),

        // MARK: Bottoms
        .jeans: .init(warmth: 3, formality: 2, season: .allSeason, layerRole: .base, weatherTags: [], styleTags: [.casual]),
        .chinos: .init(warmth: 2, formality: 3, season: .allSeason, layerRole: .base, weatherTags: [], styleTags: [.smart_casual]),
        .trousers: .init(warmth: 2, formality: 4, season: .allSeason, layerRole: .base, weatherTags: [], styleTags: [.business]),
        .shorts: .init(warmth: 1, formality: 1, season: .summer, layerRole: .base, weatherTags: [.breathable], styleTags: [.casual]),
        .skirt: .init(warmth: 1, formality: 3, season: .summer, layerRole: .base, weatherTags: [], styleTags: [.casual]),
        .leggings: .init(warmth: 2, formality: 1, season: .allSeason, layerRole: .base, weatherTags: [], styleTags: [.sporty]),
        .joggers: .init(warmth: 2, formality: 1, season: .allSeason, layerRole: .base, weatherTags: [], styleTags: [.sporty, .streetwear]),
        .sweatpants: .init(warmth: 3, formality: 1, season: .winter, layerRole: .base, weatherTags: [], styleTags: [.casual, .sporty]),

        // MARK: Shoes
        .sneakers: .init(warmth: 2, formality: 2, season: .allSeason, layerRole: nil, weatherTags: [], styleTags: [.casual, .sporty]),
        .boots: .init(warmth: 4, formality: 3, season: .winter, layerRole: nil, weatherTags: [.rainFriendly], styleTags: [.casual]),
        .loafers: .init(warmth: 2, formality: 4, season: .allSeason, layerRole: nil, weatherTags: [], styleTags: [.smart_casual]),
        .sandals: .init(warmth: 1, formality: 1, season: .summer, layerRole: nil, weatherTags: [.breathable], styleTags: [.casual]),
        .heels: .init(warmth: 1, formality: 4, season: .allSeason, layerRole: nil, weatherTags: [], styleTags: [.formal]),
        .flats: .init(warmth: 1, formality: 3, season: .allSeason, layerRole: nil, weatherTags: [], styleTags: [.smart_casual]),
        .oxfords: .init(warmth: 2, formality: 5, season: .allSeason, layerRole: nil, weatherTags: [], styleTags: [.formal, .business]),
        .slippers: .init(warmth: 2, formality: 1, season: .allSeason, layerRole: nil, weatherTags: [], styleTags: [.casual]),

        // MARK: Outerwear
        .jacket: .init(warmth: 3, formality: 3, season: .transitional, layerRole: .outer, weatherTags: [.windproof], styleTags: [.casual]),
        .coat: .init(warmth: 4, formality: 4, season: .winter, layerRole: .outer, weatherTags: [.windproof, .insulated], styleTags: [.smart_casual]),
        .blazer: .init(warmth: 2, formality: 4, season: .allSeason, layerRole: .outer, weatherTags: [], styleTags: [.business]),
        .parka: .init(warmth: 5, formality: 2, season: .winter, layerRole: .outer, weatherTags: [.insulated, .windproof], styleTags: [.casual]),
        .raincoat: .init(warmth: 3, formality: 2, season: .transitional, layerRole: .outer, weatherTags: [.waterproof, .rainFriendly], styleTags: [.casual]),
        .windbreaker: .init(warmth: 2, formality: 1, season: .transitional, layerRole: .outer, weatherTags: [.windproof, .rainFriendly], styleTags: [.sporty]),
        .puffer: .init(warmth: 5, formality: 2, season: .winter, layerRole: .outer, weatherTags: [.insulated], styleTags: [.casual, .streetwear]),
        .denim_jacket: .init(warmth: 3, formality: 2, season: .transitional, layerRole: .outer, weatherTags: [], styleTags: [.casual, .vintage]),

        // MARK: Accessories
        .hat: .init(warmth: 3, formality: 2, season: .winter, layerRole: nil, weatherTags: [.insulated], styleTags: []),
        .cap: .init(warmth: 1, formality: 1, season: .summer, layerRole: nil, weatherTags: [], styleTags: [.casual, .sporty]),
        .scarf: .init(warmth: 4, formality: 3, season: .winter, layerRole: nil, weatherTags: [.insulated], styleTags: []),
        .belt: .init(warmth: 1, formality: 3, season: .allSeason, layerRole: nil, weatherTags: [], styleTags: []),
        .watch: .init(warmth: 1, formality: 3, season: .allSeason, layerRole: nil, weatherTags: [], styleTags: []),
        .bag: .init(warmth: 1, formality: 3, season: .allSeason, layerRole: nil, weatherTags: [], styleTags: []),
        .sunglasses: .init(warmth: 1, formality: 2, season: .summer, layerRole: nil, weatherTags: [], styleTags: []),
        .jewelry: .init(warmth: 1, formality: 3, season: .allSeason, layerRole: nil, weatherTags: [], styleTags: []),
        .tie: .init(warmth: 1, formality: 5, season: .allSeason, layerRole: nil, weatherTags: [], styleTags: [.formal, .business])
        // .other intentionally has no entry — nothing sensible to assume.
    ]
}

// MARK: - Application to a Garment

extension ItemTypeDefaults {
    /// Field keys used for AI/defaults provenance tracking on `Garment`.
    enum FieldKey {
        static let warmth = "warmth"
        static let formality = "formality"
        static let season = "season"
        static let layerRole = "layerRole"
        static let weatherTags = "weatherTags"
        static let styleTags = "styleTags"
        static let materialTags = "materialTags"
        static let occasionTags = "occasionTags"
        static let tempRange = "tempRange"
    }

    /// Fills recommendation-critical fields the user has not explicitly set.
    /// A field counts as "unset" when it still holds the generic model default
    /// AND is not recorded as user-edited. Returns the keys that were applied
    /// so callers can record provenance.
    @discardableResult
    static func apply(to garment: Garment, userEditedFields: Set<String> = []) -> [String] {
        guard let type = garment.itemType, let defaults = defaults(for: type) else { return [] }
        var applied: [String] = []

        if garment.warmth == 3, !userEditedFields.contains(FieldKey.warmth) {
            garment.warmth = defaults.warmth
            applied.append(FieldKey.warmth)
        }
        if garment.formality == 3, !userEditedFields.contains(FieldKey.formality) {
            garment.formality = defaults.formality
            applied.append(FieldKey.formality)
        }
        if garment.seasonSuitability == nil, !userEditedFields.contains(FieldKey.season) {
            garment.seasonSuitability = defaults.season
            applied.append(FieldKey.season)
        }
        if garment.layerRole == nil, let role = defaults.layerRole,
           !userEditedFields.contains(FieldKey.layerRole) {
            garment.layerRole = role
            applied.append(FieldKey.layerRole)
        }
        if (garment.weatherTags ?? []).isEmpty, !defaults.weatherTags.isEmpty,
           !userEditedFields.contains(FieldKey.weatherTags) {
            garment.weatherTags = defaults.weatherTags
            applied.append(FieldKey.weatherTags)
        }
        if (garment.styleTags ?? []).isEmpty, !defaults.styleTags.isEmpty,
           !userEditedFields.contains(FieldKey.styleTags) {
            garment.styleTags = defaults.styleTags
            applied.append(FieldKey.styleTags)
        }
        return applied
    }
}
