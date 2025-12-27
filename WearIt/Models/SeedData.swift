//
//  SeedData.swift
//  WearIt
//
//  Created by Dor David on 05/09/2025.
//

import SwiftData

struct SeedData {
    static func load(context: ModelContext) {
        let fetch = FetchDescriptor<Garment>()
        if let count = try? context.fetch(fetch).count, count > 0 {
            return // כבר נטען דאטה בעבר
        }

        let items: [Garment] = [

            // 👕 Tops
            Garment(name: "T-Shirt White", brand: "Nike", category: .top,
                    colors: ["white"], warmth: 1, formality: 1, loveScore: 70),
            Garment(name: "T-Shirt Black", brand: "H&M", category: .top,
                    colors: ["black"], warmth: 1, formality: 1, loveScore: 60),
            Garment(name: "Shirt Blue", brand: "Zara", category: .top,
                    colors: ["blue"], warmth: 2, formality: 4, loveScore: 65),
            Garment(name: "Shirt White", brand: "Massimo Dutti", category: .top,
                    colors: ["white"], warmth: 2, formality: 5, loveScore: 75),
            Garment(name: "Sweater Gray", brand: "Uniqlo", category: .top,
                    colors: ["gray"], warmth: 3, formality: 3, loveScore: 55),
            Garment(name: "Hoodie Red", brand: "Champion", category: .top,
                    colors: ["red"], warmth: 3, formality: 1, loveScore: 85),

            // 👖 Bottoms
            Garment(name: "Jeans Blue", brand: "Levi's", category: .bottom,
                    colors: ["blue"], warmth: 2, formality: 2, loveScore: 60),
            Garment(name: "Chinos Beige", brand: "Gap", category: .bottom,
                    colors: ["beige"], warmth: 2, formality: 3, loveScore: 50),
            Garment(name: "Suit Pants Black", brand: "Hugo Boss", category: .bottom,
                    colors: ["black"], warmth: 3, formality: 5, loveScore: 70),
            Garment(name: "Shorts Khaki", brand: "Adidas", category: .bottom,
                    colors: ["khaki"], warmth: 1, formality: 1, loveScore: 80),

            // 👟 Shoes
            Garment(name: "Sneakers White", brand: "Adidas", category: .shoes,
                    colors: ["white"], warmth: 1, formality: 1, loveScore: 90),
            Garment(name: "Sneakers Black", brand: "Nike", category: .shoes,
                    colors: ["black"], warmth: 1, formality: 1, loveScore: 75),
            Garment(name: "Formal Shoes Brown", brand: "Clarks", category: .shoes,
                    colors: ["brown"], warmth: 1, formality: 5, loveScore: 65),
            Garment(name: "Boots Leather", brand: "Timberland", category: .shoes,
                    colors: ["brown"], warmth: 4, formality: 3, loveScore: 70),
            Garment(name: "Sandals", brand: "Birkenstock", category: .shoes,
                    colors: ["tan"], warmth: 1, formality: 1, loveScore: 50),

            // 🧥 Outerwear
            Garment(name: "Suit Jacket", brand: "Hugo Boss", category: .outer,
                    colors: ["black"], warmth: 3, formality: 5, loveScore: 55),
            Garment(name: "Winter Coat", brand: "North Face", category: .outer,
                    colors: ["navy"], warmth: 5, formality: 3, loveScore: 65),
            Garment(name: "Leather Jacket", brand: "AllSaints", category: .outer,
                    colors: ["black"], warmth: 4, formality: 4, loveScore: 70),
            Garment(name: "Light Jacket", brand: "Columbia", category: .outer,
                    colors: ["gray"], warmth: 2, formality: 2, loveScore: 60),

            // 🎒 Accessories
            Garment(name: "Watch Silver", brand: "Seiko", category: .accessory,
                    colors: ["silver"], warmth: 0, formality: 5, loveScore: 85),
            Garment(name: "Baseball Cap", brand: "New Era", category: .accessory,
                    colors: ["blue"], warmth: 0, formality: 1, loveScore: 75),
            Garment(name: "Scarf Wool", brand: "Uniqlo", category: .accessory,
                    colors: ["gray"], warmth: 2, formality: 3, loveScore: 65),
            Garment(name: "Belt Black", brand: "Zara", category: .accessory,
                    colors: ["black"], warmth: 0, formality: 4, loveScore: 55)
        ]

        items.forEach { context.insert($0) }
        try? context.save()
        print("🌱 Seeding \(items.count) garments")
    }
    
}
