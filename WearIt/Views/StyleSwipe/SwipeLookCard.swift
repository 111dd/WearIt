import SwiftUI
import UIKit

/// A look as a styled flat-lay: the outfit stacked like it is worn (top, bottom,
/// shoes) on a light studio surface, layers and accessories beside it, and a
/// footer that names the color scheme so the user learns why it works.
/// Uses the cut-out item images, downsampled off-main.
struct SwipeLookCard: View {
    let card: StyleSwipeDeckBuilder.Card

    private var top: Garment? { card.garments.first { $0.category == .top } }
    private var bottom: Garment? { card.garments.first { $0.category == .bottom } }
    private var shoes: Garment? { card.garments.first { $0.category == .shoes } }
    private var extras: [Garment] {
        card.garments.filter { $0.category == .outer || $0.category == .accessory }
    }

    var body: some View {
        VStack(spacing: 0) {
            stage
            footer
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xxl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.xxl, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
    }

    // MARK: - Outfit

    private var stage: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let width = geometry.size.width
            HStack(alignment: .center, spacing: DS.Spacing.xs) {
                // The outfit as worn, top to bottom.
                VStack(spacing: DS.Spacing.xxs) {
                    if let top {
                        SwipeGarmentImage(garment: top)
                            .frame(height: height * 0.36)
                    }
                    if let bottom {
                        SwipeGarmentImage(garment: bottom)
                            .frame(height: height * 0.38)
                    }
                    if let shoes {
                        SwipeGarmentImage(garment: shoes)
                            .frame(height: height * 0.18)
                    }
                }
                .frame(width: extras.isEmpty ? width - DS.Spacing.lg * 2 : width * 0.62)

                if !extras.isEmpty {
                    VStack(spacing: DS.Spacing.sm) {
                        ForEach(extras) { garment in
                            SwipeGarmentImage(garment: garment)
                                .frame(maxHeight: garment.category == .outer ? height * 0.45 : height * 0.22)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(width: width, height: height)
        }
        .padding(.vertical, DS.Spacing.md)
        .padding(.horizontal, DS.Spacing.sm)
        .background(
            // Light studio surface in both modes so cut-outs read cleanly.
            LinearGradient(
                colors: [Color(white: 0.985), Color(white: 0.93)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(StyleSwipeCardText.paletteTitle(card.dna.scheme))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(StyleSwipeCardText.detail(card.dna))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: DS.Spacing.xs)
            swatches
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
    }

    private var swatches: some View {
        HStack(spacing: -6) {
            ForEach(card.garments) { garment in
                if let color = garment.safeColorTags.first {
                    Circle()
                        .fill(color == .multicolor
                              ? AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple, .red], center: .center))
                              : AnyShapeStyle(color.color))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}

/// Short, friendly names for what makes a look work.
enum StyleSwipeCardText {
    static func paletteTitle(_ palette: LookDNA.Palette) -> String {
        switch palette {
        case .neutral: return String(localized: "style_swipe_palette_neutral")
        case .neutralPlusPop: return String(localized: "style_swipe_palette_pop")
        case .tonal: return String(localized: "style_swipe_palette_tonal")
        case .analogous: return String(localized: "style_swipe_palette_analogous")
        case .complementary: return String(localized: "style_swipe_palette_complementary")
        case .bold: return String(localized: "style_swipe_palette_bold")
        }
    }

    static func detail(_ dna: LookDNA) -> String {
        var parts: [String] = []
        switch dna.silhouette {
        case .balanced?: parts.append(String(localized: "style_swipe_silhouette_balanced"))
        case .relaxed?: parts.append(String(localized: "style_swipe_silhouette_relaxed"))
        case .sleek?: parts.append(String(localized: "style_swipe_silhouette_sleek"))
        case nil: break
        }
        if dna.contrast >= 0.6 {
            parts.append(String(localized: "style_swipe_contrast_high"))
        } else if dna.contrast <= 0.2 {
            parts.append(String(localized: "style_swipe_contrast_soft"))
        }
        if dna.patternLoad >= 1 {
            parts.append(String(localized: "style_swipe_has_pattern"))
        }
        if parts.isEmpty {
            return String(localized: "style_swipe_detail_default")
        }
        return parts.joined(separator: " · ")
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
                    .interpolation(.high)
                    .scaledToFit()
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 4)
                    .transition(.opacity)
            } else {
                Image(systemName: garment.category.icon)
                    .font(.system(size: 30))
                    .foregroundStyle(Color.black.opacity(0.2))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: garment.id) {
            let path = garment.imagePath ?? garment.thumbnailPath
            guard let path else { return }
            let maxPixel = 520 * UIScreen.main.scale
            let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
                ImageStore.loadThumbnail(path: path, maxPixelSize: maxPixel)
            }.value
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}
