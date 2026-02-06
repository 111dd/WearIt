//
//  SeedData.swift
//  WearIt
//
//  Sample data for development and first launch.
//  Uses the current structured Garment model.

import SwiftData

struct SeedData {
    static func load(context: ModelContext) {
        let fetch = FetchDescriptor<Garment>()
        if let count = try? context.fetch(fetch).count, count > 0 {
            return // Already seeded
        }

        let items: [Garment] = [

            // 👕 Tops
            makeGarment(
                category: .top, itemType: .tshirt, brand: "Nike",
                colors: [.white], warmth: 1, formality: 1, loveScore: 70
            ),
            makeGarment(
                category: .top, itemType: .tshirt, brand: "H&M",
                colors: [.black], warmth: 1, formality: 1, loveScore: 60
            ),
            makeGarment(
                category: .top, itemType: .shirt, brand: "Zara",
                colors: [.blue], warmth: 2, formality: 4, loveScore: 65
            ),
            makeGarment(
                category: .top, itemType: .shirt, brand: "Massimo Dutti",
                colors: [.white], warmth: 2, formality: 5, loveScore: 75
            ),
            makeGarment(
                category: .top, itemType: .sweater, brand: "Uniqlo",
                colors: [.gray], warmth: 3, formality: 3, loveScore: 55
            ),
            makeGarment(
                category: .top, itemType: .hoodie, brand: "Champion",
                colors: [.red], warmth: 3, formality: 1, loveScore: 85,
                season: .transitional
            ),

            // 👖 Bottoms
            makeGarment(
                category: .bottom, itemType: .jeans, brand: "Levi's",
                colors: [.denim], warmth: 2, formality: 2, loveScore: 60
            ),
            makeGarment(
                category: .bottom, itemType: .chinos, brand: "Gap",
                colors: [.beige], warmth: 2, formality: 3, loveScore: 50
            ),
            makeGarment(
                category: .bottom, itemType: .trousers, brand: "Hugo Boss",
                colors: [.black], warmth: 3, formality: 5, loveScore: 70
            ),
            makeGarment(
                category: .bottom, itemType: .shorts, brand: "Adidas",
                colors: [.beige], warmth: 1, formality: 1, loveScore: 80,
                season: .summer
            ),

            // 👟 Shoes
            makeGarment(
                category: .shoes, itemType: .sneakers, brand: "Adidas",
                colors: [.white], warmth: 1, formality: 1, loveScore: 90
            ),
            makeGarment(
                category: .shoes, itemType: .sneakers, brand: "Nike",
                colors: [.black], warmth: 1, formality: 1, loveScore: 75
            ),
            makeGarment(
                category: .shoes, itemType: .oxfords, brand: "Clarks",
                colors: [.brown], warmth: 1, formality: 5, loveScore: 65
            ),
            makeGarment(
                category: .shoes, itemType: .boots, brand: "Timberland",
                colors: [.brown], warmth: 4, formality: 3, loveScore: 70,
                season: .winter
            ),
            makeGarment(
                category: .shoes, itemType: .sandals, brand: "Birkenstock",
                colors: [.beige], warmth: 1, formality: 1, loveScore: 50,
                season: .summer
            ),

            // 🧥 Outerwear
            makeGarment(
                category: .outer, itemType: .blazer, brand: "Hugo Boss",
                colors: [.black], warmth: 3, formality: 5, loveScore: 55
            ),
            makeGarment(
                category: .outer, itemType: .coat, brand: "North Face",
                colors: [.navy], warmth: 5, formality: 3, loveScore: 65,
                season: .winter
            ),
            makeGarment(
                category: .outer, itemType: .jacket, brand: "AllSaints",
                colors: [.black], warmth: 4, formality: 4, loveScore: 70
            ),
            makeGarment(
                category: .outer, itemType: .windbreaker, brand: "Columbia",
                colors: [.gray], warmth: 2, formality: 2, loveScore: 60,
                season: .transitional
            ),

            // 🎒 Accessories
            makeGarment(
                category: .accessory, itemType: .watch, brand: "Seiko",
                colors: [.gray], warmth: 1, formality: 5, loveScore: 85
            ),
            makeGarment(
                category: .accessory, itemType: .cap, brand: "New Era",
                colors: [.blue], warmth: 1, formality: 1, loveScore: 75
            ),
            makeGarment(
                category: .accessory, itemType: .scarf, brand: "Uniqlo",
                colors: [.gray], warmth: 3, formality: 3, loveScore: 65,
                season: .winter
            ),
            makeGarment(
                category: .accessory, itemType: .belt, brand: "Zara",
                colors: [.black], warmth: 1, formality: 4, loveScore: 55
            )
        ]

        items.forEach { context.insert($0) }
        try? context.save()
        print("🌱 Seeded \(items.count) garments")
    }
    
    // MARK: - Helper
    
    /// Create a garment using the current structured model
    private static func makeGarment(
        category: Category,
        itemType: ItemType,
        brand: String,
        colors: [ColorTag],
        warmth: Int,
        formality: Int,
        loveScore: Int,
        season: SeasonSuitability? = nil
    ) -> Garment {
        Garment(
            category: category,
            itemType: itemType,
            brand: brand,
            colorTags: colors,
            seasonSuitability: season,
            warmth: max(1, min(5, warmth)),  // Clamp to 1-5
            formality: max(1, min(5, formality)),
            loveScore: max(0, min(100, loveScore)),
            migrationVersion: 2
        )
    }
}
