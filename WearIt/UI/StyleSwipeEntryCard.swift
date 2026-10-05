import SwiftUI

/// Small daily invite to Style Swipe at the top of the planner.
struct StyleSwipeEntryCard: View {
    let deckSize: Int
    let isOnboarding: Bool
    let progress: Double
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button(action: onOpen) {
                HStack(spacing: DS.Spacing.sm) {
                    ZStack {
                        Circle()
                            .stroke(Color.primary.opacity(0.12), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "rectangle.stack.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "style_swipe_title"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(String(
                            format: NSLocalizedString(
                                isOnboarding ? "style_swipe_entry_onboarding_format" : "style_swipe_entry_daily_format",
                                comment: ""
                            ),
                            deckSize
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "action_close")))
        }
        .padding(DS.Spacing.sm)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, tint: Color(.systemBackground).opacity(0.35), castsShadow: true)
    }
}
