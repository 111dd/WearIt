import SwiftUI

/// Calm content surfaces for the planner. Glass remains on the controls above them.
struct PlannerCardSurface: ViewModifier {
    var isToday = false

    func body(content: Content) -> some View {
        content.contentSurface(cornerRadius: DS.Radius.lg, emphasized: isToday)
    }
}

/// One optional suggestion at a time, with a shared visual rhythm and native menu.
struct PlannerSuggestionCard<Options: View, Actions: View>: View {
    let title: String
    let message: String
    let systemImage: String
    let onDismiss: () -> Void
    private let options: Options
    private let actions: Actions

    init(
        title: String, message: String, systemImage: String, onDismiss: @escaping () -> Void,
        @ViewBuilder options: () -> Options, @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.onDismiss = onDismiss
        self.options = options()
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(alignment: .top, spacing: DS.Spacing.xs) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, DS.Spacing.xxs)
                options
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "action_close"))
            }
            actions
        }
        .padding(DS.Spacing.sm)
        .modifier(PlannerCardSurface())
    }
}

struct PlannerSuggestionActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, DS.Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.16 : 0.08))
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
    }
}

/// A worn day look stays recognizable without keeping its editing controls open.
struct PlannerWornLookSummary: View {
    let garments: [Garment]
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: DS.Spacing.sm) {
                HStack(spacing: -DS.Spacing.md) {
                    ForEach(Array(garments.prefix(3)), id: \.id) { garment in
                        DSGarmentThumbnail(garment, size: .small)
                    }
                }
                .fixedSize()
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    HStack(spacing: DS.Spacing.xxs) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("planner_swipe_status_worn")
                            .foregroundStyle(.primary)
                    }
                    .font(.subheadline.weight(.semibold))

                    Text("planner_show_worn_look")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(DS.Surface.raised.opacity(0.7))
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "planner_worn_day_summary"))
        .accessibilityValue(String(localized: "planner_details_collapsed"))
        .accessibilityHint(String(localized: "planner_show_worn_look"))
    }
}

/// Whole-garment photos adapt to the actual item count without shrinking a
/// complete look into a strip of tiny thumbnails. No geometry state/cache.
struct PlannerOutfitLayout: Layout {
    var minimumTileWidth: CGFloat = 88

    private let spacing = DS.Spacing.xs
    private let maximumTileWidth: CGFloat = 180
    private let maximumColumns = 3

    private struct Metrics {
        let count: Int
        let rows: Int
        let tileWidth: CGFloat

        func items(in row: Int) -> Int {
            count / rows + (row < count % rows ? 1 : 0)
        }
    }

    private func metrics(width: CGFloat, count: Int) -> Metrics {
        guard count > 0 else { return Metrics(count: 0, rows: 0, tileWidth: 0) }
        let minimumWidth = max(44, minimumTileWidth)
        let fittingColumns = max(1, Int((width + spacing) / (minimumWidth + spacing)))
        let initialColumns = min(count, maximumColumns, fittingColumns)
        let rows = (count + initialColumns - 1) / initialColumns
        // Distribute a remainder across rows instead of leaving one final item.
        let columns = (count + rows - 1) / rows
        let tileWidth = min(maximumTileWidth, max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)))
        return Metrics(count: count, rows: rows, tileWidth: tileWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposedWidth = proposal.width ?? 320
        let width = proposedWidth.isFinite ? max(0, proposedWidth) : 320
        let grid = metrics(width: width, count: subviews.count)
        let tileHeight = grid.tileWidth / DS.AspectRatio.garmentTile
        return CGSize(width: width, height: CGFloat(grid.rows) * tileHeight + CGFloat(max(0, grid.rows - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = metrics(width: bounds.width, count: subviews.count)
        let tileHeight = grid.tileWidth / DS.AspectRatio.garmentTile
        var index = 0
        for row in 0..<grid.rows {
            let rowCount = grid.items(in: row)
            let rowWidth = CGFloat(rowCount) * grid.tileWidth + CGFloat(rowCount - 1) * spacing
            let inset = max(0, (bounds.width - rowWidth) / 2)
            for column in 0..<rowCount {
                subviews[index].place(
                    at: CGPoint(
                        x: bounds.minX + inset + CGFloat(column) * (grid.tileWidth + spacing),
                        y: bounds.minY + CGFloat(row) * (tileHeight + spacing)
                    ),
                    // SwiftUI mirrors coordinates for RTL; do not reverse them again.
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: grid.tileWidth, height: tileHeight)
                )
                index += 1
            }
        }
    }
}
