//
//  StatsView.swift
//  WearIt
//
//  Created by Dor David on 05/09/2025.
//

import SwiftUI
import SwiftData

struct StatsView: View {
    @Query(sort: \Garment.name) private var garments: [Garment]
    let rec = OutfitRecommender()

    var body: some View {
        NavigationStack {
            List {
                Section("Wearing Stats") {
                    HStack {
                        Label("Total Items", systemImage: "tshirt")
                        Spacer()
                        Text("\(garments.count)")
                    }
                    HStack {
                        Label("Average Love", systemImage: "heart")
                        Spacer()
                        let avg = garments.isEmpty ? 0 : garments.map{$0.loveScore}.reduce(0,+)/garments.count
                        Text("\(avg)")
                    }
                }

                Section("Haven't worn in a while") {
                    ForEach(stale.prefix(10)) { g in
                        HStack {
                            Text(g.name)
                            Spacer()
                            Text("\(rec.daysSinceLastWorn(g)) days")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Stats")
        }
    }

    var stale: [Garment] {
        garments.sorted { rec.daysSinceLastWorn($0) > rec.daysSinceLastWorn($1) }
    }
}
