//
//  DesignSystem.swift
//  WearIt
//
//  Centralized Design Tokens & Reusable Components
//  iOS 18+ Modern Native Design System
//

import SwiftUI
import UIKit

// MARK: - Design Tokens

enum DS {
    // MARK: Theme Tokens
    enum Surface {
        static var bg: Color { Color(uiColor: .systemBackground) }
        static var card: Color { Color(uiColor: .secondarySystemBackground) }
        static var raised: Color { Color(uiColor: .tertiarySystemBackground) }
        static var inverted: Color { Color(uiColor: .label) }
    }

    enum Text {
        static var primary: Color { .primary }
        static var secondary: Color { .secondary }
        static var tertiary: Color { Color(uiColor: .tertiaryLabel) }
        static var inverted: Color { Color(uiColor: .systemBackground) }
    }

    enum Border {
        static var subtle: Color { Color(uiColor: .separator).opacity(0.6) }
        static var strong: Color { Color(uiColor: .separator) }
    }

    enum Accent {
        static var primary: Color { .accentColor }
        static var love: Color { .pink }
        static var warmth: Color { .orange }
        static var danger: Color { .red }
    }

    // MARK: Spacing
    enum Spacing {
        static let xxxs: CGFloat = 2
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }
    
    // MARK: Corner Radius
    enum Radius {
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 28
        
        /// Standard card radius
        static let card: CGFloat = 18
        /// Chip/pill radius
        static let chip: CGFloat = 100
        /// Button radius
        static let button: CGFloat = 14
        /// Tile/thumbnail radius
        static let tile: CGFloat = 14
    }
    
    // MARK: Icon Sizes
    enum IconSize {
        static let xs: CGFloat = 12
        static let sm: CGFloat = 16
        static let md: CGFloat = 20
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
        static let hero: CGFloat = 64
    }
    
    // MARK: Animation (tuned for ProMotion 120Hz — short springs, interactive feel)
    enum Animation {
        /// Press / chip / micro feedback — tracks finger well at 120Hz.
        static let interactive = SwiftUI.Animation.interactiveSpring(
            response: 0.28,
            dampingFraction: 0.86,
            blendDuration: 0.08
        )
        static let fast = SwiftUI.Animation.spring(response: 0.22, dampingFraction: 0.86)
        static let standard = SwiftUI.Animation.spring(response: 0.30, dampingFraction: 0.84)
        static let slow = SwiftUI.Animation.spring(response: 0.42, dampingFraction: 0.82)
        static let gentle = SwiftUI.Animation.easeOut(duration: 0.22)
        /// Tab / screen crossfade
        static let transition = SwiftUI.Animation.snappy(duration: 0.22, extraBounce: 0.02)
    }
    
    // MARK: Shadows
    enum Shadow {
        static let subtle = (color: Color.black.opacity(0.04), radius: 8.0, y: 4.0)
        static let medium = (color: Color.black.opacity(0.08), radius: 16.0, y: 8.0)
        static let elevated = (color: Color.black.opacity(0.12), radius: 24.0, y: 12.0)
    }
    
    // MARK: Aspect Ratios
    enum AspectRatio {
        static let garmentTile: CGFloat = 4.0 / 5.0
        static let garmentCard: CGFloat = 3.0 / 4.0
        static let thumbnail: CGFloat = 1.0
    }
    
    // MARK: Grid
    enum Grid {
        static let minColumnWidth: CGFloat = 100
        static let maxColumnWidth: CGFloat = 160
        static let columnSpacing: CGFloat = 12
        static let rowSpacing: CGFloat = 12
    }
    
    // MARK: Haptics
    static let feedback = UIImpactFeedbackGenerator(style: .light)
    static let mediumFeedback = UIImpactFeedbackGenerator(style: .medium)
    
    static func haptic(_ intensity: CGFloat = 0.5) {
        feedback.impactOccurred(intensity: intensity)
    }
}

// MARK: - Card Modifier

struct DSCard: ViewModifier {
    let cornerRadius: CGFloat
    let padding: CGFloat
    let material: Material
    
    init(
        cornerRadius: CGFloat = DS.Radius.card,
        padding: CGFloat = DS.Spacing.md,
        material: Material = .ultraThinMaterial
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.material = material
    }
    
    func body(content: Content) -> some View {
        content
            .liquidGlassSurface(
                cornerRadius: cornerRadius,
                padding: padding,
                fallbackMaterial: material,
                castsShadow: true
            )
    }
}

// MARK: - Field Modifier

struct DSField: ViewModifier {
    let cornerRadius: CGFloat
    let padding: CGFloat

    init(cornerRadius: CGFloat = 12, padding: CGFloat = 10) {
        self.cornerRadius = cornerRadius
        self.padding = padding
    }

    func body(content: Content) -> some View {
        content
            .liquidGlassSurface(
                cornerRadius: cornerRadius,
                padding: padding,
                interactive: true,
                tint: Color.white.opacity(0.025),
                fallbackMaterial: .ultraThinMaterial
            )
    }
}

// MARK: - Section Header

struct DSSectionHeader: View {
    let title: String
    let icon: String?
    let action: (() -> Void)?
    let actionLabel: String?
    
    init(_ title: String, icon: String? = nil, action: (() -> Void)? = nil, actionLabel: String? = nil) {
        self.title = title
        self.icon = icon
        self.action = action
        self.actionLabel = actionLabel
    }
    
    var body: some View {
        HStack {
            if let icon {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Text.secondary)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.Text.secondary)
            
            Spacer()
            
            if let action, let label = actionLabel {
                Button(action: action) {
                    Text(label)
                        .font(.subheadline.weight(.medium))
                }
            }
        }
    }
}

// MARK: - Chip/Tag Component

struct DSChip: View {
    let title: String
    let icon: String?
    let isSelected: Bool
    let color: Color
    let action: () -> Void
    
    init(
        _ title: String,
        icon: String? = nil,
        isSelected: Bool = false,
        color: Color = .accentColor,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isSelected = isSelected
        self.color = color
        self.action = action
    }
    
    var body: some View {
        Button(action: {
            DS.haptic(0.4)
            action()
        }) {
            HStack(spacing: DS.Spacing.xxs) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption2.weight(.medium))
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .foregroundStyle(isSelected ? color : .secondary)
            .liquidGlassPill(interactive: true, tint: isSelected ? color.opacity(0.16) : nil)
        }
        .buttonStyle(.plain)
        .animation(DS.Animation.interactive, value: isSelected)
    }
}

// MARK: - Primary Button Style

struct DSPrimaryButtonStyle: ButtonStyle {
    let isDestructive: Bool
    
    init(isDestructive: Bool = false) {
        self.isDestructive = isDestructive
    }
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.sm)
            .frame(maxWidth: .infinity)
            .background(
                isDestructive ? Color.red : Color.accentColor,
                in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(DS.Animation.interactive, value: configuration.isPressed)
    }
}

// MARK: - Secondary Button Style

struct DSSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.xs + 2)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(DS.Animation.interactive, value: configuration.isPressed)
    }
}

// MARK: - Garment Thumbnail

struct DSGarmentThumbnail: View {
    let garment: Garment
    let size: ThumbnailSize
    @State private var image: UIImage?
    
    enum ThumbnailSize {
        case small  // 50pt
        case medium // 70pt
        case large  // 100pt
        
        var dimension: CGFloat {
            switch self {
            case .small: return 50
            case .medium: return 72
            case .large: return 100
            }
        }
        
        var iconSize: CGFloat {
            switch self {
            case .small: return 20
            case .medium: return 28
            case .large: return 36
            }
        }
    }
    
    init(_ garment: Garment, size: ThumbnailSize = .medium) {
        self.garment = garment
        self.size = size
    }
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                .fill(Color(.systemGray6))
            
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.dimension, height: size.dimension)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
            } else {
                Image(systemName: garment.category.icon)
                    .font(.system(size: size.iconSize))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size.dimension, height: size.dimension)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                .strokeBorder(.primary.opacity(0.05), lineWidth: 1)
        )
        .task(id: "\(garment.id.uuidString)|\(garment.thumbnailPath ?? "")|\(garment.imagePath ?? "")|\(size.dimension)") {
            let thumbPath = garment.thumbnailPath
            let imagePath = garment.imagePath
            let cacheKey = garment.id.uuidString
            let pixelSize = size.dimension * UIScreen.main.scale
            let garmentID = garment.id

            if let path = imagePath, !ImageStore.fileExists(path: path) {
                CloudKitImageSyncService.shared.ensureLocalMainImage(
                    garmentID: garmentID,
                    imagePath: path,
                    thumbnailPath: thumbPath,
                    updateThumbnail: { newPath in
                        if let newPath {
                            garment.thumbnailPath = newPath
                        }
                    }
                )
            }

            let loaded: UIImage? = await Task.detached(priority: .utility) {
                if let thumbPath,
                   let cached = ImageStore.loadStoredThumbnail(path: thumbPath, cacheKey: cacheKey) {
                    return cached
                }
                if let imagePath {
                    return ImageStore.loadThumbnail(path: imagePath, maxPixelSize: pixelSize)
                }
                return nil as UIImage?
            }.value
            image = loaded
        }
    }
}

// MARK: - Garment Grid Tile

struct DSGarmentTile: View {
    let garment: Garment
    let showTitle: Bool
    
    init(_ garment: Garment, showTitle: Bool = true) {
        self.garment = garment
        self.showTitle = showTitle
    }
    
    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                    .fill(Color(.secondarySystemBackground).opacity(0.35))
                
                if let img = tileImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    Image(systemName: garment.category.icon)
                        .font(.system(size: DS.IconSize.xl))
                        .foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(DS.AspectRatio.garmentTile, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                    .strokeBorder(.primary.opacity(0.05), lineWidth: 0.6)
            )
            .clipped()
            
            if showTitle {
                Text(garment.displayTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }

            if showTitle {
                Text(garmentMetaLine(for: garment))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: garment.imagePath) {
            guard let path = garment.imagePath else { return }
            if !ImageStore.fileExists(path: path) {
                CloudKitImageSyncService.shared.ensureLocalMainImage(
                    garmentID: garment.id,
                    imagePath: path,
                    thumbnailPath: garment.thumbnailPath,
                    updateThumbnail: { newPath in
                        if let newPath {
                            garment.thumbnailPath = newPath
                        }
                    }
                )
            }
        }
    }

    private var tileImage: UIImage? {
        if let thumbPath = garment.thumbnailPath {
            let cacheKey = garment.id.uuidString
            if let image = ImageStore.loadStoredThumbnail(path: thumbPath, cacheKey: cacheKey) {
                return image
            }
        }
        if let path = garment.imagePath {
            let pixelSize = DS.Grid.maxColumnWidth * UIScreen.main.scale * 1.2
            return ImageStore.loadThumbnail(path: path, maxPixelSize: pixelSize)
        }
        return garment.resolvedImage
    }

    private func garmentMetaLine(for garment: Garment) -> String {
        var parts: [String] = []
        if let season = garment.seasonSuitability?.title { parts.append(season) }
        if let fit = garment.fitTag?.title { parts.append(fit) }
        if let size = garment.sizeOption?.title { parts.append(size) }
        return parts.isEmpty ? String(localized: "garment_meta_default") : parts.joined(separator: " · ")
    }
}

// MARK: - Empty State

struct DSEmptyState: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?
    
    init(
        icon: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }
    
    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: DS.IconSize.hero, weight: .light))
                .foregroundStyle(.secondary)
            
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.xxl)
            
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .padding(.top, DS.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xxxl)
    }
}

// MARK: - Forecast Card (Compact)

struct DSForecastCard: View {
    let forecast: DayForecast
    let isSelected: Bool
    
    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            Text(forecast.shortDayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)
            
            Image(systemName: forecast.condition.icon)
                .font(.system(size: DS.IconSize.lg))
                .foregroundStyle(iconColor)
                .frame(height: DS.IconSize.xl)
            
            Text("\(Int(forecast.temperatureC))°")
                .font(.headline)
                .foregroundStyle(.primary)
            
            if forecast.isRaining {
                Text("\(Int(forecast.rainProbability * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, DS.Spacing.sm)
        .padding(.horizontal, DS.Spacing.md)
        .background(
            isSelected ? Color.accentColor.opacity(0.1) : Color(.systemGray6).opacity(0.5),
            in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
    }
    
    private var iconColor: Color {
        switch forecast.condition {
        case .sunny: return .orange
        case .partlyCloudy: return .yellow
        case .cloudy: return .gray
        case .rain: return .blue
        case .storm: return .purple
        case .snow: return .cyan
        }
    }
}

// MARK: - View Extensions

extension View {
    /// Standard card styling
    func dsCard(
        cornerRadius: CGFloat = DS.Radius.card,
        padding: CGFloat = DS.Spacing.md,
        material: Material = .ultraThinMaterial
    ) -> some View {
        modifier(DSCard(cornerRadius: cornerRadius, padding: padding, material: material))
    }
    
    /// Compact card with less padding
    func dsCardCompact() -> some View {
        modifier(DSCard(cornerRadius: DS.Radius.sm, padding: DS.Spacing.sm, material: .ultraThinMaterial))
    }
    
    /// Primary button style
    @ViewBuilder
    func dsPrimaryButton(destructive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self
                .font(.headline)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.roundedRectangle(radius: DS.Radius.button))
                .tint(destructive ? Color.red : Color.accentColor)
        } else {
            self.buttonStyle(DSPrimaryButtonStyle(isDestructive: destructive))
        }
    }
    
    /// Secondary button style
    @ViewBuilder
    func dsSecondaryButton() -> some View {
        if #available(iOS 26.0, *) {
            self
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle(radius: DS.Radius.button))
        } else {
            self.buttonStyle(DSSecondaryButtonStyle())
        }
    }

    /// Themed text field style
    func dsFieldStyle(cornerRadius: CGFloat = 12, padding: CGFloat = 10) -> some View {
        modifier(DSField(cornerRadius: cornerRadius, padding: padding))
    }
}

// MARK: - Adaptive Grid Helper

struct DSAdaptiveGrid<Content: View>: View {
    let items: Int
    let minWidth: CGFloat
    let spacing: CGFloat
    let content: () -> Content
    
    init(
        items: Int,
        minWidth: CGFloat = DS.Grid.minColumnWidth,
        spacing: CGFloat = DS.Grid.columnSpacing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.items = items
        self.minWidth = minWidth
        self.spacing = spacing
        self.content = content
    }
    
    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minWidth, maximum: DS.Grid.maxColumnWidth), spacing: spacing)],
            spacing: DS.Grid.rowSpacing
        ) {
            content()
        }
    }
}

// MARK: - Previews

#Preview("Design System Components") {
    ScrollView {
        VStack(spacing: 24) {
            // Section Header
            DSSectionHeader("Section Title", icon: "star.fill", action: {}, actionLabel: "See All")
                .padding(.horizontal)
            
            // Chips
            HStack {
                DSChip("All", isSelected: true) {}
                DSChip("Tops", icon: "tshirt", isSelected: false) {}
                DSChip("Bottoms", isSelected: false) {}
            }
            .padding(.horizontal)
            
            // Buttons
            VStack(spacing: 12) {
                Button("Primary Action") {}
                    .dsPrimaryButton()
                
                Button("Destructive") {}
                    .dsPrimaryButton(destructive: true)
                
                Button("Secondary") {}
                    .dsSecondaryButton()
            }
            .padding(.horizontal)
            
            // Empty State
            DSEmptyState(
                icon: "tshirt",
                title: "No Items",
                message: "Add some garments to get started",
                actionTitle: "Add Item"
            ) {}
            .dsCard()
            .padding(.horizontal)
        }
        .padding(.vertical)
    }
    .background(Color(.systemGroupedBackground))
}
