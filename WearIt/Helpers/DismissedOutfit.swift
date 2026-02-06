import Foundation
import SwiftData

//
//  DismissedOutfit.swift
//  WearIt
//
//  Created by Dor David on 05/09/2025.
//

@Model final class DismissedOutfit {
    var key: String = ""
    init(key: String) { self.key = key }
}

func outfitKey(for items: [Garment]) -> String {
    items
        .map { $0.id.uuidString.lowercased() }
        .sorted()
        .joined(separator: "|")
}
