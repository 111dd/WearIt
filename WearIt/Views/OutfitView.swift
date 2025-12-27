//
//  OutfitView.swift
//  WearIt
//
//  Created by Dor David on 05/09/2025.
//

import SwiftUI
import SwiftData

struct OutfitView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Garment.name) private var garments: [Garment]

    @State private var desiredFormality: Double = 3
    @State private var temperatureC: Double = 22
    @State private var isRaining: Bool = false
    @State private var suggested: [Garment] = []

    let rec = OutfitRecommender()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Today's Outfit").font(.largeTitle).bold()
                    Text("Here's an outfit suggestion for today.")
                        .foregroundStyle(.secondary)

                    OutfitGrid(items: suggested)

                    Group {
                        HStack {
                            Text("Formality: \(Int(desiredFormality))")
                            Slider(value: $desiredFormality, in: 1...5, step: 1)
                        }
                        HStack {
                            Text("Temp: \(Int(temperatureC))℃")
                            Slider(value: $temperatureC, in: -5...40, step: 1)
                        }
                        Toggle("Raining", isOn: $isRaining)
                    }
                    .padding(.vertical, 8)

                    Button {
                        refreshSuggestion()
                    } label: {
                        Text("REFRESH OUTFIT").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    if !suggested.isEmpty {
                        Button {
                            markAsWornAndSave()
                            refreshSuggestion()
                        } label: {
                            Text("MARK AS WORN").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            .onAppear { if suggested.isEmpty { refreshSuggestion() } }
            // רענון אוטומטי כשמשנים פרמטרים
            .onChange(of: desiredFormality) { _,_ in refreshSuggestion() }
            .onChange(of: temperatureC)     { _,_ in refreshSuggestion() }
            .onChange(of: isRaining)        { _,_ in refreshSuggestion() }
            .onChange(of: garments.map(\.id)) { _,_ in refreshSuggestion() }
        }
    }

    func refreshSuggestion() {
        suggested = rec.suggest(
            from: garments,
            desiredFormality: Int(desiredFormality),
            weather: .init(temperatureC: temperatureC, isRaining: isRaining)
        )
    }

    func markAsWornAndSave() {
        let now = Date()
        suggested.forEach { g in
            g.lastWorn = now
            g.timesWorn += 1
        }
        try? context.save()
    }
}

struct OutfitGrid: View {
    let items: [Garment]
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()),
                            GridItem(.flexible())], spacing: 12) {
            ForEach(items) { g in
                GarmentCard(garment: g)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct GarmentCard: View {
    let garment: Garment
    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemBackground))
                .overlay {
                    if let d = garment.imageData, let ui = UIImage(data: d) {
                        Image(uiImage: ui).resizable().scaledToFit().padding(16)
                    } else {
                        Image(systemName: "tshirt")
                            .resizable().scaledToFit().padding(24)
                    }
                }
                .frame(height: 140)
            VStack(alignment: .leading, spacing: 2) {
                Text(garment.name)
                    .font(.subheadline).lineLimit(1)
                if let b = garment.brand, !b.isEmpty {
                    Text(b)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
