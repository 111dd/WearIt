//
//  OutfitLookRow.swift
//  WearIt
//
//  One look inside a planner day card, designed to show only what matters now:
//  - Today / past, not yet answered: one quiet "Did you wear it?" line (✓ / ✕).
//  - Future days: no buttons at all — the plan is the content.
//  - Once answered: a small status mark on the corner; tapping it undoes or fine-tunes.
//  - Right after "worn": a one-tap "How was it?" emoji strip, then it disappears.
//  Gestures carry the rest: swipe the look sideways to replace it, tap an item
//  for quick swaps (handled by the tile).
//  Every gesture is mirrored as a VoiceOver action.
//

import SwiftUI

/// Look-level rating hooks. Only the day look carries them; the evening look
/// has no feedback model of its own.
struct LookFeedbackActions {
    let isLoved: Bool
    let temperature: TemperatureFeedback?
    /// True once any rating or temperature feedback exists for this look.
    let hasReaction: Bool
    let onLove: () -> Void
    let onNotMyStyle: () -> Void
    let onTemperature: (TemperatureFeedback) -> Void
    /// -1 = too formal, +1 = too casual.
    let onFormality: (Int) -> Void
}

struct OutfitLookRow<Content: View>: View {
    let canConfirm: Bool
    let isBusy: Bool
    let status: LookWearStatus?
    let confirmTitle: String
    let notWornTitle: String
    let replaceTitle: String
    let clearStatusTitle: String?
    let statusBadge: String?
    let accessibilitySlotLabel: String
    /// Future looks show no wear prompt; they are confirmed from the day menu.
    var isFuture: Bool = false
    var feedback: LookFeedbackActions? = nil
    let onConfirm: () -> Void
    let onNotWorn: () -> Void
    let onReplace: () -> Void
    let onClearStatus: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @State private var swipeOffset: CGFloat = 0
    @State private var reactionDismissed = false
    @State private var heartBurst = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Horizontal travel that commits a swipe-to-replace.
    private static var swipeCommitDistance: CGFloat { 80 }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topLeading) { statusMark }
                .overlay { heartOverlay }
                .offset(x: swipeOffset)
                .opacity(1 - min(0.5, abs(swipeOffset) / 300))

            if showsWearPrompt {
                wearPrompt
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if showsReactionStrip, let feedback {
                reactionStrip(feedback)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .opacity(isBusy ? 0.65 : 1)
        .gesture(swipeGesture)
        .animation(reduceMotion ? nil : DS.Animation.standard, value: showsWearPrompt)
        .animation(reduceMotion ? nil : DS.Animation.standard, value: showsReactionStrip)
        .onChange(of: feedback?.isLoved ?? false) { _, loved in
            guard loved else { return }
            playHeartBurst()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityAction(named: Text(confirmTitle)) {
            guard canConfirm, !isBusy else { return }
            onConfirm()
        }
        .accessibilityAction(named: Text(notWornTitle)) {
            guard !isBusy else { return }
            onNotWorn()
        }
        .accessibilityAction(named: Text(replaceTitle)) {
            guard !isBusy else { return }
            onReplace()
        }
        .accessibilityAction(named: Text(String(localized: "planner_love_it"))) {
            guard let feedback, !feedback.isLoved, !isBusy else { return }
            feedback.onLove()
        }
    }

    private var accessibilitySummary: String {
        var parts = [accessibilitySlotLabel]
        if let statusBadge { parts.append(statusBadge) }
        return parts.joined(separator: ", ")
    }

    private var showsWearPrompt: Bool {
        // Unanswered, or only planned ahead of time: ask once on the day itself.
        canConfirm && !isFuture && (status == nil || status == .planned)
    }

    private var showsReactionStrip: Bool {
        guard let feedback else { return false }
        return status == .worn && !feedback.hasReaction && !reactionDismissed
    }

    // MARK: - Wear prompt

    private var wearPrompt: some View {
        LiquidGlassGroup(spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                Text(String(localized: "planner_did_you_wear_question"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: DS.Spacing.xs)
                Button {
                    DS.haptic(0.3)
                    onNotWorn()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40)
                        .liquidGlassCircle(interactive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityLabel(Text(notWornTitle))

                Button {
                    DS.haptic(0.45)
                    onConfirm()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(DS.Accent.onFill)
                        .frame(width: 44, height: 44)
                        .modifier(ProminentGlassCircle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityLabel(Text(confirmTitle))
            }
        }
    }

    // MARK: - Status mark

    /// Small corner mark once the look has a status. Tapping opens undo and,
    /// for the day look, the fine-tune feedback that used to live in buttons.
    @ViewBuilder
    private var statusMark: some View {
        if let status {
            Menu {
                if let feedback {
                    Section(String(localized: "planner_tune_look_section")) {
                        if !feedback.isLoved {
                            Button(String(localized: "planner_love_it"), systemImage: "heart") {
                                feedback.onLove()
                            }
                        }
                        Button(String(localized: "planner_not_my_style"), systemImage: "hand.thumbsdown") {
                            feedback.onNotMyStyle()
                        }
                        Button(String(localized: "planner_too_warm"), systemImage: "thermometer.sun") {
                            feedback.onTemperature(.tooWarm)
                        }
                        .disabled(feedback.temperature == .tooWarm)
                        Button(String(localized: "planner_too_cold"), systemImage: "thermometer.snowflake") {
                            feedback.onTemperature(.tooCold)
                        }
                        .disabled(feedback.temperature == .tooCold)
                        Button(String(localized: "planner_too_formal"), systemImage: "briefcase") {
                            feedback.onFormality(-1)
                        }
                        Button(String(localized: "planner_too_casual"), systemImage: "tshirt") {
                            feedback.onFormality(1)
                        }
                    }
                }
                Section {
                    if status != .notWorn {
                        Button(notWornTitle, systemImage: "xmark.circle") { onNotWorn() }
                    }
                    if let clearStatusTitle {
                        Button(clearStatusTitle, systemImage: "arrow.uturn.backward.circle") {
                            onClearStatus?()
                        }
                    }
                }
            } label: {
                Image(systemName: Self.icon(for: status))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Self.color(for: status))
                    .symbolEffect(.bounce, value: status)
                    .frame(width: 30, height: 30)
                    .liquidGlassCircle(interactive: true, tint: Self.color(for: status).opacity(0.18))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .offset(x: -10, y: -10)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel(Text(statusBadge ?? confirmTitle))
        }
    }

    private static func icon(for status: LookWearStatus) -> String {
        switch status {
        case .worn: return "checkmark"
        case .notWorn: return "xmark"
        case .planned: return "calendar"
        }
    }

    private static func color(for status: LookWearStatus) -> Color {
        switch status {
        case .worn: return .green
        case .notWorn: return .secondary
        case .planned: return .accentColor
        }
    }

    // MARK: - Reaction strip

    private func reactionStrip(_ feedback: LookFeedbackActions) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(String(localized: "planner_how_was_it"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: DS.Spacing.xxs)
            LiquidGlassGroup(spacing: DS.Spacing.xxs) {
                HStack(spacing: DS.Spacing.xxs) {
                    reactionButton("😍", label: "planner_love_it") { feedback.onLove() }
                    reactionButton("🥶", label: "planner_too_cold") { feedback.onTemperature(.tooCold) }
                    reactionButton("🥵", label: "planner_too_warm") { feedback.onTemperature(.tooWarm) }
                    reactionButton("👎", label: "planner_not_my_style") { feedback.onNotMyStyle() }
                }
            }
            Button {
                reactionDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "micro_question_skip")))
        }
    }

    private func reactionButton(_ emoji: String, label: String.LocalizationValue, action: @escaping () -> Void) -> some View {
        Button {
            DS.haptic(0.35)
            action()
        } label: {
            Text(emoji)
                .font(.title3)
                .frame(width: 40, height: 40)
                .liquidGlassCircle(interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(Text(String(localized: label)))
    }

    // MARK: - Heart burst

    @ViewBuilder
    private var heartOverlay: some View {
        if heartBurst {
            Image(systemName: "heart.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.pink)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func playHeartBurst() {
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
            heartBurst = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.easeOut(duration: 0.25)) {
                heartBurst = false
            }
        }
    }

    // MARK: - Swipe to replace

    private var swipeGesture: HorizontalSwipeGesture {
        HorizontalSwipeGesture(
            isEnabled: !isBusy,
            onChanged: { travel in
                swipeOffset = travel * 0.55
            },
            onEnded: { travel, speed in
                let isFling = abs(travel) >= 30 && speed >= 700
                guard abs(travel) >= Self.swipeCommitDistance || isFling, !isBusy else {
                    withAnimation(reduceMotion ? nil : DS.Animation.standard) { swipeOffset = 0 }
                    return
                }
                commitSwipe(direction: travel >= 0 ? 1 : -1)
            },
            onCancelled: {
                withAnimation(reduceMotion ? nil : DS.Animation.standard) { swipeOffset = 0 }
            }
        )
    }

    /// Slide the old look out, replace it, and bring the new one in from the other side.
    private func commitSwipe(direction: CGFloat) {
        DS.haptic(0.45)
        guard !reduceMotion else {
            swipeOffset = 0
            onReplace()
            return
        }
        withAnimation(.easeIn(duration: 0.16)) {
            swipeOffset = direction * 260
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            onReplace()
            swipeOffset = -direction * 120
            withAnimation(DS.Animation.standard) {
                swipeOffset = 0
            }
        }
    }
}

/// Accent-tinted glass circle for the one primary action. Before iOS 26 the
/// plain material fallback would leave a white glyph unreadable, so it uses a
/// solid accent circle instead.
private struct ProminentGlassCircle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
        } else {
            content.background(Color.accentColor, in: Circle())
        }
    }
}
