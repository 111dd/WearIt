import SwiftUI

/// Planner invite to connect the calendar, so looks fit the user's events.
struct CalendarConnectCard: View {
    let onConnect: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button(action: onConnect) {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "calendar_connect_title"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(String(localized: "calendar_connect_subtitle"))
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

            PromptDismissButton(action: onDismiss)
        }
        .padding(DS.Spacing.sm)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, tint: Color(.systemBackground).opacity(0.35), castsShadow: true)
    }
}

/// Asked once, the first time work shows up on the calendar.
struct WorkDressCodeCard: View {
    let onPick: (WorkDressCode) -> Void
    let onDismiss: () -> Void

    private let columns = [GridItem(.flexible(), spacing: DS.Spacing.xs), GridItem(.flexible(), spacing: DS.Spacing.xs)]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                Image(systemName: "briefcase")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "work_dress_question"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(String(localized: "work_dress_question_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                PromptDismissButton(action: onDismiss)
            }

            LazyVGrid(columns: columns, spacing: DS.Spacing.xs) {
                ForEach(WorkDressCode.allCases) { code in
                    Button {
                        DS.haptic(0.4)
                        onPick(code)
                    } label: {
                        Label(code.title, systemImage: code.icon)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(.horizontal, DS.Spacing.xs)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
            }
        }
        .padding(DS.Spacing.sm)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, tint: Color(.systemBackground).opacity(0.35), castsShadow: true)
    }
}

private struct PromptDismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "action_close")))
    }
}
