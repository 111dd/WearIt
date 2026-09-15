//
//  OutfitLookRow.swift
//  WearIt
//
//  One look inside a planner day card: status chip, garment tiles, and an
//  explicit action bar (confirm / not worn / replace). Replaces the previous
//  swipe-to-act shell — every action is now a visible, tappable control.
//

import SwiftUI

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
    let onConfirm: () -> Void
    let onNotWorn: () -> Void
    let onReplace: () -> Void
    let onClearStatus: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if let statusBadge {
                statusChip(statusBadge)
            }

            content()
                .frame(maxWidth: .infinity, alignment: .leading)

            actionBar
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
    }

    private var accessibilitySummary: String {
        var parts = [accessibilitySlotLabel]
        if let statusBadge { parts.append(statusBadge) }
        return parts.joined(separator: ", ")
    }

    // MARK: - Status chip

    private func statusChip(_ text: String) -> some View {
        Label(text, systemImage: statusIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, 4)
            .liquidGlassPill(tint: statusColor.opacity(0.12))
            .accessibilityHidden(true)
    }

    private var statusIcon: String {
        switch status {
        case .worn: return "checkmark.seal.fill"
        case .notWorn: return "xmark.circle"
        case .planned: return "calendar.badge.clock"
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

    // MARK: - Action bar

    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Spacing.xs) {
                inlineActions
                Spacer(minLength: 0)
                overflowMenu
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                inlineActions
                overflowMenu
            }
        }
    }

    @ViewBuilder
    private var inlineActions: some View {
        if canConfirm {
            Button {
                DS.haptic(0.4)
                onConfirm()
            } label: {
                Label(confirmTitle, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .frame(minHeight: 44)
            .disabled(isBusy)
        }

        actionPill(
            title: replaceTitle,
            systemImage: "arrow.triangle.2.circlepath",
            tint: .blue,
            action: onReplace
        )
    }

    private func actionPill(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            DS.haptic(0.4)
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, 6)
                .foregroundStyle(tint)
                .frame(minHeight: 44)
                .liquidGlassPill(interactive: true, tint: tint.opacity(0.08))
                // HIG touch target without growing the visual pill.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(Text(title))
    }

    private var overflowMenu: some View {
        Menu {
            if status != .notWorn {
                Button(notWornTitle, systemImage: "xmark.circle") { onNotWorn() }
            }
            if let clearStatusTitle {
                Button(clearStatusTitle, systemImage: "arrow.uturn.backward.circle") {
                    onClearStatus?()
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "planner_swipe_more_actions")))
        .disabled(isBusy)
    }
}
