import SwiftUI
import SwiftData
import UIKit

// MARK: - Segment

private enum AvailabilitySegment: String, CaseIterable, Identifiable {
    case unavailable
    case notRecommended
    case worn
    case cooldown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unavailable: return String(localized: "unavailable_segment_unavailable")
        case .notRecommended: return String(localized: "unavailable_segment_not_recommended")
        case .worn: return String(localized: "unavailable_segment_worn")
        case .cooldown: return String(localized: "unavailable_segment_cooldown")
        }
    }
}

// MARK: - UnavailableItemsView

struct UnavailableItemsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var weather: WeatherCenter
    @EnvironmentObject private var auth: AuthManager

    @Query(sort: \Garment.createdAt, order: .reverse) private var allGarments: [Garment]
    @Query(sort: \WearEvent.date, order: .reverse) private var wearEvents: [WearEvent]
    @Query(sort: \UserProfile.createdAt, order: .reverse) private var profiles: [UserProfile]

    @State private var currentDate: Date = Date()
    @State private var selectedSegment: AvailabilitySegment = .unavailable

    // Compute once, reuse for counts + list
    private var allAvailabilityItems: [AvailabilityService.AvailabilityItem] {
        let latestWearMap = WearHistoryService.latestWearMap(events: wearEvents)
        let ctx = recoContext
        return allGarments.map { garment in
            let status = AvailabilityService.availabilityStatus(
                for: garment,
                on: currentDate,
                ctx: ctx,
                latestWearMap: latestWearMap
            )
            return AvailabilityService.AvailabilityItem(garment: garment, status: status)
        }
    }

    private var recoContext: RecoContext {
        let profile = activeProfile
        let preferredFormality = profile?.preferredFormality ?? 3
        let temperatureC = weather.forecasts.first?.temperatureC ?? weather.currentTempC ?? 18
        let isRaining = weather.forecasts.first?.isRaining ?? weather.isRainingNow
        return RecoContext(
            desiredFormality: min(max(preferredFormality, 1), 5),
            temperatureC: temperatureC,
            isRaining: isRaining,
            now: currentDate,
            profileID: profile?.id,
            warmthSensitivity: profile?.warmthSensitivity ?? 3,
            rainTolerance: profile?.rainTolerance ?? 3
        )
    }

    private var activeProfile: UserProfile? {
        if let userIdentifier = auth.userIdentifier,
           let profile = profiles.first(where: { $0.userIdentifier == userIdentifier }) {
            return profile
        }
        return profiles.first(where: { $0.userIdentifier == nil }) ?? profiles.first
    }

    private func count(for segment: AvailabilitySegment) -> Int {
        switch segment {
        case .unavailable:
            return allAvailabilityItems.filter { if case .unavailable = $0.status { return true }; return false }.count
        case .notRecommended:
            return allAvailabilityItems.filter { !AvailabilityService.isRecommendedEligible($0.status) }.count
        case .worn:
            return allAvailabilityItems.filter { if case .worn = $0.status { return true }; return false }.count
        case .cooldown:
            return allAvailabilityItems.filter { if case .cooldown = $0.status { return true }; return false }.count
        }
    }

    private var filteredItems: [AvailabilityService.AvailabilityItem] {
        let items: [AvailabilityService.AvailabilityItem]
        switch selectedSegment {
        case .unavailable:
            items = allAvailabilityItems.filter { if case .unavailable = $0.status { return true }; return false }
        case .notRecommended:
            items = allAvailabilityItems.filter { !AvailabilityService.isRecommendedEligible($0.status) }
        case .worn:
            items = allAvailabilityItems.filter { if case .worn = $0.status { return true }; return false }
        case .cooldown:
            items = allAvailabilityItems.filter { if case .cooldown = $0.status { return true }; return false }
        }
        return sortedItems(items)
    }

    private func sortedItems(_ items: [AvailabilityService.AvailabilityItem]) -> [AvailabilityService.AvailabilityItem] {
        let latestWearMap = WearHistoryService.latestWearMap(events: wearEvents)
        switch selectedSegment {
        case .cooldown:
            return items.sorted { lhs, rhs in
                guard case .cooldown(let leftDays) = lhs.status,
                      case .cooldown(let rightDays) = rhs.status else { return false }
                if leftDays != rightDays { return leftDays < rightDays }
                let lhsDate = AvailabilityService.lastWearDate(for: lhs.garment, latestWearMap: latestWearMap) ?? .distantPast
                let rhsDate = AvailabilityService.lastWearDate(for: rhs.garment, latestWearMap: latestWearMap) ?? .distantPast
                return lhsDate > rhsDate
            }
        case .unavailable, .notRecommended, .worn:
            return items.sorted { lhs, rhs in
                if lhs.garment.loveScore != rhs.garment.loveScore {
                    return lhs.garment.loveScore > rhs.garment.loveScore
                }
                let lhsDate = AvailabilityService.lastWearDate(for: lhs.garment, latestWearMap: latestWearMap) ?? .distantPast
                let rhsDate = AvailabilityService.lastWearDate(for: rhs.garment, latestWearMap: latestWearMap) ?? .distantPast
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                return (lhs.garment.createdAt ?? .distantPast) > (rhs.garment.createdAt ?? .distantPast)
            }
        }
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Picker("", selection: $selectedSegment) {
                    ForEach(AvailabilitySegment.allCases) { segment in
                        Text("\(segment.title) (\(count(for: segment)))")
                            .tag(segment)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)

                if filteredItems.isEmpty {
                    DSEmptyState(
                        icon: "checkmark.circle",
                        title: String(localized: "unavailable_empty_title"),
                        message: String(localized: "unavailable_empty_message")
                    )
                    .padding(.horizontal, DS.Spacing.md)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: DS.Grid.minColumnWidth, maximum: DS.Grid.maxColumnWidth), spacing: DS.Grid.columnSpacing)],
                            spacing: DS.Grid.rowSpacing
                        ) {
                            ForEach(filteredItems, id: \.garment.id) { item in
                                UnavailableItemCard(
                                    item: item,
                                    onRestore: { restore(item.garment) },
                                    onExtendDays: { extendUnavailable(item.garment, days: $0) }
                                )
                            }
                        }
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.top, DS.Spacing.sm)
                        .padding(.bottom, 100)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "unavailable_title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshCurrentDate()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                refreshCurrentDate()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            refreshCurrentDate()
        }
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
}

// MARK: - Card

private struct UnavailableItemCard: View {
    let item: AvailabilityService.AvailabilityItem
    let onRestore: () -> Void
    let onExtendDays: (Int) -> Void

    private var statusText: String {
        switch item.status {
        case .unavailable:
            if item.garment.isBlocked {
                return String(localized: "unavailable_blocked")
            }
            if let until = item.garment.unavailableUntil {
                return String(format: NSLocalizedString("unavailable_until_format", comment: ""), Self.mediumDateFormatter.string(from: until))
            }
            return String(localized: "availability_unavailable_badge")
        case .worn:
            return String(localized: "planner_marked_worn")
        case .cooldown(let daysRemaining):
            return String(format: NSLocalizedString("planner_in_cooldown_format", comment: ""), daysRemaining)
        case .available:
            return String(localized: "availability_unavailable_badge")
        }
    }

    private var showActions: Bool {
        if case .unavailable = item.status { return true }
        return false
    }

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            DSGarmentTile(item.garment, showTitle: false)

            Text(item.garment.displayTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if showActions {
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
        }
        .padding(DS.Spacing.sm)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.04), lineWidth: 0.6)
        )
    }

    private static let mediumDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()
}
