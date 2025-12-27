//
//  Untitled.swift
//  WearIt
//
//  Created by Dor David on 05/09/2025.
//

import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    var body: some View {
        TabView {
            OutfitView()
                .tabItem { Label("Outfit", systemImage: "house") }

            WardrobeView()
                .tabItem { Label("Wardrobe", systemImage: "square.grid.2x2") }

            AddGarmentView()
                .tabItem { Label("Add", systemImage: "plus.circle") }

            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.bar") }
        }
        .task {
           SeedData.load(context: context) // ← כאן להשתמש ב-context האמיתי
       }
    }
}
