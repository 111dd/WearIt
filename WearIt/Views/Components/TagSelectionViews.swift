//
//  TagSelectionViews.swift
//  WearIt
//
//  Reusable chip-based selection components for structured garment fields.

import SwiftUI

// MARK: - Color Tag Selector (Multi-select)

struct ColorTagSelector: View {
    @Binding var selectedColors: [ColorTag]
    var columns: Int = 4
    
    private let gridColumns: [GridItem]
    
    init(selectedColors: Binding<[ColorTag]>, columns: Int = 4) {
        self._selectedColors = selectedColors
        self.columns = columns
        self.gridColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: columns)
    }
    
    var body: some View {
        LazyVGrid(columns: gridColumns, spacing: 8) {
            ForEach(ColorTag.allCases) { color in
                ColorChip(
                    color: color,
                    isSelected: selectedColors.contains(color),
                    action: { toggleColor(color) }
                )
            }
        }
    }
    
    private func toggleColor(_ color: ColorTag) {
        if let index = selectedColors.firstIndex(of: color) {
            selectedColors.remove(at: index)
        } else {
            selectedColors.append(color)
        }
    }
}

private struct ColorChip: View {
    let color: ColorTag
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Circle()
                    .fill(color.color)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Circle()
                            .strokeBorder(DS.Border.subtle, lineWidth: 1)
                    )
                    .overlay {
                        if color == .white || color == .cream || color == .beige {
                            Circle()
                                .strokeBorder(DS.Border.strong.opacity(0.6), lineWidth: 1)
                        }
                        if color == .multicolor {
                            LinearGradient(
                                colors: [.red, .orange, .yellow, .green, .blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .mask(Circle())
                        }
                    }
                
                Text(color.title)
                    .font(.caption2)
                    .foregroundStyle(DS.Text.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(DS.Surface.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? DS.Accent.primary : DS.Border.subtle, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Item Type Selector

struct ItemTypeSelector: View {
    let category: Category
    @Binding var selectedType: ItemType?
    
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(category.itemTypes) { type in
                ChipButton(
                    title: type.title,
                    isSelected: selectedType == type,
                    action: { selectedType = type }
                )
            }
        }
    }
}

// MARK: - Season Selector

struct SeasonSelector: View {
    @Binding var selectedSeason: SeasonSuitability?
    
    var body: some View {
        HStack(spacing: 8) {
            ForEach(SeasonSuitability.allCases) { season in
                Button {
                    selectedSeason = season
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: season.icon)
                            .font(.title3)
                        Text(season.title)
                            .font(.caption2.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        selectedSeason == season ? DS.Surface.inverted : DS.Surface.card,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .foregroundStyle(selectedSeason == season ? DS.Text.inverted : DS.Text.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selectedSeason == season ? DS.Accent.primary : DS.Border.subtle, lineWidth: selectedSeason == season ? 2 : 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Generic Multi-Select Tag Selector

struct TagSelector<T: Identifiable & Hashable>: View where T: RawRepresentable, T.RawValue == String {
    let title: String
    let allTags: [T]
    @Binding var selectedTags: [T]
    let titleForTag: (T) -> String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(DS.Text.secondary)
                .textCase(.uppercase)
            
            FlowLayout(spacing: 8) {
                ForEach(allTags) { tag in
                    ChipButton(
                        title: titleForTag(tag),
                        isSelected: selectedTags.contains(tag),
                        action: { toggleTag(tag) }
                    )
                }
            }
        }
    }
    
    private func toggleTag(_ tag: T) {
        if let index = selectedTags.firstIndex(of: tag) {
            selectedTags.remove(at: index)
        } else {
            selectedTags.append(tag)
        }
    }
}

// MARK: - Single-Select Tag Picker

struct SingleTagPicker<T: Identifiable & Hashable>: View where T: RawRepresentable, T.RawValue == String {
    let title: String
    let allTags: [T]
    @Binding var selectedTag: T?
    let titleForTag: (T) -> String
    var allowDeselect: Bool = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(DS.Text.secondary)
                .textCase(.uppercase)
            
            FlowLayout(spacing: 8) {
                ForEach(allTags) { tag in
                    ChipButton(
                        title: titleForTag(tag),
                        isSelected: selectedTag == tag,
                        action: {
                            if selectedTag == tag && allowDeselect {
                                selectedTag = nil
                            } else {
                                selectedTag = tag
                            }
                        }
                    )
                }
            }
        }
    }
}

// MARK: - Chip Button

struct ChipButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(DS.Surface.card, in: Capsule())
                .foregroundStyle(isSelected ? DS.Accent.primary : DS.Text.primary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? DS.Accent.primary : DS.Border.subtle, lineWidth: isSelected ? 1.5 : 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Flow Layout (for wrapping chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }
    
    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            
            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalHeight = currentY + lineHeight
        }
        
        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

// MARK: - Temperature Range Slider

struct TemperatureRangeSlider: View {
    @Binding var minTemp: Double?
    @Binding var maxTemp: Double?
    let defaultRange: (min: Double, max: Double)
    
    private var effectiveMin: Double {
        minTemp ?? defaultRange.min
    }
    
    private var effectiveMax: Double {
        maxTemp ?? defaultRange.max
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Temperature Range")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(effectiveMin))°C – \(Int(effectiveMax))°C")
                    .font(.caption.bold())
                    .foregroundStyle(DS.Accent.primary)
            }
            
            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    Text("Min")
                        .font(.caption2)
                        .foregroundStyle(DS.Text.secondary)
                    Slider(
                        value: Binding(
                            get: { effectiveMin },
                            set: { minTemp = $0 }
                        ),
                        in: -10...30,
                        step: 1
                    )
                    .tint(DS.Accent.primary)
                }
                
                VStack(alignment: .leading) {
                    Text("Max")
                        .font(.caption2)
                        .foregroundStyle(DS.Text.secondary)
                    Slider(
                        value: Binding(
                            get: { effectiveMax },
                            set: { maxTemp = $0 }
                        ),
                        in: 5...45,
                        step: 1
                    )
                    .tint(DS.Accent.primary)
                }
            }
            
            Button("Reset to Default") {
                minTemp = nil
                maxTemp = nil
            }
            .font(.caption)
            .foregroundStyle(DS.Text.secondary)
        }
    }
}

// MARK: - Previews

#Preview("Color Selector") {
    struct Preview: View {
        @State var colors: [ColorTag] = [.black, .white]
        var body: some View {
            ColorTagSelector(selectedColors: $colors)
                .padding()
        }
    }
    return Preview()
}

#Preview("Season Selector") {
    struct Preview: View {
        @State var season: SeasonSuitability? = .allSeason
        var body: some View {
            SeasonSelector(selectedSeason: $season)
                .padding()
        }
    }
    return Preview()
}
