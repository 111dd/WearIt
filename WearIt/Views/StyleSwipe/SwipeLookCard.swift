import SwiftUI
import UIKit

/// A look as a flat-lay card: top and bottom large on one side, shoes and
/// extras on the other. Uses the cut-out item images, downsampled off-main.
struct SwipeLookCard: View {
    let card: StyleSwipeDeckBuilder.Card

    private var top: Garment? { card.garments.first { $0.category == .top } }
    private var bottom: Garment? { card.garments.first { $0.category == .bottom } }
    private var extras: [Garment] {
        card.garments.filter { $0.category != .top && $0.category != .bottom }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            HStack(spacing: DS.Spacing.sm) {
                VStack(spacing: DS.Spacing.sm) {
                    if let top { SwipeGarmentImage(garment: top) }
                    if let bottom { SwipeGarmentImage(garment: bottom) }
                }
                .frame(width: width * 0.58)

                VStack(spacing: DS.Spacing.sm) {
                    ForEach(extras) { garment in
                        SwipeGarmentImage(garment: garment)
                            .frame(maxHeight: height / 3)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(DS.Spacing.md)
        }
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
    }
}

private struct SwipeGarmentImage: View {
    let garment: Garment
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: garment.category.icon)
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: garment.id) {
            let path = garment.imagePath ?? garment.thumbnailPath
            guard let path else { return }
            let maxPixel = 360 * UIScreen.main.scale
            let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
                ImageStore.loadThumbnail(path: path, maxPixelSize: maxPixel)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
