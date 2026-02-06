//
//  BarcodeLookup.swift
//  WearIt
//
//  Created by Dor David on 05/09/2025.
//

import Foundation

struct BarcodeRecord {
    let brand: String?
    let name: String?
    let category: Category?
    let colors: [String]?
    let formality: Int?
    let warmth: Int?
}

/// דוגמאות קונקרטיות + כללי prefix
enum BarcodeLookup {
    // מאגר קטן קשיח (EAN/UPC מלאים)
    static let exact: [String : BarcodeRecord] = [
        "0885909950805": .init(brand: "Nike", name: "Dri-FIT Tee", category: .top, colors: ["white"], formality: 1, warmth: 1),
        "0194251234567": .init(brand: "Adidas", name: "Campus Sneakers", category: .shoes, colors: ["black","white"], formality: 1, warmth: 1),
        "7290012345678": .init(brand: "FOXX", name: "Classic Shirt", category: .top, colors: ["blue"], formality: 4, warmth: 2)
    ]

    // ניחושים לפי קידומות יצרן/מדינה (הדגמה)
    static let prefixes: [(prefix: String, record: BarcodeRecord)] = [
        ("088", .init(brand: "Nike (guess)", name: nil, category: nil, colors: nil, formality: nil, warmth: nil)),
        ("019", .init(brand: "Adidas (guess)", name: nil, category: nil, colors: nil, formality: nil, warmth: nil)),
        ("729", .init(brand: "IL Brand (guess)", name: nil, category: nil, colors: nil, formality: nil, warmth: nil))
    ]

    static func query(_ code: String) -> BarcodeRecord? {
        if let r = exact[code] { return r }
        if let match = prefixes.first(where: { code.hasPrefix($0.prefix) })?.record { return match }
        return nil
    }
}
