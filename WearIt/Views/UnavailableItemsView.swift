import SwiftUI
import SwiftData
import UIKit

struct UnavailableItemsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Garment.createdAt, order: .reverse) private var allGarments: [Garment]
    @State private var currentDate: Date = Date()

    private var unavailableGarments: [Garment] {
        allGarments.filter { $0.isBlocked || ($0.unavailableUntil ?? .distantPast) > currentDate }
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            if unavailableGarments.isEmpty {
                DSEmptyState(
                    icon: "checkmark.circle",
                    title: String(localized: "unavailable_empty_title"),
                    message: String(localized: "unavailable_empty_message")
                )
                .padding(.horizontal, DS.Spacing.md)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: DS.Grid.minColumnWidth, maximum: DS.Grid.maxColumnWidth), spacing: DS.Grid.columnSpacing)],
                        spacing: DS.Grid.rowSpacing
                    ) {
                        ForEach(unavailableGarments) { garment in
                            UnavailableItemCard(
                                garment: garment,
                                statusText: unavailableStatusText(for: garment),
                                onRestore: { restore(garment) },
                                onExtendDays: { extendUnavailable(garment, days: $0) }
                            )
                        }
                    }
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.top, DS.Spacing.sm)
                    .padding(.bottom, 100)
                }
            }
        }
        .navigationTitle(String(localized: "unavailable_title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshCurrentDate()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshCurrentDate()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            refreshCurrentDate()
        }
    }

    private func unavailableStatusText(for garment: Garment) -> String {
        if garment.isBlocked {
            return String(localized: "unavailable_blocked")
        }
        if let until = garment.unavailableUntil {
            return String(format: NSLocalizedString("unavailable_until_format", comment: ""), Self.mediumDateFormatter.string(from: until))
        }
        return String(localized: "availability_unavailable_badge")
    }

    private func restore(_ garment: Garment) {
        garment.markAvailable()
        try? context.save()
    }

    private func extendUnavailable(_ garment: Garment, days: Int) {
        let until = Calendar.current.date(byAdding: .day, value: days, to: Date())
        garment.markUnavailable(until: until)
        try? context.save()
    }

    private func refreshCurrentDate() {
        currentDate = Date()
    }

    private static let mediumDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()
}

private struct UnavailableItemCard: View {
    let garment: Garment
    let statusText: String
    let onRestore: () -> Void
    let onExtendDays: (Int) -> Void

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            DSGarmentTile(garment, showTitle: false)

            Text(garment.displayTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: DS.Spacing.xs) {
                Button(String(localized: "unavailable_mark_available")) {
                    onRestore()
                }
                .dsSecondaryButton()

                Menu {
                    Button(String(localized: "planner_unavailable_1d")) { onExtendDays(1) }
                    Button(String(localized: "planner_unavailable_2d")) { onExtendDays(2) }
                    Button(String(localized: "planner_unavailable_1w")) { onExtendDays(7) }
                } label: {
                    Label(String(localized: "unavailable_extend"), systemImage: "calendar.badge.plus")
                }
                .dsSecondaryButton()
            }
        }
        .padding(DS.Spacing.sm)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.04), lineWidth: 0.6)
        )
    }
}
