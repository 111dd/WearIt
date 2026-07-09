import SwiftUI

/// Consistent garment display template.
/// All garments are displayed using the same visual rules for a clean, catalog-like wardrobe.
struct GarmentCard: View {
    let image: UIImage?
    let name: String
    let brand: String?
    let category: Category?
    
    // Display configuration
    var showLabel: Bool = true
    var aspectRatio: CGFloat = 4.0 / 5.0
    var cornerRadius: CGFloat = 16
    
    var body: some View {
        VStack(spacing: 8) {
            // Image container with fixed aspect ratio
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.systemGray6))
                
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    Image(systemName: category?.icon ?? "tshirt")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.05), lineWidth: 1)
            )
            
            // Labels
            if showLabel {
                VStack(spacing: 2) {
                    Text(name)
                        .font(.caption.bold())
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    
                    if let brand, !brand.isEmpty {
                        Text(brand)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

/// Large garment preview for detail views
struct GarmentPreview: View {
    let image: UIImage?
    let category: Category?
    
    var aspectRatio: CGFloat = 4.0 / 5.0
    var maxHeight: CGFloat = 300
    
    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: category?.icon ?? "photo")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.tertiary)
                    
                    Text("No Image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxHeight: maxHeight)
        .liquidGlassSurface(cornerRadius: 24)
    }
}

// MARK: - Preview

#Preview("Card") {
    HStack {
        GarmentCard(
            image: nil,
            name: "White T-Shirt",
            brand: "Nike",
            category: .top
        )
        .frame(width: 120)
        
        GarmentCard(
            image: nil,
            name: "Blue Jeans",
            brand: nil,
            category: .bottom
        )
        .frame(width: 120)
    }
    .padding()
}

#Preview("Preview") {
    GarmentPreview(image: nil, category: .top)
        .padding()
}
