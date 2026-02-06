import SwiftUI
import SwiftData
import PhotosUI

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Garment.createdAt, order: .reverse) private var garments: [Garment]
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(garments) { g in
                        HStack(spacing: 12) {
                            if let data = g.imageData, let ui = UIImage(data: data) {
                                Image(uiImage: ui)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                                            .blendMode(.plusLighter)
                                    )
                            } else {
                                Image(systemName: "tshirt")
                                    .frame(width: 56, height: 56)
                                    .foregroundStyle(.secondary)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(g.displayTitle)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(g.category.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if g.isFavorite {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .glassListRow(cornerRadius: 14)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                context.delete(g)
                                try? context.save()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color.clear)
            .navigationTitle("הארון שלי")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddGarmentView()
            }
        }
    }
}
