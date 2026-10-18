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

/// The same live tiles grow to fill the row and wrap only when targets get too
/// small. Balanced rows avoid an isolated final tile. No geometry state/cache.
struct PlannerOutfitLayout: Layout {
    private let spacing = DS.Spacing.xs
    private let minimumWidth: CGFloat = 52

    private func metrics(width: CGFloat, count: Int) -> (columns: Int, width: CGFloat, height: CGFloat, rows: Int) {
        guard count > 0 else { return (1, 0, 0, 0) }
        let fittingColumns = max(1, Int((width + spacing) / (minimumWidth + spacing)))
        let initialColumns = min(count, fittingColumns)
        let rows = (count + initialColumns - 1) / initialColumns
        let columns = (count + rows - 1) / rows
        let tileWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        return (columns, tileWidth, tileWidth / DS.AspectRatio.garmentTile, rows)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposedWidth = proposal.width ?? 320
        let width = proposedWidth.isFinite ? max(0, proposedWidth) : 320
        let grid = metrics(width: width, count: subviews.count)
        return CGSize(width: width, height: CGFloat(grid.rows) * grid.height + CGFloat(max(0, grid.rows - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = metrics(width: bounds.width, count: subviews.count)
        for (index, subview) in subviews.enumerated() {
            let column = index % grid.columns
            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(column) * (grid.width + spacing),
                    y: bounds.minY + CGFloat(index / grid.columns) * (grid.height + spacing)
                ),
                // SwiftUI mirrors layout coordinates for RTL; do not reverse them again.
                anchor: .topLeading,
                proposal: ProposedViewSize(width: grid.width, height: grid.height)
            )
        }
    }
}
