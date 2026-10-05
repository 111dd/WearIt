import SwiftUI

/// One-tap question inside a day card when the sleeve / jacket call is a toss-up.
struct LayerQuestionCard: View {
    let morningTemp: Int
    let middayTemp: Int
    let onPick: (DayLayerChoice) -> Void
    let onDismiss: () -> Void

    var body: some View {
        QuestionCardShell(
            icon: "thermometer.sun",
            title: String(format: String(localized: "comfort_question_format"), morningTemp, middayTemp),
            onDismiss: onDismiss
        ) {
            HStack(spacing: DS.Spacing.xs) {
                ForEach(DayLayerChoice.allCases) { choice in
                    QuestionChip(title: choice.title, icon: choice.icon) { onPick(choice) }
                }
            }
        }
    }
}

/// "What is “At Ronit's”?" for an event the app could not read.
struct EventQuestionCard: View {
    let title: String
    let onPick: (CalendarEventUnderstanding.Kind) -> Void
    let onDismiss: () -> Void

    var body: some View {
        QuestionCardShell(
            icon: "questionmark.bubble",
            title: String(format: String(localized: "event_question_format"), title),
            onDismiss: onDismiss
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(CalendarEventUnderstanding.Kind.correctionChoices, id: \.self) { kind in
                        QuestionChip(title: kind.correctionTitle, icon: kind.correctionIcon) { onPick(kind) }
                            .fixedSize()
                    }
                }
            }
        }
    }
}

/// "Shirt: short or long sleeves?" in the wardrobe, asked once per top.
struct SleeveQuestionCard: View {
    @Environment(\.modelContext) private var context
    let garment: Garment
    let onDone: () -> Void

    var body: some View {
        QuestionCardShell(
            icon: "tshirt",
            title: String(format: String(localized: "micro_question_sleeve_format"), garment.displayTitle),
            onDismiss: onDone
        ) {
            HStack(spacing: DS.Spacing.xs) {
                ForEach(SleeveLength.allCases) { sleeve in
                    QuestionChip(title: sleeve.title, icon: nil) {
                        garment.sleeveLength = sleeve
                        try? context.save()
                        onDone()
                    }
                }
            }
        }
        .padding(DS.Spacing.xs)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
    }
}

private struct QuestionCardShell<Choices: View>: View {
    let icon: String
    let title: String
    let onDismiss: () -> Void
    @ViewBuilder let choices: () -> Choices

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "action_close")))
            }
            choices()
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
    }
}

private struct QuestionChip: View {
    let title: String
    let icon: String?
    let action: () -> Void

    var body: some View {
        Button {
            DS.haptic(0.4)
            action()
        } label: {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon).font(.caption.weight(.semibold))
                }
                Text(title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.horizontal, DS.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
                    .fill(Color(.systemBackground).opacity(0.7))
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
