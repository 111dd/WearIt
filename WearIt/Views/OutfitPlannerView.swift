//
//  OutfitPlannerView.swift
//  WearIt
//
//  3-day outfit planner board with drag & swap

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

struct OutfitPlannerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var weather: WeatherCenter

    @Query(sort: \Garment.createdAt, order: .reverse) private var allGarments: [Garment]
    @Query(sort: \UserProfile.createdAt, order: .reverse) private var profiles: [UserProfile]
    @Query(sort: \DayPlan.date, order: .reverse) private var dayPlans: [DayPlan]
    @Query(sort: \WearEvent.date, order: .reverse) private var wearEvents: [WearEvent]
    
    @State private var boardState = PlannerBoardState()
    @State private var showFeedbackAlert = false
    @State private var alertMessage = ""
    @State private var activeSheet: PlannerSheet?
    @State private var targetedSlots: Set<SlotTarget> = []
    @State private var lastForecastSignature: String = ""
    @State private var expandedDayDetails: Set<Int> = []
    @State private var selectedDayIndex: Int = 0
    @State private var availableGarmentsCache: [Garment] = []
    @State private var currentDate: Date = Date()
    @State private var availableGarmentsSignature: String = ""
    @State private var didRunWearHistoryDebug = false
    @State private var dirtyDayIndices: Set<Int> = []
    @State private var plannerSaveDebouncer = Debouncer(interval: 15.0)

    private let feedback = UIImpactFeedbackGenerator(style: .medium)
    private static let dayNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()
    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
    
    private struct SlotTarget: Hashable {
        let dayIndex: Int
        let slot: OutfitSlot
        let lookTime: LookTime
    }

    private enum PlannerSheet: Identifiable {
        case garmentMenu(Garment)
        case addPicker(dayIndex: Int, slots: [OutfitSlot], lookTime: LookTime, initialSlot: OutfitSlot?)
        case addNewItem(dayIndex: Int, slot: OutfitSlot, lookTime: LookTime)

        var id: String {
            switch self {
            case .garmentMenu(let garment):
                return "garment-\(garment.id.uuidString)"
            case .addPicker(let dayIndex, _, let lookTime, let initialSlot):
                let slot = initialSlot?.rawValue ?? "any"
                return "picker-\(dayIndex)-\(lookTime.rawValue)-\(slot)"
            case .addNewItem(let dayIndex, let slot, let lookTime):
                return "new-\(dayIndex)-\(slot.rawValue)-\(lookTime.rawValue)"
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var availableGarments: [Garment] {
        availableGarmentsCache
    }

    private var latestWearByGarmentID: [UUID: Date] {
        WearHistoryService.latestWearMap(events: wearEvents)
    }
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            plannerContent
        }
        .navigationTitle(String(localized: "planner_board_title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: handleAppear)
        .onChange(of: weather.forecasts) { _, newValue in
            handleForecastChange(newValue)
        }
        .onChange(of: allGarments.count) { _, newValue in
            handleGarmentChange(newValue)
        }
        .alert(String(localized: "error_title"), isPresented: $boardState.showUnavailableAlert) {
            Button(String(localized: "action_confirm"), role: .cancel) { }
        } message: {
            Text(boardState.alertMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .confirmWornFromWidget)) { _ in
            confirmWorn(dayIndex: 0)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .garmentMenu(let garment):
                garmentSheet(garment)
            case .addPicker(let dayIndex, let slots, let lookTime, let initialSlot):
                addPickerSheet(dayIndex: dayIndex, slots: slots, lookTime: lookTime, initialSlot: initialSlot)
            case .addNewItem(let dayIndex, let slot, let lookTime):
                addNewItemSheet(dayIndex: dayIndex, slot: slot, lookTime: lookTime)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshCurrentDate()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            refreshCurrentDate()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                flushDirtyPlans()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .plannerFlushDirtyPlans)) { _ in
            flushDirtyPlans()
        }
    }

    private var plannerContent: some View {
        ZStack {
            LiquidGlassBackdrop()
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                    plannerHeader
                        .padding(.horizontal, DS.Spacing.md)

                    ForEach(0..<3, id: \.self) { dayIndex in
                        if dayIndex < boardState.days.count {
                            dayColumn(for: dayIndex)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, DS.Spacing.sm)
                        }
                    }
                }
                .padding(.top, DS.Spacing.sm)
                .padding(.bottom, DS.Spacing.sm)
            }
        }
    }

    private func handleAppear() {
        boardState.initializeDays()
        hydrateFromPlans()
        updateAvailableGarments()
        refreshCurrentDate()
        #if DEBUG
        if !didRunWearHistoryDebug {
            WearHistoryService.debugCheckConsistency(
                garments: allGarments,
                events: wearEvents
            )
            didRunWearHistoryDebug = true
        }
        #endif
        Task {
            await weather.refreshForecast(source: "OutfitPlannerView.handleAppear")
            boardState.updateForecasts(weather.forecasts)
            lastForecastSignature = forecastSignature(weather.forecasts)
            generateAllOutfits(fillMissingOnly: true)
        }
    }

    private func handleForecastChange(_ newForecasts: [DayForecast]) {
        let signature = forecastSignature(newForecasts)
        guard signature != lastForecastSignature else { return }
        lastForecastSignature = signature
        boardState.updateForecasts(newForecasts)
        generateAllOutfits(fillMissingOnly: true)
    }

    private func handleGarmentChange(_ _: Int) {
        hydrateFromPlans()
        updateAvailableGarments()
        generateAllOutfits(fillMissingOnly: true)
    }

    private func garmentSheet(_ garment: Garment) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.md) {
                    DSGarmentThumbnail(garment, size: .large)
                    
                    Text(garment.displayTitle)
                        .font(.headline)
                    
                    Text(lastWornText(for: garment))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    garmentDetailsSection(for: garment)
                    
                    VStack(spacing: DS.Spacing.xs) {
                        Button {
                            markWornToday(garment)
                        } label: {
                            Label(String(localized: "planner_mark_worn_today"), systemImage: "checkmark.circle")
                        }
                        .dsSecondaryButton()
                        
                        Button {
                            replaceSingleItem(for: garment)
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(
                                    Circle()
                                        .strokeBorder(DS.Border.subtle, lineWidth: 0.6)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "planner_replace_single_item"))

                        Button {
                            openAddNewItemForExisting(garment)
                        } label: {
                            Label(String(localized: "planner_add_new_item"), systemImage: "plus")
                        }
                        .dsSecondaryButton()
                        
                        if garment.isCurrentlyUnavailable {
                            Button {
                                markAvailable(garment)
                            } label: {
                                Label(String(localized: "planner_mark_available_now"), systemImage: "checkmark.circle")
                            }
                            .dsSecondaryButton()
                        } else {
                            Button(role: .destructive) {
                                markUnavailable(garment)
                            } label: {
                                Label(String(localized: "planner_mark_unavailable_now"), systemImage: "xmark.circle")
                            }
                            .dsSecondaryButton()
                            
                            HStack(spacing: DS.Spacing.xs) {
                                Button(String(localized: "planner_unavailable_1d")) {
                                    markUnavailable(garment, days: 1)
                                }
                                .dsSecondaryButton()
                                
                                Button(String(localized: "planner_unavailable_2d")) {
                                    markUnavailable(garment, days: 2)
                                }
                                .dsSecondaryButton()
                                
                                Button(String(localized: "planner_unavailable_1w")) {
                                    markUnavailable(garment, days: 7)
                                }
                                .dsSecondaryButton()
                            }
                        }
                        
                        NavigationLink {
                            EditGarmentView(garment: garment)
                        } label: {
                            Label(String(localized: "planner_go_to_item"), systemImage: "pencil")
                        }
                        .dsSecondaryButton()
                    }
                }
                .padding(DS.Spacing.md)
            }
            .background(Color(.systemBackground))
            .navigationTitle(String(localized: "planner_item_actions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "action_close")) {
                        activeSheet = nil
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func addPickerSheet(
        dayIndex: Int,
        slots: [OutfitSlot],
        lookTime: LookTime,
        initialSlot: OutfitSlot?
    ) -> some View {
        NavigationStack {
            PlannerAddPicker(
                dayIndex: dayIndex,
                availableSlots: slots,
                initialSlot: initialSlot,
                recommendedItemsForSlot: { slot in
                    recommendedItemsForSlot(slot, dayIndex: dayIndex, lookTime: lookTime)
                },
                allItemsForSlot: { slot in
                    allItemsForSlot(slot, dayIndex: dayIndex, lookTime: lookTime)
                },
                onSelect: { garment, slot, allowUnavailable in
                    let success = assignGarment(
                        garment,
                        to: slot,
                        dayIndex: dayIndex,
                        lookTime: lookTime,
                        allowUnavailable: allowUnavailable
                    )
                    if success {
                        activeSheet = nil
                    }
                },
                onAddNewItem: { slot in
                    openAddNewItem(dayIndex: dayIndex, slot: slot, lookTime: lookTime)
                },
                onClose: { activeSheet = nil }
            )
        }
    }

    private func addNewItemSheet(dayIndex: Int, slot: OutfitSlot, lookTime: LookTime) -> some View {
        AddGarmentView(initialCategory: slot.allowedCategories.first) { garment in
            guard slot.allowedCategories.contains(garment.category) else {
                boardState.alertMessage = String(localized: "planner_add_item_category_mismatch")
                boardState.showUnavailableAlert = true
                return
            }
            let success = assignGarment(garment, to: slot, dayIndex: dayIndex, lookTime: lookTime)
            if success {
                activeSheet = nil
            }
        }
    }
    
    // MARK: - Day Column
    
    private func dayColumn(for dayIndex: Int) -> some View {
        let state = boardState.days[dayIndex]
        let signature = DayCardSignature(
            dayIndex: dayIndex,
            state: state,
            isExpanded: isDetailsExpanded(dayIndex),
            isSelected: selectedDayIndex == dayIndex,
            isConfirmed: isConfirmed(dayIndex),
            forecastKey: forecastKey(for: state.forecast),
            assignedSignature: assignedGarmentSignature(for: dayIndex),
            availableSignature: availableGarmentsSignature
        )

        return DayCardContainer(signature: signature) {
            VStack(spacing: DS.Spacing.sm) {
                dayTopBar(for: state, dayIndex: dayIndex)

                outfitRow(for: dayIndex, lookTime: .day)
                availabilityHintsView(for: dayIndex, lookTime: .day)

                if state.useEveningLook {
                    eveningSection(for: dayIndex)
                }

                dayCardActions(for: dayIndex)

                if !isDetailsExpanded(dayIndex) {
                    recommendationPreview(for: dayIndex)
                }

                if isDetailsExpanded(dayIndex) {
                    dayDetailsSection(for: dayIndex)
                }
            }
            .padding(DS.Spacing.sm)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
                    .blendMode(.plusLighter)
            )
        }
    }

    // MARK: - Planner Header
    
    private var plannerHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "planner_board_title"))
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.primary)

            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(headerLine)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(2)
        }
    }
    
    // MARK: - Day Top Bar
    
    private func dayTopBar(for state: PlannerDayState, dayIndex: Int) -> some View {
        let dayLabel = dayName(for: state.id)
        let dateText = formattedDate(state.date)
        let header = "\(dayLabel) · \(dateText)"

        return HStack(alignment: .center, spacing: DS.Spacing.sm) {
            Text(header)
                .font(.title3.weight(.bold))
                .foregroundStyle(dayIndex == selectedDayIndex ? Color.accentColor : .primary)
                .lineLimit(1)

            Spacer()

            forecastChip(for: dayIndex)

            dayActionMenu(for: dayIndex)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedDayIndex = dayIndex
        }
    }

    private func dayActionMenu(for dayIndex: Int) -> some View {
        Menu {
            Button {
                refreshDay(dayIndex)
            } label: {
                Label(String(localized: "planner_refresh_day"), systemImage: "arrow.clockwise")
            }
            switch dayTiming(for: dayIndex) {
            case .future:
                Button {
                    confirmPlan(dayIndex: dayIndex)
                } label: {
                    Label(String(localized: "planner_confirm_plan"), systemImage: "checkmark.seal")
                }
            case .today, .past:
                Button {
                    confirmWorn(dayIndex: dayIndex)
                } label: {
                    Label(String(localized: "planner_confirm_worn"), systemImage: "checkmark.seal")
                }
            }
            Toggle(isOn: Binding(
                get: { boardState.days[dayIndex].useEveningLook },
                set: { newValue in
                    boardState.days[dayIndex].useEveningLook = newValue
                    if newValue {
                        generateEveningOutfit(for: dayIndex)
                    } else {
                        clearEveningOutfit(for: dayIndex)
                    }
                    persistDayPlan(dayIndex)
                }
            )) {
                Label(String(localized: "planner_evening_look"), systemImage: "moon.stars")
            }
            Button {
                boardState.clearDay(dayIndex)
            } label: {
                Label(String(localized: "planner_clear_day"), systemImage: "xmark")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(6)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.6)
                        .blendMode(.plusLighter)
                )
        }
    }

    private func dayActionPill(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, 6)
                .foregroundStyle(tint)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(tint.opacity(0.35), lineWidth: 0.6)
                        .blendMode(.plusLighter)
                )
        }
        .buttonStyle(.plain)
    }

    private func dayCardActions(for dayIndex: Int) -> some View {
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Spacing.xs) {
                confirmActionPill(dayIndex: dayIndex)
                refreshActionPill(dayIndex: dayIndex)
                Spacer()
                recommendationsActionPill(dayIndex: dayIndex)
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.xs) {
                    confirmActionPill(dayIndex: dayIndex)
                    refreshActionPill(dayIndex: dayIndex)
                }
                HStack(spacing: DS.Spacing.xs) {
                    recommendationsActionPill(dayIndex: dayIndex)
                }
            }
        }
        .padding(.top, DS.Spacing.xxs)
    }

    @ViewBuilder
    private func confirmActionPill(dayIndex: Int) -> some View {
        let confirmed = isConfirmed(dayIndex)
        switch dayTiming(for: dayIndex) {
        case .future:
            compactActionPill(
                title: String(localized: "planner_confirm_plan"),
                systemImage: "checkmark.seal",
                tint: Color.accentColor
            ) {
                confirmPlan(dayIndex: dayIndex)
            }
        case .today, .past:
            compactActionPill(
                title: String(localized: confirmed ? "planner_undo_confirm" : "planner_confirm_worn"),
                systemImage: confirmed ? "arrow.uturn.left" : "checkmark.seal",
                tint: Color.accentColor
            ) {
                if confirmed {
                    unconfirmDay(dayIndex: dayIndex)
                } else {
                    confirmWorn(dayIndex: dayIndex)
                }
            }
        }
    }

    private func refreshActionPill(dayIndex: Int) -> some View {
        compactActionPill(
            title: String(localized: "planner_refresh_day"),
            systemImage: "arrow.clockwise",
            tint: .secondary
        ) {
            refreshDay(dayIndex)
        }
    }

    private func recommendationsActionPill(dayIndex: Int) -> some View {
        let expanded = isDetailsExpanded(dayIndex)
        return compactActionPill(
            title: String(localized: expanded ? "planner_hide_recommendations" : "planner_show_recommendations"),
            systemImage: expanded ? "chevron.down" : "sparkles",
            tint: .primary
        ) {
            toggleDayDetails(dayIndex)
        }
    }

    private func compactActionPill(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, 6)
                .foregroundStyle(tint)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(DS.Border.subtle, lineWidth: 0.6)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .buttonStyle(.plain)
    }

    private var bottomActionBar: some View {
        AnyView(EmptyView())
    }

    private enum DayTiming {
        case past
        case today
        case future
    }

    private func dayTiming(for dayIndex: Int) -> DayTiming {
        let day = boardState.days[dayIndex].date
        let start = Calendar.current.startOfDay(for: day)
        let today = Calendar.current.startOfDay(for: Date())
        if start == today { return .today }
        return start < today ? .past : .future
    }

    private func dayHeaderLine(for state: PlannerDayState) -> String {
        let dayLabel = dayName(for: state.id)
        let dateText = formattedDate(state.date)
        
        guard let forecast = state.forecast else {
            return String(format: NSLocalizedString("planner_day_header_no_forecast_format", comment: ""), dayLabel, dateText)
        }
        
        let location = weather.locationName?.isEmpty == false
            ? weather.locationName!
            : String(localized: "location_unavailable")
        
        return String(
            format: NSLocalizedString("planner_day_header_format", comment: ""),
            dayLabel,
            dateText,
            forecast.condition.description,
            Int(forecast.lowTempC),
            Int(forecast.highTempC),
            location
        )
    }

    private func isDetailsExpanded(_ dayIndex: Int) -> Bool {
        expandedDayDetails.contains(dayIndex)
    }

    private func toggleDayDetails(_ dayIndex: Int) {
        selectedDayIndex = dayIndex
        if expandedDayDetails.contains(dayIndex) {
            expandedDayDetails.remove(dayIndex)
        } else {
            expandedDayDetails.insert(dayIndex)
        }
    }

    private func dayDetailsSection(for dayIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            weatherRecommendationsSection(for: dayIndex)
        }
        .padding(.top, DS.Spacing.xxs)
    }

    
    
    @ViewBuilder
    private func weatherRecommendationsSection(for dayIndex: Int) -> some View {
        if dayIndex < boardState.days.count, let forecast = boardState.days[dayIndex].forecast {
            let profile = DayTemperatureProfile(from: forecast)
            let tempRange = "\(Int(profile.lowTemp))°–\(Int(profile.highTemp))°"
            let summary = "\(forecast.condition.description) • \(tempRange)"
            let layeringText = profile.layeringRecommended
                ? String(localized: "planner_reco_layering_yes")
                : String(localized: "planner_reco_layering_no")
            let guidance = recommendationGuidance(for: profile)

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(String(localized: "planner_recommendations_title"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                Text(layeringText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(guidance)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, DS.Spacing.xxs)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func forecastChip(for dayIndex: Int) -> some View {
        if dayIndex < boardState.days.count, let forecast = boardState.days[dayIndex].forecast {
            let tempRange = "\(Int(forecast.lowTempC))°–\(Int(forecast.highTempC))°"
            let summary = "\(forecast.condition.description) · \(tempRange)"
            HStack(spacing: DS.Spacing.xxs) {
                Image(systemName: forecast.condition.icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(weatherIconColor(for: forecast.condition))
                Text(summary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(DS.Border.subtle, lineWidth: 0.6)
            )
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func recommendationPreview(for dayIndex: Int) -> some View {
        if dayIndex < boardState.days.count, let forecast = boardState.days[dayIndex].forecast {
            let profile = DayTemperatureProfile(from: forecast)
            let guidance = recommendationGuidance(for: profile)
            HStack(spacing: DS.Spacing.xxs) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(guidance)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.top, DS.Spacing.xxs)
        } else {
            EmptyView()
        }
    }

    private func recommendationGuidance(for profile: DayTemperatureProfile) -> String {
        if profile.eveningJacketRecommended {
            return String(localized: "planner_reco_guidance_evening_jacket")
        }
        if profile.rainProbability > 0.35 {
            return String(localized: "planner_reco_guidance_rain")
        }
        return profile.smartHints.first?.text ?? String(localized: "planner_weather_default_hint")
    }

    private func compactHintChip(_ hint: PlannerHint) -> some View {
        HStack(spacing: DS.Spacing.xxs) {
            Image(systemName: hint.iconName)
                .font(.caption2)
                .foregroundStyle(hintTintColor(for: hint.style))
            Text(hint.text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, DS.Spacing.xs)
        .padding(.vertical, DS.Spacing.xxs)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                .blendMode(.plusLighter)
        )
    }

    private func detailHintRow(_ hint: PlannerHint) -> some View {
        HStack(spacing: DS.Spacing.xxs) {
            Image(systemName: hint.iconName)
                .font(.caption2)
                .foregroundStyle(hintTintColor(for: hint.style))
            Text(hint.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func smartHintsView(hints: [PlannerHint]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                ForEach(hints.prefix(3)) { hint in
                    HStack(spacing: DS.Spacing.xxs) {
                        Image(systemName: hint.iconName)
                            .font(.caption2)
                            .foregroundStyle(hintTintColor(for: hint.style))
                        Text(hint.text)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, DS.Spacing.xs)
                    .padding(.vertical, DS.Spacing.xxs)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                            .blendMode(.plusLighter)
                    )
                }
            }
        }
    }

    private func combinedHints(for dayIndex: Int) -> [PlannerHint] {
        guard dayIndex < boardState.days.count else { return [] }
        let state = boardState.days[dayIndex]
        var hints: [PlannerHint] = []

        if let forecast = state.forecast {
            hints.append(contentsOf: DayTemperatureProfile(from: forecast).smartHints)
        }

        hints.append(contentsOf: fitComfortHints(for: state, dayIndex: dayIndex))
        return hints
    }

    private func fitComfortHints(for state: PlannerDayState, dayIndex: Int) -> [PlannerHint] {
        let temp = state.effectiveTemperature
        let garments = state.assignedGarmentIDs.compactMap { id in
            allGarments.first { $0.id == id }
        }

        let hasTightFit = garments.contains { $0.fitTag == .skinny || $0.fitTag == .slim }
        let hasOversized = garments.contains { $0.fitTag == .oversized }

        var hints: [PlannerHint] = []
        if temp < 12, hasTightFit {
            hints.append(
                PlannerHint(
                    text: String(localized: "hint_fit_tight_cold"),
                    iconName: "thermometer.snowflake",
                    style: .temp
                )
            )
        }
        if temp > 28, hasOversized {
            hints.append(
                PlannerHint(
                    text: String(localized: "hint_fit_oversized_hot"),
                    iconName: "thermometer.sun",
                    style: .temp
                )
            )
        }

        return hints
    }

    private func hintTintColor(for style: PlannerHint.Style) -> Color {
        switch style {
        case .info:
            return .yellow
        case .temp:
            return .orange
        case .rain:
            return .blue
        }
    }

    private func inspirationLine(for dayIndex: Int) -> String? {
        guard dayIndex < boardState.days.count else { return nil }
        let day = boardState.days[dayIndex]
        let garments = day.assignedGarmentIDs.compactMap { id in
            allGarments.first { $0.id == id }
        }

        if garments.contains(where: { $0.isFavorite }) {
            return String(localized: "inspire_favorites")
        }

        if let forecast = day.forecast,
           DayTemperatureProfile(from: forecast).eveningJacketRecommended {
            return String(localized: "inspire_evening_jacket")
        }

        if let color = garments.compactMap({ $0.safeColorTags.first?.title }).first {
            return String(format: NSLocalizedString("inspire_color", comment: ""), color)
        }

        return nil
    }
    
    // MARK: - Outfit Row (Compact)
    
    private func outfitRow(for dayIndex: Int, lookTime: LookTime) -> some View {
        let order: [OutfitSlot] = [.shoes, .bottom, .top, .outer, .accessory]
        let slotsToShow = order.filter { slot in
            if slot == .outer {
                return shouldShowSlot(slot, dayIndex: dayIndex, lookTime: lookTime)
            }
            return true
        }
        
        let day = boardState.days[dayIndex]
        let assignedSlots = slotsToShow.filter { slot in
            let isLinked = lookTime == .evening && isEveningLinked(dayIndex: dayIndex, slot: slot)
            if isLinked {
                return day.garmentID(for: slot) != nil
            } else if lookTime == .evening {
                return day.eveningGarmentID(for: slot) != nil
            } else {
                return day.garmentID(for: slot) != nil
            }
        }
        let canAdd = !availableSlots(for: dayIndex, lookTime: lookTime).isEmpty
        let rowItemCount = assignedSlots.count + (canAdd ? 1 : 0)
        let thumbnailSize: DSGarmentThumbnail.ThumbnailSize = rowItemCount >= 5 ? .small : .medium

        return HStack(spacing: DS.Spacing.xs) {
            ForEach(assignedSlots, id: \.self) { slot in
                let isLinked = lookTime == .evening && isEveningLinked(dayIndex: dayIndex, slot: slot)
                let id: UUID? = {
                    if isLinked {
                        return day.garmentID(for: slot)
                    } else if lookTime == .evening {
                        return day.eveningGarmentID(for: slot)
                    } else {
                        return day.garmentID(for: slot)
                    }
                }()

                Group {
                    if let id, let garment = allGarments.first(where: { $0.id == id }) {
                        let isLocked = isLinked || (lookTime == .day ? day.isLocked(slot) : day.isEveningLocked(slot))
                        draggableGarmentTile(
                            garment: garment,
                            slot: slot,
                            dayIndex: dayIndex,
                            lookTime: lookTime,
                            isLocked: isLocked,
                            isLinked: isLinked,
                            thumbnailSize: thumbnailSize
                        )
                    }
                }
            }

            if canAdd {
                addItemsButton(
                    dayIndex: dayIndex,
                    lookTime: lookTime,
                    thumbnailSize: thumbnailSize
                )
            }
        }
    }

    private func addItemsButton(
        dayIndex: Int,
        lookTime: LookTime,
        thumbnailSize: DSGarmentThumbnail.ThumbnailSize
    ) -> some View {
        let dimension = thumbnailSize.dimension
        let iconSize = thumbnailSize.iconSize
        return Button {
            openAddPicker(dayIndex: dayIndex, lookTime: lookTime)
        } label: {
            RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                        .strokeBorder(DS.Border.subtle, lineWidth: 0.8)
                )
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                )
                .frame(width: dimension, height: dimension)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "planner_add_new_item"))
    }

    @ViewBuilder
    private func lockLinkBadge(isLocked: Bool, isLinked: Bool) -> some View {
        if isLocked || isLinked {
            HStack(spacing: 4) {
                if isLinked {
                    badgeIcon(systemName: "link")
                }
                if isLocked {
                    badgeIcon(systemName: "lock.fill")
                }
            }
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(DS.Border.subtle, lineWidth: 0.6)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 2, x: 0, y: 1)
            .padding(4)
        }
    }

    private func badgeIcon(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary.opacity(0.75))
    }

    @ViewBuilder
    private func availabilityBadge(status: AvailabilityStatus) -> some View {
        switch status {
        case .available:
            EmptyView()
        case .worn:
            availabilityBadgeView(text: String(localized: "planner_badge_worn"))
        case .unavailable:
            availabilityBadgeView(text: String(localized: "planner_badge_unavailable"))
        case .cooldown:
            availabilityBadgeView(text: String(localized: "planner_badge_cooldown"))
        }
    }

    private func availabilityBadgeView(text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(.secondary)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(DS.Border.subtle, lineWidth: 0.6)
            )
            .padding(4)
    }

    @ViewBuilder
    private func availabilityHintsView(for dayIndex: Int, lookTime: LookTime) -> some View {
        let hints = missingSlotHints(for: dayIndex, lookTime: lookTime)
        if !hints.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(hints, id: \.self) { hint in
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
        }
    }

    private func missingSlotHints(for dayIndex: Int, lookTime: LookTime) -> [String] {
        guard dayIndex < boardState.days.count else { return [] }
        var hints: [String] = []
        let slots = OutfitSlot.allCases.filter { slot in
            slot != .outer || shouldShowSlot(slot, dayIndex: dayIndex, lookTime: lookTime)
        }
        for slot in slots {
            if currentGarmentID(for: slot, dayIndex: dayIndex, lookTime: lookTime) == nil {
                if recommendedItemsForSlot(slot, dayIndex: dayIndex, lookTime: lookTime).isEmpty {
                    let slotName = slot.title.lowercased()
                    let hint = String(
                        format: NSLocalizedString("planner_no_available_slot_format", comment: ""),
                        slotName
                    )
                    hints.append(hint)
                }
            }
        }
        return hints
    }

    private func eveningSection(for dayIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(String(localized: "planner_evening_look"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            outfitRow(for: dayIndex, lookTime: .evening)
            availabilityHintsView(for: dayIndex, lookTime: .evening)
        }
    }

    private func shouldShowSlot(_ slot: OutfitSlot, dayIndex: Int, lookTime: LookTime) -> Bool {
        guard dayIndex < boardState.days.count else { return false }
        if slot != .outer {
            return true
        }

        let state = boardState.days[dayIndex]
        if lookTime == .evening {
            if state.eveningGarmentID(for: .outer) != nil {
                return true
            }
        } else if state.garmentID(for: .outer) != nil {
            return true
        }

        if let forecast = state.forecast {
            let profile = DayTemperatureProfile(from: forecast)
            if lookTime == .evening {
                return profile.eveningJacketRecommended || profile.layeringRecommended || profile.rainProbability > 0.35
            }
            return profile.layeringRecommended || profile.rainProbability > 0.35
        }

        return (lookTime == .evening ? state.effectiveTemperature - 2 : state.effectiveTemperature) < 15
    }
    
    // MARK: - Draggable Garment Tile
    
    @ViewBuilder
    private func draggableGarmentTile(
        garment: Garment,
        slot: OutfitSlot,
        dayIndex: Int,
        lookTime: LookTime,
        isLocked: Bool,
        isLinked: Bool,
        thumbnailSize: DSGarmentThumbnail.ThumbnailSize
    ) -> some View {
        let day = boardState.days[dayIndex]
        let status = availabilityStatus(for: garment, dayIndex: dayIndex, lookTime: lookTime)
        let isDimmed = !AvailabilityService.isRecommendedEligible(status)
        let canDrag = !isLocked && !isLinked
        let baseTile = ZStack(alignment: .topTrailing) {
            DSGarmentThumbnail(garment, size: thumbnailSize)
                .opacity(isDimmed ? 0.6 : 1.0)

        }
        let dropTarget = baseTile
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                    .strokeBorder(
                        isLocked ? DS.Accent.warmth.opacity(0.22) : .clear,
                        lineWidth: 1
                    )
                    .shadow(color: isLocked ? DS.Accent.warmth.opacity(0.1) : .clear, radius: 4)
            )
            .overlay(alignment: .topLeading) {
                availabilityBadge(status: status)
            }
            .overlay(alignment: .topTrailing) {
                lockLinkBadge(isLocked: isLocked, isLinked: isLinked)
            }
            .onDrop(of: [UTType.garmentDragItem], isTargeted: Binding(
                get: { isTargetHighlighted(dayIndex: dayIndex, slot: slot, lookTime: lookTime) },
                set: { updateTargeted($0, dayIndex: dayIndex, slot: slot, lookTime: lookTime) }
            )) { providers in
                return handleDrop(providers: providers, targetDay: dayIndex, targetSlot: slot, lookTime: lookTime)
            }
            .onTapGesture {
                DS.haptic(0.3)
                activeSheet = .garmentMenu(garment)
            }
            .contextMenu {
                slotContextMenu(
                    garment: garment,
                    slot: slot,
                    dayIndex: dayIndex,
                    lookTime: lookTime,
                    isLocked: isLocked,
                    isLinked: isLinked,
                    day: day
                )
            }
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                    .strokeBorder(
                        targetHighlightColor(dayIndex: dayIndex, slot: slot, lookTime: lookTime),
                        lineWidth: targetHighlightLineWidth(dayIndex: dayIndex, slot: slot, lookTime: lookTime)
                    )
            )

        if canDrag {
            dropTarget
                .onDrag {
                    let dragItem = GarmentDragItem(
                        garmentID: garment.id,
                        sourceDayIndex: dayIndex,
                        sourceSlot: slot,
                        lookTime: lookTime
                    )
                    boardState.draggedItem = dragItem
                    return makeItemProvider(for: dragItem)
                }
        } else {
            dropTarget
        }
    }

    @ViewBuilder
    private func slotContextMenu(
        garment: Garment,
        slot: OutfitSlot,
        dayIndex: Int,
        lookTime: LookTime,
        isLocked: Bool,
        isLinked: Bool,
        day: PlannerDayState
    ) -> some View {
        Group {
            if !isLinked {
                if isLocked {
                    Button {
                        if lookTime == .day {
                            toggleLock(dayIndex: dayIndex, slot: slot)
                        } else {
                            toggleEveningLock(dayIndex: dayIndex, slot: slot)
                        }
                    } label: {
                        Label(String(localized: "planner_unlock_item"), systemImage: "lock.open")
                    }
                } else {
                    Button {
                        if lookTime == .day {
                            toggleLock(dayIndex: dayIndex, slot: slot)
                        } else {
                            toggleEveningLock(dayIndex: dayIndex, slot: slot)
                        }
                    } label: {
                        Label(String(localized: "planner_lock_item"), systemImage: "lock")
                    }
                }
            }
        }

        Group {
            if lookTime == .evening, let dayID = day.garmentID(for: slot) {
                if isEveningLinked(dayIndex: dayIndex, slot: slot) {
                    Button {
                        toggleEveningLink(dayIndex: dayIndex, slot: slot, enable: false)
                    } label: {
                        Label(String(localized: "planner_evening_unlink_day"), systemImage: "link.badge.minus")
                    }
                } else if dayID != garment.id {
                    Button {
                        toggleEveningLink(dayIndex: dayIndex, slot: slot, enable: true)
                    } label: {
                        Label(String(localized: "planner_evening_link_day"), systemImage: "link")
                    }
                }
            }
        }

        Group {
            if !isLocked {
                Button {
                    openAddPicker(dayIndex: dayIndex, lookTime: lookTime, preferredSlot: slot)
                } label: {
                    Label(String(localized: "planner_replace_single_item"), systemImage: "arrow.triangle.2.circlepath")
                }

                Button {
                    openAddNewItem(dayIndex: dayIndex, slot: slot, lookTime: lookTime)
                } label: {
                    Label(String(localized: "planner_add_new_item"), systemImage: "plus")
                }
            }
        }

        Group {
            if slot == .outer {
                Button(role: .destructive) {
                    removeGarmentSlot(dayIndex: dayIndex, slot: slot, lookTime: lookTime)
                } label: {
                    Label(String(localized: "planner_remove_outerwear"), systemImage: "xmark.circle")
                }
            }
        }

        Group {
            if garment.isCurrentlyUnavailable {
                Button {
                    markAvailable(garment)
                } label: {
                    Label(String(localized: "planner_mark_available_now"), systemImage: "checkmark.circle")
                }
            } else {
                Button(role: .destructive) {
                    markUnavailable(garment)
                } label: {
                    Label(String(localized: "planner_mark_unavailable_now"), systemImage: "xmark.circle")
                }
            }
        }

        Group {
            Button {
                activeSheet = .garmentMenu(garment)
            } label: {
                Label(String(localized: "planner_go_to_item"), systemImage: "info.circle")
            }

            Button {} label: {
                Label(lastWornText(for: garment), systemImage: "clock")
            }
            .disabled(true)
        }
    }
    
    // MARK: - Empty Slot Target
    
    private func emptySlotTarget(slot: OutfitSlot, dayIndex: Int, lookTime: LookTime) -> some View {
        let isLocked = lookTime == .day
            ? boardState.days[dayIndex].isLocked(slot)
            : boardState.days[dayIndex].isEveningLocked(slot)
        let isLinked = lookTime == .evening && isEveningLinked(dayIndex: dayIndex, slot: slot)
        return RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
            .foregroundStyle(Color.secondary.opacity(0.3))
            .frame(width: 70, height: 70)
            .overlay {
                if isTargetHighlighted(dayIndex: dayIndex, slot: slot, lookTime: lookTime) {
                    Text(String(localized: "planner_drop_here"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .topTrailing) {
                lockLinkBadge(isLocked: isLocked, isLinked: isLinked)
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
            .onTapGesture {
                if !isLocked && !isLinked {
                    openAddPicker(dayIndex: dayIndex, lookTime: lookTime)
                }
            }
            .onDrop(of: [UTType.garmentDragItem], isTargeted: Binding(
                get: { isTargetHighlighted(dayIndex: dayIndex, slot: slot, lookTime: lookTime) },
                set: { updateTargeted($0, dayIndex: dayIndex, slot: slot, lookTime: lookTime) }
            )) { providers in
                if isLocked || isLinked { return false }
                return handleDrop(providers: providers, targetDay: dayIndex, targetSlot: slot, lookTime: lookTime)
            }
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                    .strokeBorder(
                        targetHighlightColor(dayIndex: dayIndex, slot: slot, lookTime: lookTime),
                        lineWidth: targetHighlightLineWidth(dayIndex: dayIndex, slot: slot, lookTime: lookTime)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                    .strokeBorder(
                        isLocked ? DS.Accent.warmth.opacity(0.22) : .clear,
                        lineWidth: 1
                    )
                    .shadow(color: isLocked ? DS.Accent.warmth.opacity(0.1) : .clear, radius: 4)
            )
            .contextMenu {
                Group {
                    if isLocked {
                        Button {
                            if lookTime == .day {
                                toggleLock(dayIndex: dayIndex, slot: slot)
                            } else {
                                toggleEveningLock(dayIndex: dayIndex, slot: slot)
                            }
                        } label: {
                            Label(String(localized: "planner_unlock_item"), systemImage: "lock.open")
                        }
                    } else {
                        Button {
                            if lookTime == .day {
                                toggleLock(dayIndex: dayIndex, slot: slot)
                            } else {
                                toggleEveningLock(dayIndex: dayIndex, slot: slot)
                            }
                        } label: {
                            Label(String(localized: "planner_lock_item"), systemImage: "lock")
                        }
                    }
                }

                Group {
                    if lookTime == .evening,
                       boardState.days[dayIndex].garmentID(for: slot) != nil {
                        if isEveningLinked(dayIndex: dayIndex, slot: slot) {
                            Button {
                                toggleEveningLink(dayIndex: dayIndex, slot: slot, enable: false)
                            } label: {
                                Label(String(localized: "planner_evening_unlink_day"), systemImage: "link.badge.minus")
                            }
                        } else {
                            Button {
                                toggleEveningLink(dayIndex: dayIndex, slot: slot, enable: true)
                            } label: {
                                Label(String(localized: "planner_evening_link_day"), systemImage: "link")
                            }
                        }
                    }
                }
            }
    }

    private func addItemButton(dayIndex: Int, lookTime: LookTime) -> some View {
        Button {
            openAddPicker(dayIndex: dayIndex, lookTime: lookTime)
        } label: {
            Image(systemName: "plus")
                .font(.caption.weight(.semibold))
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.6)
                        .blendMode(.plusLighter)
                )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Day Actions
    
    private func dayActions(for dayIndex: Int) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Button {
                DS.haptic(0.4)
                refreshDay(dayIndex)
            } label: {
                Label(String(localized: "planner_refresh_day"), systemImage: "arrow.clockwise")
                    .font(.caption.weight(.medium))
            }
            .dsSecondaryButton()
            
            Button {
                DS.haptic(0.3)
                boardState.clearDay(dayIndex)
            } label: {
                Label(String(localized: "planner_clear_day"), systemImage: "xmark")
                    .font(.caption.weight(.medium))
            }
            .dsSecondaryButton()
        }
    }
    
    // MARK: - Feedback Section
    
    private func feedbackSection(for dayIndex: Int) -> some View {
        let state = boardState.days[dayIndex]
        
        return VStack(spacing: DS.Spacing.xs) {
            Text(String(localized: "planner_what_do_you_think"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            
            HStack(spacing: DS.Spacing.xs) {
                FeedbackButton(
                    label: String(localized: "planner_wear_this"),
                    icon: "checkmark.seal.fill",
                    color: .green,
                    isSelected: state.feedback == .worn
                ) {
                    submitFeedback(for: dayIndex, rating: .worn)
                }
                
                FeedbackButton(
                    label: String(localized: "planner_love_it"),
                    icon: "heart.fill",
                    color: .pink,
                    isSelected: state.feedback == .loved
                ) {
                    submitFeedback(for: dayIndex, rating: .loved)
                }
                
                FeedbackButton(
                    label: String(localized: "planner_skip"),
                    icon: "arrow.clockwise",
                    color: .orange,
                    isSelected: state.feedback == .rejected
                ) {
                    submitFeedback(for: dayIndex, rating: .rejected)
                }
            }
        }
        .padding(DS.Spacing.sm)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
                .blendMode(.plusLighter)
        )
    }
    
    // MARK: - Drag & Drop
    
    private func makeItemProvider(for item: GarmentDragItem) -> NSItemProvider {
        let provider = NSItemProvider()
        if let data = try? JSONEncoder().encode(item) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.garmentDragItem.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }

    private func handleDrop(providers: [NSItemProvider], targetDay: Int, targetSlot: OutfitSlot, lookTime: LookTime) -> Bool {
        guard let provider = providers.first else {
            clearDragState()
            return false
        }

        let typeId = UTType.garmentDragItem.identifier
        guard provider.hasItemConformingToTypeIdentifier(typeId) else {
            clearDragState()
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: typeId) { data, _ in
            Task { @MainActor in
                guard let data,
                      let item = try? JSONDecoder().decode(GarmentDragItem.self, from: data) else {
                    clearDragState()
                    return
                }
                _ = handleDrop(items: [item], targetDay: targetDay, targetSlot: targetSlot, lookTime: lookTime)
            }
        }

        return true
    }

    private func handleDrop(items: [GarmentDragItem], targetDay: Int, targetSlot: OutfitSlot, lookTime: LookTime) -> Bool {
        guard let item = items.first else { return false }
        
        // Same slot type check
        guard item.sourceSlot == targetSlot else {
            DS.haptic(0.8)
            boardState.alertMessage = String(localized: "swap_error_different_slots")
            boardState.showUnavailableAlert = true
            clearDragState()
            return false
        }

        // Same position - no action needed
        if item.sourceDayIndex == targetDay && item.sourceSlot == targetSlot && item.lookTime == lookTime {
            clearDragState()
            return false
        }
        
        // Check if garment is available
        if let garment = allGarments.first(where: { $0.id == item.garmentID }),
           garment.isCurrentlyUnavailable {
            DS.haptic(0.8)
            boardState.alertMessage = String(localized: "assign_error_unavailable")
            boardState.showUnavailableAlert = true
            clearDragState()
            return false
        }

        // Check if either slot is locked or linked (day or evening)
        if (item.lookTime == .day && boardState.days[item.sourceDayIndex].isLocked(item.sourceSlot)) ||
            (item.lookTime == .evening && (boardState.days[item.sourceDayIndex].isEveningLocked(item.sourceSlot) ||
                                           isEveningLinked(dayIndex: item.sourceDayIndex, slot: item.sourceSlot))) ||
            (lookTime == .day && boardState.days[targetDay].isLocked(targetSlot)) ||
            (lookTime == .evening && (boardState.days[targetDay].isEveningLocked(targetSlot) ||
                                      isEveningLinked(dayIndex: targetDay, slot: targetSlot))) {
            DS.haptic(0.8)
            boardState.alertMessage = String(localized: "swap_error_locked")
            boardState.showUnavailableAlert = true
            clearDragState()
            return false
        }
        
        // Perform swap
        let success: Bool = withAnimation(DS.Animation.fast) {
            if item.lookTime != lookTime {
                return swapAcrossLooks(
                    fromDay: item.sourceDayIndex,
                    fromSlot: item.sourceSlot,
                    fromLook: item.lookTime,
                    toDay: targetDay,
                    toSlot: targetSlot,
                    toLook: lookTime
                )
            }
            if lookTime == .evening {
                return swapEveningGarments(
                    fromDay: item.sourceDayIndex,
                    fromSlot: item.sourceSlot,
                    toDay: targetDay,
                    toSlot: targetSlot
                )
            }
            return boardState.swapGarments(
                fromDay: item.sourceDayIndex,
                fromSlot: item.sourceSlot,
                toDay: targetDay,
                toSlot: targetSlot
            )
        }
        
        if success {
            DS.haptic(0.3)
            persistPlans(for: [item.sourceDayIndex, targetDay])
        } else {
            DS.haptic(0.8)
        }
        
        clearDragState()
        return success
    }

    private func swapEveningGarments(fromDay: Int, fromSlot: OutfitSlot, toDay: Int, toSlot: OutfitSlot) -> Bool {
        guard fromDay < boardState.days.count, toDay < boardState.days.count else { return false }
        guard fromSlot == toSlot else {
            boardState.alertMessage = String(localized: "swap_error_different_slots")
            boardState.showUnavailableAlert = true
            return false
        }

        if boardState.days[fromDay].isEveningLocked(fromSlot) || boardState.days[toDay].isEveningLocked(toSlot) {
            boardState.alertMessage = String(localized: "swap_error_locked")
            boardState.showUnavailableAlert = true
            return false
        }

        let fromID = boardState.days[fromDay].eveningGarmentID(for: fromSlot)
        let toID = boardState.days[toDay].eveningGarmentID(for: toSlot)

        if let fromID, isGarmentUsedOutside(fromID, excludingDays: [fromDay, toDay]) {
            boardState.alertMessage = String(localized: "swap_error_duplicate")
            boardState.showUnavailableAlert = true
            return false
        }
        if let toID, isGarmentUsedOutside(toID, excludingDays: [fromDay, toDay]) {
            boardState.alertMessage = String(localized: "swap_error_duplicate")
            boardState.showUnavailableAlert = true
            return false
        }

        boardState.days[fromDay].setEveningGarment(toID, for: fromSlot)
        boardState.days[toDay].setEveningGarment(fromID, for: toSlot)
        return true
    }

    private func swapAcrossLooks(
        fromDay: Int,
        fromSlot: OutfitSlot,
        fromLook: LookTime,
        toDay: Int,
        toSlot: OutfitSlot,
        toLook: LookTime
    ) -> Bool {
        guard fromDay < boardState.days.count, toDay < boardState.days.count else { return false }
        guard fromSlot == toSlot else {
            boardState.alertMessage = String(localized: "swap_error_different_slots")
            boardState.showUnavailableAlert = true
            return false
        }

        if (fromLook == .day && boardState.days[fromDay].isLocked(fromSlot)) ||
            (fromLook == .evening && boardState.days[fromDay].isEveningLocked(fromSlot)) ||
            (toLook == .day && boardState.days[toDay].isLocked(toSlot)) ||
            (toLook == .evening && boardState.days[toDay].isEveningLocked(toSlot)) {
            boardState.alertMessage = String(localized: "swap_error_locked")
            boardState.showUnavailableAlert = true
            return false
        }

        let fromID = garmentID(for: fromDay, slot: fromSlot, lookTime: fromLook)
        let toID = garmentID(for: toDay, slot: toSlot, lookTime: toLook)

        if let fromID, isGarmentUsedOutside(fromID, excludingDays: [fromDay, toDay]) {
            boardState.alertMessage = String(localized: "swap_error_duplicate")
            boardState.showUnavailableAlert = true
            return false
        }
        if let toID, isGarmentUsedOutside(toID, excludingDays: [fromDay, toDay]) {
            boardState.alertMessage = String(localized: "swap_error_duplicate")
            boardState.showUnavailableAlert = true
            return false
        }

        setGarmentID(toID, for: fromDay, slot: fromSlot, lookTime: fromLook)
        setGarmentID(fromID, for: toDay, slot: toSlot, lookTime: toLook)
        return true
    }

    private func garmentID(for dayIndex: Int, slot: OutfitSlot, lookTime: LookTime) -> UUID? {
        if lookTime == .evening {
            return boardState.days[dayIndex].eveningGarmentID(for: slot)
        }
        return boardState.days[dayIndex].garmentID(for: slot)
    }

    private func setGarmentID(_ id: UUID?, for dayIndex: Int, slot: OutfitSlot, lookTime: LookTime) {
        if lookTime == .evening {
            boardState.days[dayIndex].setEveningGarment(id, for: slot)
        } else {
            boardState.days[dayIndex].setGarment(id, for: slot)
        }
    }

    private func isGarmentUsedOutside(_ id: UUID, excludingDays: Set<Int>) -> Bool {
        for (index, day) in boardState.days.enumerated() where !excludingDays.contains(index) {
            if day.assignedGarmentIDs.contains(id) || day.eveningAssignedGarmentIDs.contains(id) {
                return true
            }
        }
        return false
    }
    
    // MARK: - Actions
    
    private func refreshDay(_ dayIndex: Int) {
        guard dayIndex < boardState.days.count else { return }
        let referenceDate = boardState.days[dayIndex].date
        let previousIDsBySlot: [OutfitSlot: UUID] = OutfitSlot.allCases.reduce(into: [:]) { result, slot in
            if let id = boardState.days[dayIndex].garmentID(for: slot) {
                result[slot] = id
            }
        }
        let currentUnlockedIDs = OutfitSlot.allCases.compactMap { slot -> UUID? in
            if boardState.days[dayIndex].isLocked(slot) { return nil }
            return boardState.days[dayIndex].garmentID(for: slot)
        }

        // Collect IDs used in other days (day + evening)
        var baseExcludedIDs = Set<UUID>()
        for (index, day) in boardState.days.enumerated() {
            if index != dayIndex {
                baseExcludedIDs.formUnion(day.assignedGarmentIDs)
                baseExcludedIDs.formUnion(day.eveningAssignedGarmentIDs)
            }
        }
        
        // Also exclude locked items in this day
        for slot in OutfitSlot.allCases {
            if boardState.days[dayIndex].isLocked(slot),
               let id = boardState.days[dayIndex].garmentID(for: slot) {
                baseExcludedIDs.insert(id)
            }
        }
        baseExcludedIDs.formUnion(currentUnlockedIDs)
        
        let ctx = recoContext(for: dayIndex)
        let cooldownExcludedIDs = buildCooldownExcludedIDs(
            referenceDate: referenceDate,
            ctx: ctx,
            baseExcludedIDs: baseExcludedIDs
        )
        let excludedMerged = baseExcludedIDs.union(cooldownExcludedIDs)
        let lockedCats = lockedCategories(for: dayIndex, lookTime: .day)
        let pool = recommendedPool(referenceDate: referenceDate, ctx: ctx)
            .filter { !lockedCats.contains($0.category) }
        
        let outfit = AIRecommender.shared.suggestOutfit(
            from: pool,
            ctx: ctx,
            modelContext: context,
            excludedIDs: excludedMerged
        )
        
        boardState.setOutfit(forDay: dayIndex, garments: outfit, overwriteExisting: true)
        var didChange = false
        for slot in OutfitSlot.allCases {
            if boardState.days[dayIndex].isLocked(slot) { continue }
            let previousID = previousIDsBySlot[slot]
            if boardState.days[dayIndex].garmentID(for: slot) == nil, let previousID {
                boardState.days[dayIndex].setGarment(previousID, for: slot)
            }
            let currentID = boardState.days[dayIndex].garmentID(for: slot)
            if currentID != previousID {
                didChange = true
            }
        }

        boardState.days[dayIndex].regenVersion += 1
        persistDayPlan(dayIndex)

        if !didChange {
            boardState.alertMessage = String(localized: "planner_no_alternatives")
            boardState.showUnavailableAlert = true
        }

        #if DEBUG
        logPlannerOutfit(
            dayIndex: dayIndex,
            isEvening: false,
            referenceDate: referenceDate,
            ctx: ctx,
            baseExcludedIDs: baseExcludedIDs,
            cooldownExcludedIDs: cooldownExcludedIDs,
            mergedExcludedIDs: excludedMerged
        )
        #endif

        if boardState.days[dayIndex].useEveningLook {
            generateEveningOutfit(for: dayIndex)
        }
    }

    private func openAddPicker(dayIndex: Int, lookTime: LookTime, preferredSlot: OutfitSlot? = nil) {
        var slots = availableSlots(for: dayIndex, lookTime: lookTime)
        if let preferredSlot, !slots.contains(preferredSlot) {
            slots.insert(preferredSlot, at: 0)
        }
        guard !slots.isEmpty else { return }
        activeSheet = .addPicker(dayIndex: dayIndex, slots: slots, lookTime: lookTime, initialSlot: preferredSlot)
    }

    private func openAddNewItem(dayIndex: Int, slot: OutfitSlot, lookTime: LookTime) {
        guard dayIndex < boardState.days.count else { return }
        if lookTime == .day, boardState.days[dayIndex].isLocked(slot) {
            boardState.alertMessage = String(localized: "swap_error_locked")
            boardState.showUnavailableAlert = true
            return
        }
        activeSheet = .addNewItem(dayIndex: dayIndex, slot: slot, lookTime: lookTime)
    }

    private func openAddNewItemForExisting(_ garment: Garment) {
        guard let assignment = findAssignment(for: garment.id) else { return }
        openAddNewItem(dayIndex: assignment.dayIndex, slot: assignment.slot, lookTime: .day)
    }

    private func availableSlots(for dayIndex: Int, lookTime: LookTime) -> [OutfitSlot] {
        guard dayIndex < boardState.days.count else { return [] }
        var slots: [OutfitSlot] = []

        let topID = currentGarmentID(for: .top, dayIndex: dayIndex, lookTime: lookTime)
        if topID == nil { slots.append(.top) }

        let bottomID = currentGarmentID(for: .bottom, dayIndex: dayIndex, lookTime: lookTime)
        if bottomID == nil { slots.append(.bottom) }

        let shoesID = currentGarmentID(for: .shoes, dayIndex: dayIndex, lookTime: lookTime)
        if shoesID == nil { slots.append(.shoes) }

        let outerID = currentGarmentID(for: .outer, dayIndex: dayIndex, lookTime: lookTime)
        if shouldShowSlot(.outer, dayIndex: dayIndex, lookTime: lookTime),
           outerID == nil {
            slots.append(.outer)
        }

        let accessoryID = currentGarmentID(for: .accessory, dayIndex: dayIndex, lookTime: lookTime)
        if accessoryID == nil {
            slots.append(.accessory)
        }

        return slots
    }

    private func currentGarmentID(for slot: OutfitSlot, dayIndex: Int, lookTime: LookTime) -> UUID? {
        guard dayIndex < boardState.days.count else { return nil }
        let day = boardState.days[dayIndex]
        if lookTime == .evening, isEveningLinked(dayIndex: dayIndex, slot: slot) {
            return day.garmentID(for: slot)
        }
        return lookTime == .evening ? day.eveningGarmentID(for: slot) : day.garmentID(for: slot)
    }

    private func availabilityStatus(for garment: Garment, dayIndex: Int, lookTime: LookTime) -> AvailabilityStatus {
        let referenceDate = boardState.days[dayIndex].date
        let ctx = recoContext(for: dayIndex, isEvening: lookTime == .evening)
        return AvailabilityService.availabilityStatus(
            for: garment,
            on: referenceDate,
            ctx: ctx,
            latestWearMap: latestWearByGarmentID
        )
    }

    private func slotCandidates(_ slot: OutfitSlot, dayIndex: Int, lookTime: LookTime) -> [Garment] {
        let allowed = slot.allowedCategories
        let currentID = currentGarmentID(for: slot, dayIndex: dayIndex, lookTime: lookTime)
        return allGarments.filter { garment in
            guard allowed.contains(garment.category) else { return false }
            if garment.id == currentID { return true }
            return !isGarmentUsedElsewhere(garment.id, excludingDay: dayIndex)
        }
    }

    private func recommendedItemsForSlot(_ slot: OutfitSlot, dayIndex: Int, lookTime: LookTime) -> [Garment] {
        let referenceDate = boardState.days[dayIndex].date
        let ctx = recoContext(for: dayIndex, isEvening: lookTime == .evening)
        let candidates = slotCandidates(slot, dayIndex: dayIndex, lookTime: lookTime)
        return AvailabilityService.recommendedItemsForSlot(
            slot,
            garments: candidates,
            date: referenceDate,
            ctx: ctx,
            latestWearMap: latestWearByGarmentID
        )
    }

    private func allItemsForSlot(_ slot: OutfitSlot, dayIndex: Int, lookTime: LookTime) -> [AvailabilityService.AvailabilityItem] {
        let referenceDate = boardState.days[dayIndex].date
        let ctx = recoContext(for: dayIndex, isEvening: lookTime == .evening)
        let candidates = slotCandidates(slot, dayIndex: dayIndex, lookTime: lookTime)
        return AvailabilityService.allItemsForSlot(
            slot,
            garments: candidates,
            date: referenceDate,
            ctx: ctx,
            latestWearMap: latestWearByGarmentID
        )
    }

    private func recommendedPool(referenceDate: Date, ctx: RecoContext) -> [Garment] {
        allGarments.filter { garment in
            let status = AvailabilityService.availabilityStatus(
                for: garment,
                on: referenceDate,
                ctx: ctx,
                latestWearMap: latestWearByGarmentID
            )
            return AvailabilityService.isRecommendedEligible(status)
        }
    }

    private func isGarmentUsedElsewhere(_ id: UUID, excludingDay dayIndex: Int) -> Bool {
        for (index, day) in boardState.days.enumerated() where index != dayIndex {
            if day.assignedGarmentIDs.contains(id) || day.eveningAssignedGarmentIDs.contains(id) {
                return true
            }
        }
        return false
    }

    private var preferredFormality: Int {
        let value = profiles.first?.preferredFormality ?? 3
        return min(max(value, 1), 4)
    }

    private func cooldownDays(for category: Category, ctx: RecoContext) -> Int {
        AvailabilityService.cooldownDays(for: category, ctx: ctx)
    }

    private func daysSinceWorn(_ garmentID: UUID, referenceDate: Date) -> Int? {
        AvailabilityService.daysSinceWorn(
            garmentID: garmentID,
            referenceDate: referenceDate,
            latestWearMap: latestWearByGarmentID
        )
    }

    private func buildCooldownExcludedIDs(
        referenceDate: Date,
        ctx: RecoContext,
        baseExcludedIDs: Set<UUID>
    ) -> Set<UUID> {
        var excluded = Set<UUID>()
        let categories: [Category] = [.top, .bottom, .shoes, .outer, .accessory]

        for category in categories {
            let cooldown = cooldownDays(for: category, ctx: ctx)
            guard cooldown > 0 else { continue }

            let pool = allGarments.filter { g in
                g.category == category && !baseExcludedIDs.contains(g.id)
            }

            var recentIDs = Set<UUID>()
            for g in pool {
                if let days = daysSinceWorn(g.id, referenceDate: referenceDate),
                   days < cooldown {
                    recentIDs.insert(g.id)
                }
            }

            if recentIDs.isEmpty { continue }
            excluded.formUnion(recentIDs)
        }

        return excluded
    }

    private func lockedCategories(for dayIndex: Int, lookTime: LookTime) -> Set<Category> {
        guard dayIndex < boardState.days.count else { return [] }
        let day = boardState.days[dayIndex]
        let lockedSlots = OutfitSlot.allCases.filter { slot in
            lookTime == .day ? day.isLocked(slot) : day.isEveningLocked(slot)
        }
        var categories = Set(lockedSlots.compactMap { $0.allowedCategories.first })
        if lookTime == .evening {
            for slot in day.eveningLinkedSlots {
                if let category = slot.allowedCategories.first {
                    categories.insert(category)
                }
            }
        }
        return categories
    }

    #if DEBUG
    private static let plannerLogDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func logPlannerOutfit(
        dayIndex: Int,
        isEvening: Bool,
        referenceDate: Date,
        ctx: RecoContext,
        baseExcludedIDs: Set<UUID>,
        cooldownExcludedIDs: Set<UUID>,
        mergedExcludedIDs: Set<UUID>
    ) {
        let dateString = Self.plannerLogDateFormatter.string(from: referenceDate)
        let selectedIDs = isEvening
            ? boardState.days[dayIndex].eveningAssignedGarmentIDs
            : boardState.days[dayIndex].assignedGarmentIDs

        print(
            "PLANNER_OUTFIT,date=\(dateString),isEvening=\(isEvening ? 1 : 0),excludedBaseCount=\(baseExcludedIDs.count),excludedCooldownCount=\(cooldownExcludedIDs.count),excludedMergedCount=\(mergedExcludedIDs.count),selectedCount=\(selectedIDs.count)"
        )

        for slot in OutfitSlot.allCases {
            let id = isEvening
                ? boardState.days[dayIndex].eveningGarmentID(for: slot)
                : boardState.days[dayIndex].garmentID(for: slot)
            guard let id, let garment = allGarments.first(where: { $0.id == id }) else { continue }

            let days = daysSinceWorn(garment.id, referenceDate: referenceDate)
            let daysString = days.map { String($0) } ?? "nil"
            let cooldown = cooldownDays(for: garment.category, ctx: ctx)
            let isInBase = baseExcludedIDs.contains(garment.id) ? 1 : 0
            let isInCooldown = cooldownExcludedIDs.contains(garment.id) ? 1 : 0
            let isInMerged = mergedExcludedIDs.contains(garment.id) ? 1 : 0
            let lastWornIsNil = latestWearByGarmentID[garment.id] == nil ? 1 : 0
            let isLocked = isEvening
                ? (boardState.days[dayIndex].isEveningLocked(slot) ? 1 : 0)
                : (boardState.days[dayIndex].isLocked(slot) ? 1 : 0)

            print(
                "PLANNER_PICK,id=\(id.uuidString),slot=\(slot.rawValue),category=\(garment.category.rawValue),daysSinceWorn=\(daysString),cooldownDays=\(cooldown),isInBaseExcluded=\(isInBase),isInCooldownExcluded=\(isInCooldown),isInMergedExcluded=\(isInMerged),lastWornIsNil=\(lastWornIsNil),isLocked=\(isLocked)"
            )
            if isInCooldown == 1 {
                print("COOLDOWN_BROKEN,id=\(id.uuidString),date=\(dateString),slot=\(slot.rawValue),category=\(garment.category.rawValue)")
            }
        }
    }
    #endif

    private func recoContext(for dayIndex: Int, isEvening: Bool = false) -> RecoContext {
        let state = boardState.days[dayIndex]
        let baseFormality = state.overrides.desiredFormality ?? preferredFormality
        let desiredFormality = isEvening ? min(baseFormality + 1, 4) : baseFormality

        let temperatureC: Double
        if isEvening, let forecast = state.forecast {
            temperatureC = DayTemperatureProfile(from: forecast).eveningTemp
        } else {
            temperatureC = state.effectiveTemperature
        }

        return RecoContext(
            desiredFormality: desiredFormality,
            temperatureC: temperatureC,
            isRaining: state.effectiveIsRaining,
            now: state.date
        )
    }

    @discardableResult
    private func assignGarment(
        _ garment: Garment,
        to slot: OutfitSlot,
        dayIndex: Int,
        lookTime: LookTime,
        allowUnavailable: Bool = false
    ) -> Bool {
        if !allowUnavailable {
            let status = availabilityStatus(for: garment, dayIndex: dayIndex, lookTime: lookTime)
            if !AvailabilityService.isRecommendedEligible(status) {
                boardState.alertMessage = availabilityAlertMessage(for: status)
                boardState.showUnavailableAlert = true
                return false
            }
        }

        let success: Bool
        if lookTime == .evening {
            success = assignEveningGarment(garment, to: slot, dayIndex: dayIndex, allowUnavailable: allowUnavailable)
        } else {
            success = boardState.assignGarment(
                garment.id,
                toDay: dayIndex,
                toSlot: slot,
                garments: allGarments,
                allowUnavailable: allowUnavailable
            )
        }
        if success {
            if lookTime == .day && isEveningLinked(dayIndex: dayIndex, slot: slot) {
                boardState.days[dayIndex].setEveningGarment(garment.id, for: slot, locked: true)
            }
            DS.haptic(0.3)
            persistAllPlans()
        } else {
            DS.haptic(0.8)
        }
        return success
    }

    private func assignEveningGarment(
        _ garment: Garment,
        to slot: OutfitSlot,
        dayIndex: Int,
        allowUnavailable: Bool
    ) -> Bool {
        guard dayIndex < boardState.days.count else { return false }
        if boardState.days[dayIndex].isEveningLocked(slot) || isEveningLinked(dayIndex: dayIndex, slot: slot) {
            boardState.alertMessage = String(localized: "swap_error_locked")
            boardState.showUnavailableAlert = true
            return false
        }
        if !allowUnavailable {
            let status = availabilityStatus(for: garment, dayIndex: dayIndex, lookTime: .evening)
            if !AvailabilityService.isRecommendedEligible(status) {
                boardState.alertMessage = availabilityAlertMessage(for: status)
                boardState.showUnavailableAlert = true
                return false
            }
        }
        if isGarmentUsedElsewhere(garment.id, excludingDay: dayIndex) {
            boardState.alertMessage = String(localized: "swap_error_duplicate")
            boardState.showUnavailableAlert = true
            return false
        }
        boardState.days[dayIndex].setEveningGarment(garment.id, for: slot)
        return true
    }

    private func availabilityAlertMessage(for status: AvailabilityStatus) -> String {
        switch status {
        case .unavailable:
            return String(localized: "assign_error_unavailable")
        case .worn:
            return String(localized: "planner_marked_worn")
        case .cooldown(let remaining):
            return String(format: NSLocalizedString("planner_in_cooldown_format", comment: ""), remaining)
        case .available:
            return String(localized: "assign_error_unavailable")
        }
    }

    private func toggleLock(dayIndex: Int, slot: OutfitSlot) {
        guard dayIndex < boardState.days.count else { return }
        let isLocked = boardState.days[dayIndex].isLocked(slot)
        let garmentID = boardState.days[dayIndex].garmentID(for: slot)
        boardState.days[dayIndex].setGarment(garmentID, for: slot, locked: !isLocked)
        persistDayPlan(dayIndex)
    }

    private func toggleEveningLock(dayIndex: Int, slot: OutfitSlot) {
        guard dayIndex < boardState.days.count else { return }
        let isLocked = boardState.days[dayIndex].isEveningLocked(slot)
        boardState.days[dayIndex].setEveningLock(slot, locked: !isLocked)
        persistDayPlan(dayIndex)
    }

    private func toggleEveningLink(dayIndex: Int, slot: OutfitSlot, enable: Bool) {
        guard dayIndex < boardState.days.count else { return }
        if enable {
            guard let dayID = boardState.days[dayIndex].garmentID(for: slot) else { return }
            boardState.days[dayIndex].eveningLinkedSlots.insert(slot)
            boardState.days[dayIndex].setEveningGarment(dayID, for: slot, locked: true)
        } else {
            boardState.days[dayIndex].eveningLinkedSlots.remove(slot)
            boardState.days[dayIndex].setEveningGarment(nil, for: slot, locked: false)
        }
        persistDayPlan(dayIndex)
    }

    private func isEveningLinked(dayIndex: Int, slot: OutfitSlot) -> Bool {
        guard dayIndex < boardState.days.count else { return false }
        return boardState.days[dayIndex].eveningLinkedSlots.contains(slot)
    }

    private func removeGarment(dayIndex: Int, slot: OutfitSlot) {
        guard dayIndex < boardState.days.count else { return }
        if boardState.days[dayIndex].isLocked(slot) {
            boardState.alertMessage = String(localized: "swap_error_locked")
            boardState.showUnavailableAlert = true
            return
        }
        if isEveningLinked(dayIndex: dayIndex, slot: slot) {
            boardState.days[dayIndex].eveningLinkedSlots.remove(slot)
            boardState.days[dayIndex].setEveningGarment(nil, for: slot, locked: false)
        }
        boardState.days[dayIndex].setGarment(nil, for: slot)
        persistDayPlan(dayIndex)
    }

    private func removeGarmentSlot(dayIndex: Int, slot: OutfitSlot, lookTime: LookTime) {
        guard dayIndex < boardState.days.count else { return }
        if lookTime == .day {
            removeGarment(dayIndex: dayIndex, slot: slot)
        } else {
            if boardState.days[dayIndex].isEveningLocked(slot) {
                boardState.alertMessage = String(localized: "swap_error_locked")
                boardState.showUnavailableAlert = true
                return
            }
            boardState.days[dayIndex].setEveningGarment(nil, for: slot)
            persistDayPlan(dayIndex)
        }
    }

    private func replaceSlot(dayIndex: Int, slot: OutfitSlot, lookTime: LookTime) {
        guard dayIndex < boardState.days.count else { return }
        if lookTime == .day, boardState.days[dayIndex].isLocked(slot) {
            boardState.alertMessage = String(localized: "swap_error_locked")
            boardState.showUnavailableAlert = true
            return
        }
        if lookTime == .evening, boardState.days[dayIndex].isEveningLocked(slot) {
            boardState.alertMessage = String(localized: "swap_error_locked")
            boardState.showUnavailableAlert = true
            return
        }
        if lookTime == .evening, isEveningLinked(dayIndex: dayIndex, slot: slot) {
            boardState.alertMessage = String(localized: "swap_error_locked")
            boardState.showUnavailableAlert = true
            return
        }

        let referenceDate = boardState.days[dayIndex].date
        let ctx = recoContext(for: dayIndex, isEvening: lookTime == .evening)
        let state = boardState.days[dayIndex]
        let currentID = lookTime == .evening ? state.eveningGarmentID(for: slot) : state.garmentID(for: slot)

        var baseExcludedIDs: Set<UUID> = []
        for (index, day) in boardState.days.enumerated() {
            if index != dayIndex {
                baseExcludedIDs.formUnion(day.assignedGarmentIDs)
                baseExcludedIDs.formUnion(day.eveningAssignedGarmentIDs)
            } else {
                baseExcludedIDs.formUnion(day.assignedGarmentIDs)
                baseExcludedIDs.formUnion(day.eveningAssignedGarmentIDs)
            }
        }
        if let currentID {
            baseExcludedIDs.remove(currentID)
        }

        let cooldownExcludedIDs = buildCooldownExcludedIDs(
            referenceDate: referenceDate,
            ctx: ctx,
            baseExcludedIDs: baseExcludedIDs
        )
        let excludedMerged = baseExcludedIDs.union(cooldownExcludedIDs)

        let pool = recommendedPool(referenceDate: referenceDate, ctx: ctx)
            .filter { slot.allowedCategories.contains($0.category) }
        let suggestions = AIRecommender.shared.suggest(
            from: pool,
            k: 1,
            ctx: ctx,
            modelContext: context,
            excludedIDs: excludedMerged
        )

        if let replacement = suggestions.first {
            if lookTime == .evening {
                boardState.days[dayIndex].setEveningGarment(replacement.id, for: slot)
            } else {
                boardState.days[dayIndex].setGarment(replacement.id, for: slot)
            }
            persistDayPlan(dayIndex)
            DS.haptic(0.3)
            #if DEBUG
            logPlannerOutfit(
                dayIndex: dayIndex,
                isEvening: lookTime == .evening,
                referenceDate: referenceDate,
                ctx: ctx,
                baseExcludedIDs: baseExcludedIDs,
                cooldownExcludedIDs: cooldownExcludedIDs,
                mergedExcludedIDs: excludedMerged
            )
            #endif
        } else {
            boardState.alertMessage = String(localized: "planner_no_replacement")
            boardState.showUnavailableAlert = true
            DS.haptic(0.8)
        }
    }

    private func findAssignment(for garmentID: UUID) -> (dayIndex: Int, slot: OutfitSlot)? {
        for (dayIndex, day) in boardState.days.enumerated() {
            for (slot, assignment) in day.slots where assignment.garmentID == garmentID {
                return (dayIndex, slot)
            }
        }
        return nil
    }
    
    private func generateAllOutfits(fillMissingOnly: Bool) {
        for i in 0..<boardState.days.count {
            let state = boardState.days[i]
            let ctx = recoContext(for: i)
            let referenceDate = state.date
            var baseExcludedIDs = Set<UUID>()
            for (index, day) in boardState.days.enumerated() {
                if index != i {
                    baseExcludedIDs.formUnion(day.assignedGarmentIDs)
                    baseExcludedIDs.formUnion(day.eveningAssignedGarmentIDs)
                }
            }
            let cooldownExcludedIDs = buildCooldownExcludedIDs(
                referenceDate: referenceDate,
                ctx: ctx,
                baseExcludedIDs: baseExcludedIDs
            )
            let excludedMerged = baseExcludedIDs.union(cooldownExcludedIDs)
            let lockedCats = lockedCategories(for: i, lookTime: .day)
            let pool = recommendedPool(referenceDate: referenceDate, ctx: ctx)
                .filter { !lockedCats.contains($0.category) }
            
            let outfit = AIRecommender.shared.suggestOutfit(
                from: pool,
                ctx: ctx,
                modelContext: context,
                excludedIDs: excludedMerged
            )
            
            boardState.setOutfit(forDay: i, garments: outfit, overwriteExisting: !fillMissingOnly)
            boardState.days[i].insufficientItemsWarning = boardState.days[i].assignedGarmentIDs.isEmpty && i > 0
            persistDayPlan(i)
            #if DEBUG
            logPlannerOutfit(
                dayIndex: i,
                isEvening: false,
                referenceDate: referenceDate,
                ctx: ctx,
                baseExcludedIDs: baseExcludedIDs,
                cooldownExcludedIDs: cooldownExcludedIDs,
                mergedExcludedIDs: excludedMerged
            )
            #endif
        }

        generateEveningOutfits(fillMissingOnly: fillMissingOnly)
    }

    private func generateEveningOutfit(for dayIndex: Int) {
        guard dayIndex < boardState.days.count else { return }
        guard boardState.days[dayIndex].useEveningLook else { return }

        let referenceDate = boardState.days[dayIndex].date
        let ctx = recoContext(for: dayIndex, isEvening: true)
        var baseExcludedIDs = Set(boardState.days.flatMap { $0.assignedGarmentIDs })
        baseExcludedIDs.formUnion(boardState.days.flatMap { $0.eveningAssignedGarmentIDs })
        if !boardState.days[dayIndex].eveningLinkedSlots.isEmpty {
            for slot in boardState.days[dayIndex].eveningLinkedSlots {
                if let dayID = boardState.days[dayIndex].garmentID(for: slot) {
                    baseExcludedIDs.remove(dayID)
                }
            }
        }

        let cooldownExcludedIDs = buildCooldownExcludedIDs(
            referenceDate: referenceDate,
            ctx: ctx,
            baseExcludedIDs: baseExcludedIDs
        )
        let excludedMerged = baseExcludedIDs.union(cooldownExcludedIDs)
        let lockedCats = lockedCategories(for: dayIndex, lookTime: .evening)
        let pool = recommendedPool(referenceDate: referenceDate, ctx: ctx)
            .filter { !lockedCats.contains($0.category) }
        let outfit = AIRecommender.shared.suggestOutfit(
            from: pool,
            ctx: ctx,
            modelContext: context,
            excludedIDs: excludedMerged
        )

        setEveningOutfit(forDay: dayIndex, garments: outfit)
        persistDayPlan(dayIndex)
        #if DEBUG
        logPlannerOutfit(
            dayIndex: dayIndex,
            isEvening: true,
            referenceDate: referenceDate,
            ctx: ctx,
            baseExcludedIDs: baseExcludedIDs,
            cooldownExcludedIDs: cooldownExcludedIDs,
            mergedExcludedIDs: excludedMerged
        )
        #endif
    }

    private func generateEveningOutfits(fillMissingOnly: Bool) {
        for i in 0..<boardState.days.count {
            guard boardState.days[i].useEveningLook else { continue }

            let currentEveningIDs = boardState.days[i].eveningAssignedGarmentIDs
            if fillMissingOnly, !currentEveningIDs.isEmpty {
                continue
            }

            let ctx = recoContext(for: i, isEvening: true)
            let referenceDate = boardState.days[i].date
            var baseExcludedIDs = Set<UUID>()
            for (index, day) in boardState.days.enumerated() {
                if index != i {
                    baseExcludedIDs.formUnion(day.assignedGarmentIDs)
                    baseExcludedIDs.formUnion(day.eveningAssignedGarmentIDs)
                } else {
                    baseExcludedIDs.formUnion(day.assignedGarmentIDs)
                    baseExcludedIDs.formUnion(day.eveningAssignedGarmentIDs)
                }
            }
            if !boardState.days[i].eveningLinkedSlots.isEmpty {
                for slot in boardState.days[i].eveningLinkedSlots {
                    if let dayID = boardState.days[i].garmentID(for: slot) {
                        baseExcludedIDs.remove(dayID)
                    }
                }
            }
            let cooldownExcludedIDs = buildCooldownExcludedIDs(
                referenceDate: referenceDate,
                ctx: ctx,
                baseExcludedIDs: baseExcludedIDs
            )
            let excludedMerged = baseExcludedIDs.union(cooldownExcludedIDs)
            let lockedCats = lockedCategories(for: i, lookTime: .evening)
            let pool = recommendedPool(referenceDate: referenceDate, ctx: ctx)
                .filter { !lockedCats.contains($0.category) }
            let outfit = AIRecommender.shared.suggestOutfit(
                from: pool,
                ctx: ctx,
                modelContext: context,
                excludedIDs: excludedMerged
            )

            setEveningOutfit(forDay: i, garments: outfit)
            persistDayPlan(i)
            #if DEBUG
            logPlannerOutfit(
                dayIndex: i,
                isEvening: true,
                referenceDate: referenceDate,
                ctx: ctx,
                baseExcludedIDs: baseExcludedIDs,
                cooldownExcludedIDs: cooldownExcludedIDs,
                mergedExcludedIDs: excludedMerged
            )
            #endif
        }
    }

    private func setEveningOutfit(forDay dayIndex: Int, garments: [Garment]) {
        guard dayIndex < boardState.days.count else { return }
        for slot in OutfitSlot.allCases {
            if !boardState.days[dayIndex].isEveningLocked(slot) &&
                !isEveningLinked(dayIndex: dayIndex, slot: slot) {
                boardState.days[dayIndex].setEveningGarment(nil, for: slot)
            }
        }
        for garment in garments {
            let slot = OutfitSlot.from(category: garment.category)
            if !boardState.days[dayIndex].isEveningLocked(slot),
               !isEveningLinked(dayIndex: dayIndex, slot: slot),
               boardState.days[dayIndex].eveningGarmentID(for: slot) == nil {
                boardState.days[dayIndex].setEveningGarment(garment.id, for: slot)
            }
        }
    }

    private func clearEveningOutfit(for dayIndex: Int) {
        guard dayIndex < boardState.days.count else { return }
        for slot in OutfitSlot.allCases {
            if !boardState.days[dayIndex].isEveningLocked(slot) &&
                !isEveningLinked(dayIndex: dayIndex, slot: slot) {
                boardState.days[dayIndex].setEveningGarment(nil, for: slot)
            }
        }
    }

    // MARK: - Planner Persistence

    private func hydrateFromPlans() {
        var usedIDs: Set<UUID> = []
        for dayIndex in 0..<boardState.days.count {
            let plan = DayPlanService.shared.planFor(date: boardState.days[dayIndex].date, context: context)
            applyPlan(plan, dayIndex: dayIndex, usedIDs: &usedIDs)
        }
    }

    private func applyPlan(_ plan: DayPlan, dayIndex: Int, usedIDs: inout Set<UUID>) {
        for slot in OutfitSlot.allCases {
            boardState.days[dayIndex].setGarment(nil, for: slot)
        }
        for slot in OutfitSlot.allCases {
            boardState.days[dayIndex].setEveningGarment(nil, for: slot)
        }

        boardState.days[dayIndex].useEveningLook = plan.eveningEnabled ?? false
        boardState.days[dayIndex].eveningUsesDayBottom = plan.eveningUsesDayBottom
        if !plan.eveningLinkedSlots.isEmpty {
            boardState.days[dayIndex].eveningLinkedSlots = plan.eveningLinkedSlots
        } else if plan.eveningUsesDayBottom {
            boardState.days[dayIndex].eveningLinkedSlots = [.bottom]
        } else {
            boardState.days[dayIndex].eveningLinkedSlots = []
        }

        let assignments = plan.slotAssignments
        if !assignments.isEmpty {
            let lockedSlots = plan.lockedSlots
            for slot in OutfitSlot.allCases {
                if let id = assignments[slot],
                   let garment = allGarments.first(where: { $0.id == id }),
                   !usedIDs.contains(garment.id) {
                    boardState.days[dayIndex].setGarment(garment.id, for: slot, locked: lockedSlots.contains(slot))
                    usedIDs.insert(garment.id)
                }
            }
        } else {
            var remainingIDs = plan.selectedGarmentIDs
            for slot in OutfitSlot.allCases {
                if let id = remainingIDs.first(where: { id in
                    guard let garment = allGarments.first(where: { $0.id == id }) else { return false }
                    return OutfitSlot.from(category: garment.category) == slot && !usedIDs.contains(id)
                }) {
                    boardState.days[dayIndex].setGarment(id, for: slot)
                    usedIDs.insert(id)
                    remainingIDs.removeAll { $0 == id }
                }
            }

            if !plan.lockedGarmentIDs.isEmpty {
                for slot in OutfitSlot.allCases {
                    if let id = boardState.days[dayIndex].garmentID(for: slot),
                       plan.lockedGarmentIDs.contains(id) {
                        boardState.days[dayIndex].setGarment(id, for: slot, locked: true)
                    }
                }
            }
        }

        let eveningAssignments = plan.eveningSlotAssignments
        if boardState.days[dayIndex].useEveningLook, !eveningAssignments.isEmpty {
            let eveningLockedSlots = plan.eveningLockedSlots
            for slot in OutfitSlot.allCases {
                if let id = eveningAssignments[slot],
                   let garment = allGarments.first(where: { $0.id == id }),
                   !usedIDs.contains(garment.id) {
                    boardState.days[dayIndex].setEveningGarment(
                        garment.id,
                        for: slot,
                        locked: eveningLockedSlots.contains(slot)
                    )
                    usedIDs.insert(garment.id)
                }
            }
        }
        if !boardState.days[dayIndex].eveningLinkedSlots.isEmpty {
            for slot in boardState.days[dayIndex].eveningLinkedSlots {
                if let dayID = boardState.days[dayIndex].garmentID(for: slot) {
                    boardState.days[dayIndex].setEveningGarment(dayID, for: slot, locked: true)
                }
            }
        }
    }

    /// Persist a day: debounced unless `immediate` (e.g. confirm worn/plan, or flush on background).
    private func persistDayPlan(_ dayIndex: Int, immediate: Bool = false) {
        guard dayIndex < boardState.days.count else { return }
        if immediate {
            persistDayPlanImmediate(dayIndex)
            dirtyDayIndices.remove(dayIndex)
            plannerSaveDebouncer.flush()
            return
        }
        dirtyDayIndices.insert(dayIndex)
        plannerSaveDebouncer.schedule {
            NotificationCenter.default.post(name: .plannerFlushDirtyPlans, object: nil)
        }
    }

    private func flushDirtyPlans() {
        for dayIndex in dirtyDayIndices {
            persistDayPlanImmediate(dayIndex)
        }
        dirtyDayIndices.removeAll()
        plannerSaveDebouncer.flush()
    }

    private func persistDayPlanImmediate(_ dayIndex: Int) {
        guard dayIndex < boardState.days.count else { return }
        let day = boardState.days[dayIndex]
        let plan = DayPlanService.shared.planFor(date: day.date, context: context)

        var assignments: [OutfitSlot: UUID?] = [:]
        var lockedSlots: Set<OutfitSlot> = []
        for slot in OutfitSlot.allCases {
            let id = day.garmentID(for: slot)
            assignments[slot] = id
            if day.isLocked(slot) {
                lockedSlots.insert(slot)
            }
        }

        plan.setSlotAssignments(assignments, lockedSlots: lockedSlots)
        plan.eveningEnabled = day.useEveningLook

        var eveningAssignments: [OutfitSlot: UUID?] = [:]
        var eveningLockedSlots: Set<OutfitSlot> = []
        for slot in OutfitSlot.allCases {
            eveningAssignments[slot] = day.eveningGarmentID(for: slot)
            if day.isEveningLocked(slot) {
                eveningLockedSlots.insert(slot)
            }
        }
        plan.setEveningSlotAssignments(eveningAssignments, lockedSlots: eveningLockedSlots)
        plan.setEveningLinkedSlots(day.eveningLinkedSlots)
        plan.eveningUsesDayBottom = day.eveningLinkedSlots.contains(.bottom)
        try? context.save()

        if Calendar.current.isDateInToday(day.date) {
            WidgetSnapshotService.saveTodaySnapshot(
                plan: plan,
                garments: allGarments,
                forecast: weather.forecasts.first,
                locationName: weather.locationName
            )
        }
    }

    private func persistPlans(for indices: [Int], immediate: Bool = false) {
        for index in indices {
            persistDayPlan(index, immediate: immediate)
        }
    }

    private func persistAllPlans() {
        persistPlans(for: Array(0..<boardState.days.count))
    }
    
    private func submitFeedback(for dayIndex: Int, rating: OutfitFeedbackRating) {
        DS.haptic(0.5)
        boardState.days[dayIndex].feedback = rating
        
        // Update garment love scores
        let garmentIDs = boardState.days[dayIndex].assignedGarmentIDs
        for garment in allGarments where garmentIDs.contains(garment.id) {
            let delta: Int
            switch rating {
            case .loved: delta = 5
            case .worn: delta = 2
            case .rejected: delta = -3
            case .neutral: delta = 0
            }
            garment.loveScore = max(0, min(100, garment.loveScore + delta))
        }
        
        try? context.save()
        
        if rating == .rejected {
            refreshDay(dayIndex)
        }
    }
    
    private func markUnavailable(_ garment: Garment) {
        DS.haptic(0.4)
        garment.markUnavailable()
        try? context.save()
        updateAvailableGarments()
        activeSheet = nil
    }

    private func markUnavailable(_ garment: Garment, days: Int) {
        DS.haptic(0.4)
        let until = Calendar.current.date(byAdding: .day, value: days, to: Date())
        garment.markUnavailable(until: until)
        try? context.save()
        updateAvailableGarments()
        activeSheet = nil
    }
    
    private func markAvailable(_ garment: Garment) {
        DS.haptic(0.4)
        garment.markAvailable()
        try? context.save()
        updateAvailableGarments()
        activeSheet = nil
    }
    
    private func replaceSingleItem(for garment: Garment) {
        guard let assignment = findAssignment(for: garment.id) else { return }
        openAddPicker(dayIndex: assignment.dayIndex, lookTime: .day, preferredSlot: assignment.slot)
        activeSheet = nil
    }

    private func markWornToday(_ garment: Garment) {
        DS.haptic(0.4)
        let date = Date()
        WearHistoryService.recordWorn(
            date: date,
            garmentIDs: [garment.id],
            source: .manual,
            context: context,
            incrementTimesWorn: true,
            loveScoreDelta: nil
        )
        activeSheet = nil
    }

    private func confirmWorn(dayIndex: Int) {
        guard dayIndex < boardState.days.count else { return }
        let date = boardState.days[dayIndex].date
        let garmentIDs = boardState.days[dayIndex].assignedGarmentIDs

        let plan = DayPlanService.shared.planFor(date: date, context: context)
        plan.wasWornConfirmed = true
        plan.updatedAt = Date()
        WearHistoryService.recordWorn(
            date: date,
            garmentIDs: garmentIDs,
            source: .planner,
            context: context,
            outfitID: plan.id,
            incrementTimesWorn: true,
            loveScoreDelta: 1
        )
        DS.haptic(0.4)

        if Calendar.current.isDateInToday(date) {
            WidgetSnapshotService.saveTodaySnapshot(
                plan: plan,
                garments: allGarments,
                forecast: weather.forecasts.first,
                locationName: weather.locationName
            )
        }
        persistDayPlan(dayIndex, immediate: true)
    }

    private func confirmPlan(dayIndex: Int) {
        guard dayIndex < boardState.days.count else { return }
        persistDayPlan(dayIndex, immediate: true)
        DS.haptic(0.3)
    }

    private func isConfirmed(_ dayIndex: Int) -> Bool {
        guard dayIndex < boardState.days.count else { return false }
        let date = boardState.days[dayIndex].date
        let events = WearEventStore.events(on: date, context: context)
        if events.contains(where: { $0.source == .planner }) {
            return true
        }
        return dayPlans.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) })?.wasWornConfirmed == true
    }

    private func unconfirmDay(dayIndex: Int) {
        guard dayIndex < boardState.days.count else { return }
        let date = boardState.days[dayIndex].date
        let plan = DayPlanService.shared.planFor(date: date, context: context)
        plan.wasWornConfirmed = false
        plan.updatedAt = Date()
        try? context.save()
        WearEventStore.unmarkWorn(date: date, source: .planner, context: context)
        DS.haptic(0.3)

        if Calendar.current.isDateInToday(date) {
            WidgetSnapshotService.saveTodaySnapshot(
                plan: plan,
                garments: allGarments,
                forecast: weather.forecasts.first,
                locationName: weather.locationName
            )
        }
    }

    private func garmentDetailsSection(for garment: Garment) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            garmentDetailRow(label: String(localized: "garment_detail_category"), value: garment.category.title)

            if let type = garment.itemType {
                garmentDetailRow(label: String(localized: "garment_detail_type"), value: type.title)
            }

            let colors = garment.safeColorTags.map { $0.title }.joined(separator: ", ")
            if !colors.isEmpty {
                garmentDetailRow(label: String(localized: "garment_detail_colors"), value: colors)
            }

            if let fit = garment.fitTag {
                garmentDetailRow(label: String(localized: "garment_detail_fit"), value: fit.title)
            }

            if let size = garment.sizeOption {
                garmentDetailRow(label: String(localized: "garment_detail_size"), value: size.title)
            }

            garmentDetailRow(
                label: String(localized: "garment_detail_warmth"),
                value: "\(garment.warmth)/5"
            )

            garmentDetailRow(
                label: String(localized: "garment_detail_formality"),
                value: "\(garment.formality)/5"
            )

            if let notes = garment.notes, !notes.isEmpty {
                garmentDetailRow(label: String(localized: "garment_detail_notes"), value: notes)
            }
        }
        .padding(DS.Spacing.sm)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    private func garmentDetailRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.xs) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    // MARK: - Slot Picker

    private struct PlannerAddPicker: View {
        let dayIndex: Int
        let availableSlots: [OutfitSlot]
        let initialSlot: OutfitSlot?
        let recommendedItemsForSlot: (OutfitSlot) -> [Garment]
        let allItemsForSlot: (OutfitSlot) -> [AvailabilityService.AvailabilityItem]
        let onSelect: (Garment, OutfitSlot, Bool) -> Void
        let onAddNewItem: (OutfitSlot) -> Void
        let onClose: () -> Void

        @State private var selectedSlot: OutfitSlot
        @State private var searchText = ""
        @State private var selectedSeasons: Set<SeasonSuitability> = []
        @State private var selectedColors: Set<ColorTag> = []
        @State private var pickerMode: PickerMode = .recommended
        @State private var pendingSelection: AvailabilityService.AvailabilityItem?
        @State private var showConfirm = false

        private enum PickerMode: String, CaseIterable {
            case recommended
            case all
        }

        init(
            dayIndex: Int,
            availableSlots: [OutfitSlot],
            initialSlot: OutfitSlot?,
            recommendedItemsForSlot: @escaping (OutfitSlot) -> [Garment],
            allItemsForSlot: @escaping (OutfitSlot) -> [AvailabilityService.AvailabilityItem],
            onSelect: @escaping (Garment, OutfitSlot, Bool) -> Void,
            onAddNewItem: @escaping (OutfitSlot) -> Void,
            onClose: @escaping () -> Void
        ) {
            self.dayIndex = dayIndex
            self.availableSlots = availableSlots
            self.initialSlot = initialSlot
            self.recommendedItemsForSlot = recommendedItemsForSlot
            self.allItemsForSlot = allItemsForSlot
            self.onSelect = onSelect
            self.onAddNewItem = onAddNewItem
            self.onClose = onClose
            let preferred = initialSlot.flatMap { slot in
                availableSlots.contains(slot) ? slot : nil
            }
            _selectedSlot = State(initialValue: preferred ?? availableSlots.first ?? .top)
        }

        private let columns = [GridItem(.adaptive(minimum: 90), spacing: DS.Spacing.sm)]

        private var filteredItems: [AvailabilityService.AvailabilityItem] {
            let baseItems: [AvailabilityService.AvailabilityItem]
            switch pickerMode {
            case .recommended:
                baseItems = recommendedItemsForSlot(selectedSlot).map {
                    AvailabilityService.AvailabilityItem(garment: $0, status: .available)
                }
            case .all:
                baseItems = allItemsForSlot(selectedSlot)
            }

            return baseItems.filter { item in
                let garment = item.garment
                if !searchText.isEmpty {
                    let text = searchText.lowercased()
                    let title = garment.displayTitle.lowercased()
                    let brand = garment.brand?.lowercased() ?? ""
                    if !title.contains(text) && !brand.contains(text) {
                        return false
                    }
                }

                if !selectedSeasons.isEmpty {
                    let season = garment.seasonSuitability ?? .allSeason
                    if season != .allSeason && !selectedSeasons.contains(season) { return false }
                }

                if !selectedColors.isEmpty {
                    let colors = Set(garment.safeColorTags)
                    if colors.isDisjoint(with: selectedColors) {
                        return false
                    }
                }

                return true
            }
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    TextField(String(localized: "planner_search_placeholder"), text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    if availableSlots.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: DS.Spacing.xs) {
                                ForEach(availableSlots, id: \.self) { slot in
                                    DSChip(slot.title, isSelected: selectedSlot == slot) {
                                        selectedSlot = slot
                                    }
                                }
                            }
                        }
                    }

                    Picker(String(localized: "planner_picker_mode_title"), selection: $pickerMode) {
                        Text(String(localized: "planner_picker_recommended")).tag(PickerMode.recommended)
                        Text(String(localized: "planner_picker_all")).tag(PickerMode.all)
                    }
                    .pickerStyle(.segmented)

                    filterSection

                    if filteredItems.isEmpty {
                        DSEmptyState(
                            icon: "tshirt",
                            title: String(localized: "planner_no_outfit"),
                            message: String(localized: "planner_add_more_items")
                        )
                    } else {
                        LazyVGrid(columns: columns, spacing: DS.Spacing.sm) {
                            ForEach(filteredItems) { item in
                                Button {
                                    handleSelection(item)
                                } label: {
                                    pickerItemCard(item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(DS.Spacing.md)
            }
            .navigationTitle(String(localized: "planner_add_item_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_close")) {
                        onClose()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onAddNewItem(selectedSlot)
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                    }
                    .accessibilityLabel(String(localized: "planner_add_new_item"))
                }
            }
            .confirmationDialog(
                String(localized: "planner_confirm_use_anyway_title"),
                isPresented: $showConfirm,
                titleVisibility: .visible
            ) {
                Button(String(localized: "planner_confirm_use_anyway_action")) {
                    if let pendingSelection {
                        onSelect(pendingSelection.garment, selectedSlot, true)
                        self.pendingSelection = nil
                    }
                }
                Button(String(localized: "action_cancel"), role: .cancel) {
                    pendingSelection = nil
                }
            } message: {
                Text(String(localized: "planner_confirm_use_anyway_message"))
            }
        }

        private var filterSection: some View {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(String(localized: "planner_filter_season"))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(SeasonSuitability.allCases, id: \.self) { season in
                            DSChip(season.shortTitle, isSelected: selectedSeasons.contains(season)) {
                                if selectedSeasons.contains(season) {
                                    selectedSeasons.remove(season)
                                } else {
                                    selectedSeasons.insert(season)
                                }
                            }
                        }
                    }
                }

                Text(String(localized: "planner_filter_color"))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(ColorTag.allCases) { color in
                            DSChip(color.title, isSelected: selectedColors.contains(color)) {
                                if selectedColors.contains(color) {
                                    selectedColors.remove(color)
                                } else {
                                    selectedColors.insert(color)
                                }
                            }
                        }
                    }
                }
            }
        }

        private func handleSelection(_ item: AvailabilityService.AvailabilityItem) {
            let isRecommended = AvailabilityService.isRecommendedEligible(item.status)
            if pickerMode == .all && !isRecommended {
                pendingSelection = item
                showConfirm = true
                return
            }
            onSelect(item.garment, selectedSlot, false)
        }

        @ViewBuilder
        private func pickerItemCard(_ item: AvailabilityService.AvailabilityItem) -> some View {
            let garment = item.garment
            let isDimmed = pickerMode == .all && !AvailabilityService.isRecommendedEligible(item.status)

            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    DSGarmentThumbnail(garment, size: .medium)
                        .opacity(isDimmed ? 0.6 : 1.0)

                    if let badge = badgeText(for: item.status), pickerMode == .all {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .foregroundStyle(.secondary)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(DS.Border.subtle, lineWidth: 0.6)
                            )
                            .padding(4)
                    }
                }

                Text(garment.displayTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isDimmed ? .secondary : .primary)
                    .lineLimit(1)

                if let warning = warningText(for: item.status), pickerMode == .all {
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(DS.Spacing.xs)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .strokeBorder(DS.Border.subtle, lineWidth: 0.6)
            )
        }

        private func badgeText(for status: AvailabilityStatus) -> String? {
            switch status {
            case .available:
                return nil
            case .worn:
                return String(localized: "planner_badge_worn")
            case .unavailable:
                return String(localized: "planner_badge_unavailable")
            case .cooldown:
                return String(localized: "planner_badge_cooldown")
            }
        }

        private func warningText(for status: AvailabilityStatus) -> String? {
            switch status {
            case .available:
                return nil
            case .worn:
                return String(localized: "planner_warning_worn")
            case .unavailable:
                return String(localized: "planner_warning_unavailable")
            case .cooldown(let daysRemaining):
                return String(
                    format: NSLocalizedString("planner_warning_cooldown_format", comment: ""),
                    daysRemaining
                )
            }
        }
    }
    
    // MARK: - Helpers

    private var greetingTitle: String {
        let hour = Calendar.current.component(.hour, from: currentDate)
        switch hour {
        case 5..<12:
            return String(localized: "greeting_morning")
        case 12..<18:
            return String(localized: "greeting_afternoon")
        default:
            return String(localized: "greeting_evening")
        }
    }

    private var greetingLine: String {
        let name = profiles.first?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
            return greetingTitle
        }
        return "\(greetingTitle), \(name)."
    }

    private var headerLine: String {
        let location = weather.locationName?.isEmpty == false ? weather.locationName! : String(localized: "location_unavailable")
        if let today = weather.forecasts.first {
            return "\(greetingLine) · \(location) · \(Int(today.lowTempC))°–\(Int(today.highTempC))°"
        }
        return "\(greetingLine) · \(location)"
    }

    private func lastWornText(for garment: Garment) -> String {
        if let date = garment.lastWorn {
            let days = max(0, Calendar.current.dateComponents([.day], from: date, to: currentDate).day ?? 0)
            let daysText = String(format: NSLocalizedString("planner_days_ago_format", comment: ""), days)
            return String(format: NSLocalizedString("planner_last_worn_format", comment: ""), daysText)
        }
        return String(localized: "planner_never_worn")
    }

    private func forecastSignature(_ forecasts: [DayForecast]) -> String {
        forecasts.prefix(3).map { forecast in
            "\(forecast.date.timeIntervalSince1970)-\(forecast.temperatureC)-\(forecast.highTempC)-\(forecast.lowTempC)-\(forecast.rainProbability)-\(forecast.condition.rawValue)"
        }.joined(separator: "|")
    }

    private func updateTargeted(_ isTargeted: Bool, dayIndex: Int, slot: OutfitSlot, lookTime: LookTime) {
        let target = SlotTarget(dayIndex: dayIndex, slot: slot, lookTime: lookTime)
        let isValid = isValidDropTarget(slot: slot, lookTime: lookTime)

        if isTargeted && isValid {
            targetedSlots.insert(target)
        } else {
            targetedSlots.remove(target)
        }
    }

    private func isValidDropTarget(slot: OutfitSlot, lookTime: LookTime) -> Bool {
        guard let dragged = boardState.draggedItem else { return false }
        return dragged.sourceSlot == slot
    }

    private func isTargetHighlighted(dayIndex: Int, slot: OutfitSlot, lookTime: LookTime) -> Bool {
        targetedSlots.contains(SlotTarget(dayIndex: dayIndex, slot: slot, lookTime: lookTime))
    }

    private func targetHighlightColor(dayIndex: Int, slot: OutfitSlot, lookTime: LookTime) -> Color {
        isTargetHighlighted(dayIndex: dayIndex, slot: slot, lookTime: lookTime) ? Color.accentColor.opacity(0.35) : .clear
    }

    private func targetHighlightLineWidth(dayIndex: Int, slot: OutfitSlot, lookTime: LookTime) -> CGFloat {
        isTargetHighlighted(dayIndex: dayIndex, slot: slot, lookTime: lookTime) ? 2 : 0
    }

    private func clearDragState() {
        boardState.draggedItem = nil
        targetedSlots.removeAll()
    }
    
    private func dayName(for index: Int) -> String {
        switch index {
        case 0: return String(localized: "day_today")
        case 1: return String(localized: "day_tomorrow")
        default:
            let date = Calendar.current.date(byAdding: .day, value: index, to: currentDate) ?? currentDate
            return Self.dayNameFormatter.string(from: date)
        }
    }
    
    private func formattedDate(_ date: Date) -> String {
        Self.shortDateFormatter.string(from: date)
    }

    private func updateAvailableGarments() {
        let filtered = allGarments
        availableGarmentsCache = filtered
        availableGarmentsSignature = filtered.map {
            "\($0.id.uuidString)-\($0.isWorn ? 1 : 0)-\($0.isCurrentlyUnavailable ? 1 : 0)"
        }.sorted().joined(separator: "|")
    }

    private func refreshCurrentDate() {
        currentDate = Date()
    }

    private func forecastKey(for forecast: DayForecast?) -> String {
        guard let forecast else { return "" }
        return [
            String(forecast.date.timeIntervalSince1970),
            String(forecast.temperatureC),
            String(forecast.highTempC),
            String(forecast.lowTempC),
            String(forecast.rainProbability),
            forecast.condition.rawValue
        ].joined(separator: "|")
    }

    private func assignedGarmentSignature(for dayIndex: Int) -> String {
        guard dayIndex < boardState.days.count else { return "" }
        let day = boardState.days[dayIndex]
        var parts: [String] = []
        let slots = OutfitSlot.allCases

        for slot in slots {
            let id = day.garmentID(for: slot)
            let signature = garmentSignature(id: id)
            parts.append("d:\(slot.rawValue):\(signature)")
        }
        for slot in slots {
            let id = day.eveningGarmentID(for: slot)
            let signature = garmentSignature(id: id)
            parts.append("e:\(slot.rawValue):\(signature)")
        }
        return parts.joined(separator: "|")
    }

    private func garmentSignature(id: UUID?) -> String {
        guard let id else { return "nil" }
        if let garment = allGarments.first(where: { $0.id == id }) {
            return [
                garment.id.uuidString,
                garment.imagePath ?? "",
                garment.thumbnailPath ?? "",
                garment.isCurrentlyUnavailable ? "1" : "0"
            ].joined(separator: ":")
        }
        return id.uuidString
    }
    
    private func weatherIconColor(for condition: WeatherCondition) -> Color {
        switch condition {
        case .sunny: return .orange
        case .partlyCloudy: return .yellow
        case .cloudy: return .gray
        case .rain, .storm: return .blue
        case .snow: return .cyan
        }
    }
}

private struct DayCardSignature: Equatable {
    let dayIndex: Int
    let state: PlannerDayState
    let isExpanded: Bool
    let isSelected: Bool
    let isConfirmed: Bool
    let forecastKey: String
    let assignedSignature: String
    let availableSignature: String
}

private struct DayCardContainer<Content: View>: View, Equatable {
    let signature: DayCardSignature
    let content: Content

    init(signature: DayCardSignature, @ViewBuilder content: () -> Content) {
        self.signature = signature
        self.content = content()
    }

    static func == (lhs: DayCardContainer<Content>, rhs: DayCardContainer<Content>) -> Bool {
        lhs.signature == rhs.signature
    }

    var body: some View {
        content
    }
}

// MARK: - Feedback Button

struct FeedbackButton: View {
    let label: String
    let icon: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button {
            DS.haptic(0.4)
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.xs)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(color.opacity(isSelected ? 0.18 : 0))
            )
            .foregroundStyle(isSelected ? color : .primary)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .strokeBorder(isSelected ? color.opacity(0.4) : Color.white.opacity(0.12), lineWidth: 0.6)
                    .blendMode(.plusLighter)
            )
        }
        .buttonStyle(.plain)
        .animation(DS.Animation.fast, value: isSelected)
    }
}

// MARK: - Temperature Feedback Button

struct TempFeedbackButton: View {
    let feedback: TemperatureFeedback
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button {
            DS.haptic(0.3)
            action()
        } label: {
            HStack(spacing: 2) {
                Text(feedback.emoji)
                    .font(.caption2)
                Text(feedback.label)
                    .font(.caption2.weight(.medium))
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .fill(Color.accentColor.opacity(isSelected ? 0.18 : 0))
            )
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
