//
//  MicroQuestionCard.swift
//  WearIt
//
//  A tiny, dismissible one-question card that completes missing garment data
//  over time without a form: "What brand is this t-shirt?" — answer or skip,
//  and it won't come back until tomorrow.
//

import SwiftUI
import SwiftData

struct MicroQuestionCard: View {
    @Environment(\.modelContext) private var context

    let garment: Garment
    /// Called after the user answers or skips; parent hides the card for today.
    var onDone: () -> Void

    @State private var answer = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.xs) {
                DSGarmentThumbnail(garment, size: .small)
                    .accessibilityHidden(true)
                Text(String(
                    format: NSLocalizedString("micro_question_brand_format", comment: ""),
                    garment.displayTitle
                ))
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button {
                    DS.haptic(0.3)
                    onDone()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "micro_question_skip"))
            }

            HStack(spacing: DS.Spacing.xs) {
                TextField(String(localized: "garment_brand_placeholder"), text: $answer)
                    .textFieldStyle(.plain)
                    .dsFieldStyle()
                    .focused($isFieldFocused)
                    .submitLabel(.done)
                    .onSubmit(saveAnswer)

                Button {
                    saveAnswer()
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSave ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .accessibilityLabel(String(localized: "action_save"))
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
    }

    private var canSave: Bool {
        !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveAnswer() {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        garment.brand = trimmed
        BrandStore.upsert(name: trimmed, context: context)
        try? context.save()
        DS.haptic(0.5)
        isFieldFocused = false
        onDone()
    }
}
