//
//  OutfitLookRow.swift
//  WearIt
//
//  One look inside a planner day card: garment tiles over a single Liquid
//  Glass control bar. One primary action (wear / status), a heart, a replace
//  button and one menu that holds everything else (fine-tune feedback, not
//  worn, clear status). On iOS 26+ the controls share a GlassEffectContainer,
//  so the wear button morphs into the status capsule once confirmed.
//

import SwiftUI

/// Look-level rating hooks. Only the day look carries them; the evening look
/// has no feedback model of its own.
struct LookFeedbackActions {
    let isLoved: Bool
    let temperature: TemperatureFeedback?
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
    var feedback: LookFeedbackActions? = nil
    let onConfirm: () -> Void
    let onNotWorn: () -> Void
    let onReplace: () -> Void
    let onClearStatus: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @Namespace private var glassNamespace
    @State private var replaceTick = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)

            controlBar
        }
        .opacity(isBusy ? 0.65 : 1)
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

    // MARK: - Control bar

    private var controlBar: some View {
        LiquidGlassGroup(spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.xs) {
                primaryControl
                Spacer(minLength: DS.Spacing.xs)
                if let feedback {
                    loveButton(feedback)
                }
                replaceButton
                moreMenu
            }
        }
        .animation(reduceMotion ? nil : DS.Animation.standard, value: canConfirm)
        .animation(reduceMotion ? nil : DS.Animation.standard, value: status)
    }

    /// Wear button while the look can still be confirmed; afterwards the same
    /// glass shape becomes a status capsule that opens the undo options.
    @ViewBuilder
    private var primaryControl: some View {
        if canConfirm {
            Button {
                DS.haptic(0.4)
                onConfirm()
            } label: {
                HStack(spacing: DS.Spacing.xxs) {
                    Label(confirmTitle, systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let statusBadge {
                        // Secondary state, e.g. planned earlier or marked not worn.
                        Text("· \(statusBadge)")
                            .font(.caption.weight(.medium))
                            .opacity(0.8)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, DS.Spacing.md)
                .frame(minHeight: 44)
                .modifier(ProminentGlassCapsule())
                .liquidGlassID("primary", in: glassNamespace)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .transition(.opacity)
        } else {
            Menu {
                statusMenuItems
            } label: {
                Label(statusBadge ?? confirmTitle, systemImage: statusIcon)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(statusColor)
                    .symbolEffect(.bounce, value: status)
                    .padding(.horizontal, DS.Spacing.md)
                    .frame(minHeight: 44)
                    .liquidGlassPill(interactive: true, tint: statusColor.opacity(0.14))
                    .liquidGlassID("primary", in: glassNamespace)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .transition(.opacity)
        }
    }

    private func loveButton(_ feedback: LookFeedbackActions) -> some View {
        Button {
            guard !feedback.isLoved else { return }
            feedback.onLove()
        } label: {
            Image(systemName: feedback.isLoved ? "heart.fill" : "heart")
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: feedback.isLoved)
                .foregroundStyle(feedback.isLoved ? Color.pink : .primary)
                .modifier(GlassCircleIcon(namespace: glassNamespace, id: "love"))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(Text(String(localized: "planner_love_it")))
        .accessibilityAddTraits(feedback.isLoved ? .isSelected : [])
    }

    private var replaceButton: some View {
        Button {
            replaceTick += 1
            DS.haptic(0.4)
            onReplace()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.rotate, value: replaceTick)
                .foregroundStyle(.primary)
                .modifier(GlassCircleIcon(namespace: glassNamespace, id: "replace"))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(Text(replaceTitle))
    }

    private var moreMenu: some View {
        Menu {
            if let feedback {
                Section(String(localized: "planner_tune_look_section")) {
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
                statusMenuItems
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.primary)
                .modifier(GlassCircleIcon(namespace: glassNamespace, id: "more"))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(Text(String(localized: "planner_swipe_more_actions")))
    }

    @ViewBuilder
    private var statusMenuItems: some View {
        if status != .notWorn {
            Button(notWornTitle, systemImage: "xmark.circle") { onNotWorn() }
        }
        if let clearStatusTitle {
            Button(clearStatusTitle, systemImage: "arrow.uturn.backward.circle") {
                onClearStatus?()
            }
        }
    }

    private var statusIcon: String {
        switch status {
        case .worn: return "checkmark.seal.fill"
        case .notWorn: return "xmark.circle"
        case .planned: return "calendar.badge.checkmark"
        case nil: return "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch status {
        case .worn: return .green
        case .notWorn: return .secondary
        case .planned: return .accentColor
        case nil: return .secondary
        }
    }
}

/// Accent-tinted glass capsule for the one primary action. Before iOS 26 the
/// plain material fallback would leave white text unreadable, so it uses a
/// solid accent capsule instead.
private struct ProminentGlassCapsule: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
        } else {
            content.background(Color.accentColor, in: Capsule())
        }
    }
}

/// 44pt glass circle for a single SF Symbol in the look control bar.
private struct GlassCircleIcon: ViewModifier {
    let namespace: Namespace.ID
    let id: String

    func body(content: Content) -> some View {
        content
            .font(.body.weight(.semibold))
            .frame(width: 44, height: 44)
            .liquidGlassCircle(interactive: true)
            .liquidGlassID(id, in: namespace)
            .contentShape(Circle())
    }
}
