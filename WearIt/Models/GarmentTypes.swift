//
//  GarmentTypes.swift
//  WearIt
//
//  Structured enums for garment classification.
//  These enable consistent filtering, recommendations, and AI-ready tagging.

import Foundation
import SwiftUI

// MARK: - Category (Top-level)

enum Category: String, Codable, CaseIterable, Identifiable {
    case top
    case bottom
    case shoes
    case outer
    case accessory
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .top: return String(localized: "category_tops")
        case .bottom: return String(localized: "category_bottoms")
        case .shoes: return String(localized: "category_footwear")
        case .outer: return String(localized: "category_outerwear")
        case .accessory: return String(localized: "category_accessories")
        }
    }
    
    var icon: String {
        switch self {
        case .top: return "tshirt"
        case .bottom: return "figure.walk"
        case .shoes: return "shoe"
        case .outer: return "cloud.snow"
        case .accessory: return "bag"
        }
    }
    
    /// Item types available for this category
    var itemTypes: [ItemType] {
        switch self {
        case .top:
            return [.tshirt, .shirt, .polo, .blouse, .tank, .sweater, .hoodie, .cardigan, .vest]
        case .bottom:
            return [.jeans, .chinos, .trousers, .shorts, .skirt, .leggings, .joggers, .sweatpants]
        case .shoes:
            return [.sneakers, .boots, .loafers, .sandals, .heels, .flats, .oxfords, .slippers]
        case .outer:
            return [.jacket, .coat, .blazer, .parka, .raincoat, .windbreaker, .puffer, .denim_jacket]
        case .accessory:
            return [.hat, .cap, .scarf, .belt, .watch, .bag, .sunglasses, .jewelry, .tie]
        }
    }
}

// MARK: - Item Type (Specific type within category)

enum ItemType: String, Codable, CaseIterable, Identifiable {
    // Tops
    case tshirt, shirt, polo, blouse, tank, sweater, hoodie, cardigan, vest
    // Bottoms
    case jeans, chinos, trousers, shorts, skirt, leggings, joggers, sweatpants
    // Shoes
    case sneakers, boots, loafers, sandals, heels, flats, oxfords, slippers
    // Outerwear
    case jacket, coat, blazer, parka, raincoat, windbreaker, puffer, denim_jacket
    // Accessories
    case hat, cap, scarf, belt, watch, bag, sunglasses, jewelry, tie
    // Generic fallback
    case other
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .tshirt: return String(localized: "item_type_tshirt")
        case .shirt: return String(localized: "item_type_shirt")
        case .polo: return String(localized: "item_type_polo")
        case .blouse: return String(localized: "item_type_blouse")
        case .tank: return String(localized: "item_type_tank")
        case .sweater: return String(localized: "item_type_sweater")
        case .hoodie: return String(localized: "item_type_hoodie")
        case .cardigan: return String(localized: "item_type_cardigan")
        case .vest: return String(localized: "item_type_vest")
        case .jeans: return String(localized: "item_type_jeans")
        case .chinos: return String(localized: "item_type_chinos")
        case .trousers: return String(localized: "item_type_trousers")
        case .shorts: return String(localized: "item_type_shorts")
        case .skirt: return String(localized: "item_type_skirt")
        case .leggings: return String(localized: "item_type_leggings")
        case .joggers: return String(localized: "item_type_joggers")
        case .sweatpants: return String(localized: "item_type_sweatpants")
        case .sneakers: return String(localized: "item_type_sneakers")
        case .boots: return String(localized: "item_type_boots")
        case .loafers: return String(localized: "item_type_loafers")
        case .sandals: return String(localized: "item_type_sandals")
        case .heels: return String(localized: "item_type_heels")
        case .flats: return String(localized: "item_type_flats")
        case .oxfords: return String(localized: "item_type_oxfords")
        case .slippers: return String(localized: "item_type_slippers")
        case .jacket: return String(localized: "item_type_jacket")
        case .coat: return String(localized: "item_type_coat")
        case .blazer: return String(localized: "item_type_blazer")
        case .parka: return String(localized: "item_type_parka")
        case .raincoat: return String(localized: "item_type_raincoat")
        case .windbreaker: return String(localized: "item_type_windbreaker")
        case .puffer: return String(localized: "item_type_puffer")
        case .denim_jacket: return String(localized: "item_type_denim_jacket")
        case .hat: return String(localized: "item_type_hat")
        case .cap: return String(localized: "item_type_cap")
        case .scarf: return String(localized: "item_type_scarf")
        case .belt: return String(localized: "item_type_belt")
        case .watch: return String(localized: "item_type_watch")
        case .bag: return String(localized: "item_type_bag")
        case .sunglasses: return String(localized: "item_type_sunglasses")
        case .jewelry: return String(localized: "item_type_jewelry")
        case .tie: return String(localized: "item_type_tie")
        case .other: return String(localized: "item_type_other")
        }
    }
}

// MARK: - Color Tag

enum ColorTag: String, Codable, CaseIterable, Identifiable {
    case black, white, gray, navy, blue, lightBlue
    case red, pink, orange, yellow, green, olive
    case brown, beige, cream, burgundy, purple
    case multicolor, denim
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .black: return String(localized: "color_black")
        case .white: return String(localized: "color_white")
        case .gray: return String(localized: "color_gray")
        case .navy: return String(localized: "color_navy")
        case .blue: return String(localized: "color_blue")
        case .lightBlue: return String(localized: "color_light_blue")
        case .red: return String(localized: "color_red")
        case .pink: return String(localized: "color_pink")
        case .orange: return String(localized: "color_orange")
        case .yellow: return String(localized: "color_yellow")
        case .green: return String(localized: "color_green")
        case .olive: return String(localized: "color_olive")
        case .brown: return String(localized: "color_brown")
        case .beige: return String(localized: "color_beige")
        case .cream: return String(localized: "color_cream")
        case .burgundy: return String(localized: "color_burgundy")
        case .purple: return String(localized: "color_purple")
        case .multicolor: return String(localized: "color_multicolor")
        case .denim: return String(localized: "color_denim")
        }
    }
    
    var color: Color {
        switch self {
        case .black: return .black
        case .white: return .white
        case .gray: return .gray
        case .navy: return Color(red: 0, green: 0, blue: 0.5)
        case .blue: return .blue
        case .lightBlue: return Color(red: 0.68, green: 0.85, blue: 0.9)
        case .red: return .red
        case .pink: return .pink
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .olive: return Color(red: 0.5, green: 0.5, blue: 0)
        case .brown: return .brown
        case .beige: return Color(red: 0.96, green: 0.96, blue: 0.86)
        case .cream: return Color(red: 1, green: 0.99, blue: 0.82)
        case .burgundy: return Color(red: 0.5, green: 0, blue: 0.13)
        case .purple: return .purple
        case .multicolor: return .clear
        case .denim: return Color(red: 0.08, green: 0.38, blue: 0.74)
        }
    }
}

// MARK: - Season Suitability

enum SeasonSuitability: String, Codable, CaseIterable, Identifiable {
    case summer
    case transitional
    case winter
    case allSeason
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .summer: return "Summer"
        case .transitional: return "Spring/Fall"
        case .winter: return "Winter"
        case .allSeason: return "All Season"
        }
    }
    
    var icon: String {
        switch self {
        case .summer: return "sun.max.fill"
        case .transitional: return "leaf.fill"
        case .winter: return "snowflake"
        case .allSeason: return "calendar"
        }
    }
    
    /// Default temperature range for this season
    var defaultTempRange: (min: Double, max: Double) {
        switch self {
        case .summer: return (22, 40)
        case .transitional: return (12, 22)
        case .winter: return (-10, 12)
        case .allSeason: return (5, 30)
        }
    }
}

// MARK: - Material Tag (Optional)

enum MaterialTag: String, Codable, CaseIterable, Identifiable {
    case cotton, linen, wool, cashmere, silk
    case polyester, nylon, spandex, leather, suede
    case denim, fleece, velvet, corduroy
    
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

// MARK: - Pattern Tag (Optional)

enum PatternTag: String, Codable, CaseIterable, Identifiable {
    case solid, striped, plaid, checkered, floral
    case polkaDot, geometric, abstract, camouflage, animalPrint
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .solid: return "Solid"
        case .striped: return "Striped"
        case .plaid: return "Plaid"
        case .checkered: return "Checkered"
        case .floral: return "Floral"
        case .polkaDot: return "Polka Dot"
        case .geometric: return "Geometric"
        case .abstract: return "Abstract"
        case .camouflage: return "Camo"
        case .animalPrint: return "Animal Print"
        }
    }
}

// MARK: - Style Tag (Optional)

enum StyleTag: String, Codable, CaseIterable, Identifiable {
    case casual, smart_casual, business, formal
    case sporty, streetwear, bohemian, minimalist, vintage
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .casual: return "Casual"
        case .smart_casual: return "Smart Casual"
        case .business: return "Business"
        case .formal: return "Formal"
        case .sporty: return "Sporty"
        case .streetwear: return "Streetwear"
        case .bohemian: return "Bohemian"
        case .minimalist: return "Minimalist"
        case .vintage: return "Vintage"
        }
    }
}

// MARK: - Fit Tag (Optional)

enum FitTag: String, Codable, CaseIterable, Identifiable {
    case skinny, slim, regular, relaxed, oversized
    
    var id: String { rawValue }
    var title: String {
        switch self {
        case .skinny: return String(localized: "fit_skinny")
        case .slim: return String(localized: "fit_slim")
        case .regular: return String(localized: "fit_regular")
        case .relaxed: return String(localized: "fit_relaxed")
        case .oversized: return String(localized: "fit_oversized")
        }
    }
}

// MARK: - Size Option

enum SizeOption: String, Codable, CaseIterable, Identifiable {
    case xs, s, m, l, xl, xxl
    case w28, w30, w32, w34, w36, w38, w40
    case eu39, eu40, eu41, eu42, eu43, eu44, eu45, eu46, eu47

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xs: return String(localized: "size_xs")
        case .s: return String(localized: "size_s")
        case .m: return String(localized: "size_m")
        case .l: return String(localized: "size_l")
        case .xl: return String(localized: "size_xl")
        case .xxl: return String(localized: "size_xxl")
        case .w28: return String(localized: "size_w28")
        case .w30: return String(localized: "size_w30")
        case .w32: return String(localized: "size_w32")
        case .w34: return String(localized: "size_w34")
        case .w36: return String(localized: "size_w36")
        case .w38: return String(localized: "size_w38")
        case .w40: return String(localized: "size_w40")
        case .eu39: return String(localized: "size_eu39")
        case .eu40: return String(localized: "size_eu40")
        case .eu41: return String(localized: "size_eu41")
        case .eu42: return String(localized: "size_eu42")
        case .eu43: return String(localized: "size_eu43")
        case .eu44: return String(localized: "size_eu44")
        case .eu45: return String(localized: "size_eu45")
        case .eu46: return String(localized: "size_eu46")
        case .eu47: return String(localized: "size_eu47")
        }
    }

    static func options(for category: Category) -> [SizeOption] {
        switch category {
        case .top, .outer, .accessory:
            return [.xs, .s, .m, .l, .xl, .xxl]
        case .bottom:
            return [.w28, .w30, .w32, .w34, .w36, .w38, .w40]
        case .shoes:
            return [.eu39, .eu40, .eu41, .eu42, .eu43, .eu44, .eu45, .eu46, .eu47]
        }
    }
}

// MARK: - Layer Role (Optional)

enum LayerRole: String, Codable, CaseIterable, Identifiable {
    case base, mid, outer
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .base: return "Base Layer"
        case .mid: return "Mid Layer"
        case .outer: return "Outer Layer"
        }
    }
}

// MARK: - Weather Suitability (Optional)

enum WeatherSuitability: String, Codable, CaseIterable, Identifiable {
    case rainFriendly, waterproof, breathable, windproof, insulated
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .rainFriendly: return "Rain Friendly"
        case .waterproof: return "Waterproof"
        case .breathable: return "Breathable"
        case .windproof: return "Windproof"
        case .insulated: return "Insulated"
        }
    }
}

// MARK: - Occasion Tag (Optional)

enum OccasionTag: String, Codable, CaseIterable, Identifiable {
    case work, gym, dateNight, party, travel, beach, home
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .work: return "Work"
        case .gym: return "Gym"
        case .dateNight: return "Date Night"
        case .party: return "Party"
        case .travel: return "Travel"
        case .beach: return "Beach"
        case .home: return "Home"
        }
    }
}
