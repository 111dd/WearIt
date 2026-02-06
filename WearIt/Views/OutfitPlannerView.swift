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
    @EnvironmentObject private var weather: WeatherCenter
    
    @Query(sort: \Garment.createdAt, order: .reverse) private var allGarments: [Garment]
    @Query(sort: \UserProfile.createdAt, order: .reverse) private var profiles: [UserProfile]
    @Query(sort: \DayPlan.date, order: .reverse) private var dayPlans: [DayPlan]
    
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
        case addPicker(dayIndex: Int, slots: [OutfitSlot], lookTime: LookTime)
        case addNewItem(dayIndex: Int, slot: OutfitSlot, lookTime: LookTime)

        var id: String {
            switch self {
            case .garmentMenu(let garment):
                return "garment-\(garment.id.uuidString)"
            case .addPicker(let dayIndex, _, let lookTime):
                return "picker-\(dayIndex)-\(lookTime.rawValue)"
            case .addNewItem(let dayIndex, let slot, let lookTime):
                return "new-\(dayIndex)-\(slot.rawValue)-\(lookTime.rawValue)"
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var availableGarments: [Garment] {
        availableGarmentsCache
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
            case .addPicker(let dayIndex, let slots, let lookTime):
                addPickerSheet(dayIndex: dayIndex, slots: slots, lookTime: lookTime)
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
    }

    private var plannerContent: some View {
        ZStack {
            LiquidGlassBackdrop()
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                    plannerHeader

                    ForEach(0..<3, id: \.self) { dayIndex in
                        if dayIndex < boardState.days.count {
                            dayColumn(for: dayIndex)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.sm)
                .padding(.bottom, DS.Spacing.xl)
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomActionBar
        }
    }

    private func handleAppear() {
        boardState.initializeDays()
        hydrateFromPlans()
        updateAvailableGarments()
        refreshCurrentDate()
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
                            Label(String(localized: "planner_replace_single_item"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .dsSecondaryButton()

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

    private func addPickerSheet(dayIndex: Int, slots: [OutfitSlot], lookTime: LookTime) -> some View {
        NavigationStack {
            PlannerAddPicker(
                dayIndex: dayIndex,
                availableSlots: slots,
                garmentsForSlot: { slot in
                    garmentsForSlot(slot, dayIndex: dayIndex, lookTime: lookTime)
                },
                onSelect: { garment, slot in
                    assignGarment(garment, to: slot, dayIndex: dayIndex, lookTime: lookTime)
                    activeSheet = nil
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
            Button {
                confirmWorn(dayIndex: dayIndex)
            } label: {
                Label(String(localized: "planner_mark_worn_today"), systemImage: "checkmark.seal")
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
        let confirmed = isConfirmed(dayIndex)
        let expanded = isDetailsExpanded(dayIndex)
        return HStack(spacing: DS.Spacing.xs) {
            compactActionPill(
                title: String(localized: confirmed ? "planner_undo_confirm" : "planner_confirm_day"),
                systemImage: confirmed ? "arrow.uturn.left" : "checkmark.seal",
                tint: Color.accentColor
            ) {
                if confirmed {
                    unconfirmDay(dayIndex: dayIndex)
                } else {
                    confirmWorn(dayIndex: dayIndex)
                }
            }

            compactActionPill(
                title: String(localized: "planner_refresh_day"),
                systemImage: "arrow.clockwise",
                tint: .secondary
            ) {
                refreshDay(dayIndex)
            }

            Spacer()

            compactActionPill(
                title: String(localized: expanded ? "planner_hide_recommendations" : "planner_show_recommendations"),
                systemImage: expanded ? "chevron.down" : "sparkles",
                tint: .primary
            ) {
                toggleDayDetails(dayIndex)
            }
        }
        .padding(.top, DS.Spacing.xxs)
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
        }
        .buttonStyle(.plain)
    }

    private var bottomActionBar: some View {
        AnyView(EmptyView())
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
        let assignedSlots = slotsToShow.compactMap { slot -> (OutfitSlot, Garment, Bool)? in
            let id: UUID?
            if lookTime == .evening {
                id = day.eveningGarmentID(for: slot)
            } else {
                id = day.garmentID(for: slot)
            }
            guard let id,
                  let garment = allGarments.first(where: { $0.id == id }) else {
                return nil
            }
            let isLocked = lookTime == .day ? day.isLocked(slot) : false
            return (slot, garment, isLocked)
        }
        
        return HStack(spacing: DS.Spacing.xs) {
            ForEach(assignedSlots, id: \.1.id) { slot, garment, isLocked in
                draggableGarmentTile(
                    garment: garment,
                    slot: slot,
                    dayIndex: dayIndex,
                    lookTime: lookTime,
                    isLocked: isLocked
                )
            }
            
            if !availableSlots(for: dayIndex, lookTime: lookTime).isEmpty {
                addItemButton(dayIndex: dayIndex, lookTime: lookTime)
            }
        }
    }

    private func eveningSection(for dayIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(String(localized: "planner_evening_look"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            outfitRow(for: dayIndex, lookTime: .evening)
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
        isLocked: Bool
    ) -> some View {
        let canDrag = !isLocked && !garment.isCurrentlyUnavailable
        let baseTile = ZStack(alignment: .topTrailing) {
            DSGarmentThumbnail(garment, size: .medium)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                        .strokeBorder(garment.isCurrentlyUnavailable ? Color.red : .clear, lineWidth: 2)
                )
                .opacity(garment.isCurrentlyUnavailable ? 0.5 : 1.0)
            
            // Lock indicator
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Color.accentColor, in: Circle())
                    .offset(x: 4, y: -4)
            }
            
            // Unavailable badge
            if garment.isCurrentlyUnavailable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Color.red, in: Circle())
                    .offset(x: 4, y: -4)
            }
        }
        let dropTarget = baseTile
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
                Button {
                    replaceSlot(dayIndex: dayIndex, slot: slot, lookTime: lookTime)
                } label: {
                    Label(String(localized: "planner_replace_single_item"), systemImage: "arrow.triangle.2.circlepath")
                }

                Button {
                    openAddNewItem(dayIndex: dayIndex, slot: slot, lookTime: lookTime)
                } label: {
                    Label(String(localized: "planner_add_new_item"), systemImage: "plus")
                }

                if slot == .outer {
                    Button(role: .destructive) {
                        removeGarmentSlot(dayIndex: dayIndex, slot: slot, lookTime: lookTime)
                    } label: {
                        Label(String(localized: "planner_remove_outerwear"), systemImage: "xmark.circle")
                    }
                }

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
    
    // MARK: - Empty Slot Target
    
    private func emptySlotTarget(slot: OutfitSlot, dayIndex: Int) -> some View {
        RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
            .foregroundStyle(Color.secondary.opacity(0.3))
            .frame(width: 70, height: 70)
            .overlay {
                if isTargetHighlighted(dayIndex: dayIndex, slot: slot, lookTime: .day) {
                    Text(String(localized: "planner_drop_here"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
            .onTapGesture {
                openAddPicker(dayIndex: dayIndex, lookTime: .day)
            }
            .onDrop(of: [UTType.garmentDragItem], isTargeted: Binding(
                get: { isTargetHighlighted(dayIndex: dayIndex, slot: slot, lookTime: .day) },
                set: { updateTargeted($0, dayIndex: dayIndex, slot: slot, lookTime: .day) }
            )) { providers in
                return handleDrop(providers: providers, targetDay: dayIndex, targetSlot: slot, lookTime: .day)
            }
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                    .strokeBorder(
                        targetHighlightColor(dayIndex: dayIndex, slot: slot, lookTime: .day),
                        lineWidth: targetHighlightLineWidth(dayIndex: dayIndex, slot: slot, lookTime: .day)
                    )
            )
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

        // Check if either day slot is locked
        if (item.lookTime == .day && boardState.days[item.sourceDayIndex].isLocked(item.sourceSlot)) ||
            (lookTime == .day && boardState.days[targetDay].isLocked(targetSlot)) {
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
        
        // Collect IDs used in other days
        var excludedIDs = Set<UUID>()
        for (index, day) in boardState.days.enumerated() {
            if index != dayIndex {
                excludedIDs.formUnion(day.assignedGarmentIDs)
            }
        }
        
        // Also exclude locked items in this day
        for slot in OutfitSlot.allCases {
            if boardState.days[dayIndex].isLocked(slot),
               let id = boardState.days[dayIndex].garmentID(for: slot) {
                excludedIDs.insert(id)
            }
        }
        
        let ctx = recoContext(for: dayIndex)
        
        let outfit = AIRecommender.shared.suggestOutfit(
            from: availableGarments,
            ctx: ctx,
            modelContext: context,
            excludedIDs: excludedIDs
        )
        
        boardState.setOutfit(forDay: dayIndex, garments: outfit, overwriteExisting: true)
        persistDayPlan(dayIndex)

        if boardState.days[dayIndex].useEveningLook {
            generateEveningOutfit(for: dayIndex)
        }
    }

    private func openAddPicker(dayIndex: Int, lookTime: LookTime) {
        let slots = availableSlots(for: dayIndex, lookTime: lookTime)
        guard !slots.isEmpty else { return }
        activeSheet = .addPicker(dayIndex: dayIndex, slots: slots, lookTime: lookTime)
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

    private func garmentsForSlot(_ slot: OutfitSlot, dayIndex: Int, lookTime: LookTime) -> [Garment] {
        let allowed = slot.allowedCategories
        let day = boardState.days[dayIndex]
        let currentID = lookTime == .evening ? day.eveningGarmentID(for: slot) : day.garmentID(for: slot)
        return availableGarments.filter { garment in
            guard allowed.contains(garment.category) else { return false }
            if garment.id == currentID { return true }
            return !isGarmentUsedElsewhere(garment.id, excludingDay: dayIndex)
        }
    }

    private func availableSlots(for dayIndex: Int, lookTime: LookTime) -> [OutfitSlot] {
        guard dayIndex < boardState.days.count else { return [] }
        let day = boardState.days[dayIndex]
        var slots: [OutfitSlot] = []

        let topID = lookTime == .evening ? day.eveningGarmentID(for: .top) : day.garmentID(for: .top)
        if topID == nil, !garmentsForSlot(.top, dayIndex: dayIndex, lookTime: lookTime).isEmpty { slots.append(.top) }

        let bottomID = lookTime == .evening ? day.eveningGarmentID(for: .bottom) : day.garmentID(for: .bottom)
        if bottomID == nil, !garmentsForSlot(.bottom, dayIndex: dayIndex, lookTime: lookTime).isEmpty { slots.append(.bottom) }

        let shoesID = lookTime == .evening ? day.eveningGarmentID(for: .shoes) : day.garmentID(for: .shoes)
        if shoesID == nil, !garmentsForSlot(.shoes, dayIndex: dayIndex, lookTime: lookTime).isEmpty { slots.append(.shoes) }

        let outerID = lookTime == .evening ? day.eveningGarmentID(for: .outer) : day.garmentID(for: .outer)
        if shouldShowSlot(.outer, dayIndex: dayIndex, lookTime: lookTime),
           outerID == nil,
           !garmentsForSlot(.outer, dayIndex: dayIndex, lookTime: lookTime).isEmpty {
            slots.append(.outer)
        }

        let accessoryID = lookTime == .evening ? day.eveningGarmentID(for: .accessory) : day.garmentID(for: .accessory)
        if accessoryID == nil,
           !garmentsForSlot(.accessory, dayIndex: dayIndex, lookTime: lookTime).isEmpty {
            slots.append(.accessory)
        }

        return slots
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
    private func assignGarment(_ garment: Garment, to slot: OutfitSlot, dayIndex: Int, lookTime: LookTime) -> Bool {
        let success: Bool
        if lookTime == .evening {
            success = assignEveningGarment(garment, to: slot, dayIndex: dayIndex)
        } else {
            success = boardState.assignGarment(garment.id, toDay: dayIndex, toSlot: slot, garments: allGarments)
        }
        if success {
            DS.haptic(0.3)
            persistAllPlans()
        } else {
            DS.haptic(0.8)
        }
        return success
    }

    private func assignEveningGarment(_ garment: Garment, to slot: OutfitSlot, dayIndex: Int) -> Bool {
        guard dayIndex < boardState.days.count else { return false }
        if garment.isCurrentlyUnavailable {
            boardState.alertMessage = String(localized: "assign_error_unavailable")
            boardState.showUnavailableAlert = true
            return false
        }
        if isGarmentUsedElsewhere(garment.id, excludingDay: dayIndex) {
            boardState.alertMessage = String(localized: "swap_error_duplicate")
            boardState.showUnavailableAlert = true
            return false
        }
        boardState.days[dayIndex].setEveningGarment(garment.id, for: slot)
        return true
    }

    private func toggleLock(dayIndex: Int, slot: OutfitSlot) {
        guard dayIndex < boardState.days.count else { return }
        let isLocked = boardState.days[dayIndex].isLocked(slot)
        let garmentID = boardState.days[dayIndex].garmentID(for: slot)
        boardState.days[dayIndex].setGarment(garmentID, for: slot, locked: !isLocked)
        persistDayPlan(dayIndex)
    }

    private func removeGarment(dayIndex: Int, slot: OutfitSlot) {
        guard dayIndex < boardState.days.count else { return }
        if boardState.days[dayIndex].isLocked(slot) {
            boardState.alertMessage = String(localized: "swap_error_locked")
            boardState.showUnavailableAlert = true
            return
        }
        boardState.days[dayIndex].setGarment(nil, for: slot)
        persistDayPlan(dayIndex)
    }

    private func removeGarmentSlot(dayIndex: Int, slot: OutfitSlot, lookTime: LookTime) {
        guard dayIndex < boardState.days.count else { return }
        if lookTime == .day {
            removeGarment(dayIndex: dayIndex, slot: slot)
        } else {
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

        let ctx = recoContext(for: dayIndex, isEvening: lookTime == .evening)
        let state = boardState.days[dayIndex]
        let currentID = lookTime == .evening ? state.eveningGarmentID(for: slot) : state.garmentID(for: slot)

        var excludedIDs: Set<UUID> = []
        for (index, day) in boardState.days.enumerated() {
            if index != dayIndex {
                excludedIDs.formUnion(day.assignedGarmentIDs)
                excludedIDs.formUnion(day.eveningAssignedGarmentIDs)
            }
        }
        if let currentID { excludedIDs.insert(currentID) }

        let pool = availableGarments.filter { slot.allowedCategories.contains($0.category) }
        let suggestions = AIRecommender.shared.suggest(
            from: pool,
            k: 1,
            ctx: ctx,
            modelContext: context,
            excludedIDs: excludedIDs
        )

        if let replacement = suggestions.first {
            if lookTime == .evening {
                boardState.days[dayIndex].setEveningGarment(replacement.id, for: slot)
            } else {
                boardState.days[dayIndex].setGarment(replacement.id, for: slot)
            }
            persistDayPlan(dayIndex)
            DS.haptic(0.3)
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
        var usedIDs: Set<UUID> = fillMissingOnly
            ? Set(boardState.days.flatMap { $0.assignedGarmentIDs })
            : []
        
        for i in 0..<boardState.days.count {
            let state = boardState.days[i]
            let ctx = recoContext(for: i)
            
            let outfit = AIRecommender.shared.suggestOutfit(
                from: availableGarments,
                ctx: ctx,
                modelContext: context,
                excludedIDs: fillMissingOnly
                    ? usedIDs.subtracting(state.assignedGarmentIDs)
                    : usedIDs
            )
            
            boardState.setOutfit(forDay: i, garments: outfit, overwriteExisting: !fillMissingOnly)
            usedIDs.formUnion(boardState.days[i].assignedGarmentIDs)
            boardState.days[i].insufficientItemsWarning = boardState.days[i].assignedGarmentIDs.isEmpty && i > 0
            persistDayPlan(i)
        }

        generateEveningOutfits(fillMissingOnly: fillMissingOnly)
    }

    private func generateEveningOutfit(for dayIndex: Int) {
        guard dayIndex < boardState.days.count else { return }
        guard boardState.days[dayIndex].useEveningLook else { return }

        var usedIDs = Set(boardState.days.flatMap { $0.assignedGarmentIDs })
        usedIDs.formUnion(boardState.days.flatMap { $0.eveningAssignedGarmentIDs })

        let ctx = recoContext(for: dayIndex, isEvening: true)
        let outfit = AIRecommender.shared.suggestOutfit(
            from: availableGarments,
            ctx: ctx,
            modelContext: context,
            excludedIDs: usedIDs
        )

        setEveningOutfit(forDay: dayIndex, garments: outfit)
        persistDayPlan(dayIndex)
    }

    private func generateEveningOutfits(fillMissingOnly: Bool) {
        var usedIDs = Set(boardState.days.flatMap { $0.assignedGarmentIDs })
        if fillMissingOnly {
            usedIDs.formUnion(boardState.days.flatMap { $0.eveningAssignedGarmentIDs })
        }

        for i in 0..<boardState.days.count {
            guard boardState.days[i].useEveningLook else { continue }

            let currentEveningIDs = boardState.days[i].eveningAssignedGarmentIDs
            if fillMissingOnly, !currentEveningIDs.isEmpty {
                continue
            }

            let ctx = recoContext(for: i, isEvening: true)
            let outfit = AIRecommender.shared.suggestOutfit(
                from: availableGarments,
                ctx: ctx,
                modelContext: context,
                excludedIDs: usedIDs
            )

            setEveningOutfit(forDay: i, garments: outfit)
            usedIDs.formUnion(boardState.days[i].eveningAssignedGarmentIDs)
            persistDayPlan(i)
        }
    }

    private func setEveningOutfit(forDay dayIndex: Int, garments: [Garment]) {
        guard dayIndex < boardState.days.count else { return }
        for slot in OutfitSlot.allCases {
            boardState.days[dayIndex].setEveningGarment(nil, for: slot)
        }
        for garment in garments {
            let slot = OutfitSlot.from(category: garment.category)
            boardState.days[dayIndex].setEveningGarment(garment.id, for: slot)
        }
    }

    private func clearEveningOutfit(for dayIndex: Int) {
        guard dayIndex < boardState.days.count else { return }
        for slot in OutfitSlot.allCases {
            boardState.days[dayIndex].setEveningGarment(nil, for: slot)
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
            for slot in OutfitSlot.allCases {
                if let id = eveningAssignments[slot],
                   let garment = allGarments.first(where: { $0.id == id }),
                   !usedIDs.contains(garment.id) {
                    boardState.days[dayIndex].setEveningGarment(garment.id, for: slot)
                    usedIDs.insert(garment.id)
                }
            }
        }
    }

    private func persistDayPlan(_ dayIndex: Int) {
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
        for slot in OutfitSlot.allCases {
            eveningAssignments[slot] = day.eveningGarmentID(for: slot)
        }
        plan.setEveningSlotAssignments(eveningAssignments)
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

    private func persistPlans(for indices: [Int]) {
        for index in indices {
            persistDayPlan(index)
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
        replaceSlot(dayIndex: assignment.dayIndex, slot: assignment.slot, lookTime: .day)
        activeSheet = nil
    }

    private func markWornToday(_ garment: Garment) {
        DS.haptic(0.4)
        let date = Date()
        garment.lastWorn = date
        garment.timesWorn += 1
        try? context.save()
        WearEventStore.markWorn(
            date: date,
            garmentIDs: [garment.id],
            source: .manual,
            context: context
        )
        activeSheet = nil
    }

    private func confirmWorn(dayIndex: Int) {
        guard dayIndex < boardState.days.count else { return }
        let date = boardState.days[dayIndex].date
        let garmentIDs = boardState.days[dayIndex].assignedGarmentIDs

        for garment in allGarments where garmentIDs.contains(garment.id) {
            if garment.lastWorn == nil || garment.lastWorn! < date {
                garment.lastWorn = date
                garment.timesWorn += 1
                garment.loveScore = min(100, garment.loveScore + 1)
            }
        }

        let plan = DayPlanService.shared.planFor(date: date, context: context)
        plan.wasWornConfirmed = true
        plan.updatedAt = Date()
        try? context.save()
        WearEventStore.markWorn(
            date: date,
            outfitID: plan.id,
            garmentIDs: garmentIDs,
            source: .planner,
            context: context
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
        let garmentsForSlot: (OutfitSlot) -> [Garment]
        let onSelect: (Garment, OutfitSlot) -> Void
        let onAddNewItem: (OutfitSlot) -> Void
        let onClose: () -> Void

        @State private var selectedSlot: OutfitSlot
        @State private var searchText = ""
        @State private var selectedSeasons: Set<SeasonSuitability> = []
        @State private var selectedColors: Set<ColorTag> = []

        init(
            dayIndex: Int,
            availableSlots: [OutfitSlot],
            garmentsForSlot: @escaping (OutfitSlot) -> [Garment],
            onSelect: @escaping (Garment, OutfitSlot) -> Void,
            onAddNewItem: @escaping (OutfitSlot) -> Void,
            onClose: @escaping () -> Void
        ) {
            self.dayIndex = dayIndex
            self.availableSlots = availableSlots
            self.garmentsForSlot = garmentsForSlot
            self.onSelect = onSelect
            self.onAddNewItem = onAddNewItem
            self.onClose = onClose
            _selectedSlot = State(initialValue: availableSlots.first ?? .top)
        }

        private let columns = [GridItem(.adaptive(minimum: 90), spacing: DS.Spacing.sm)]

        private var filteredGarments: [Garment] {
            garmentsForSlot(selectedSlot).filter { garment in
                if !searchText.isEmpty {
                    let text = searchText.lowercased()
                    let title = garment.displayTitle.lowercased()
                    let brand = garment.brand?.lowercased() ?? ""
                    if !title.contains(text) && !brand.contains(text) {
                        return false
                    }
                }

                if !selectedSeasons.isEmpty, let season = garment.seasonSuitability {
                    if !selectedSeasons.contains(season) && season != .allSeason {
                        return false
                    }
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

                    Button {
                        onAddNewItem(selectedSlot)
                    } label: {
                        Label(String(localized: "planner_add_new_item"), systemImage: "plus")
                    }
                    .dsSecondaryButton()

                    filterSection

                    if filteredGarments.isEmpty {
                        DSEmptyState(
                            icon: "tshirt",
                            title: String(localized: "planner_no_outfit"),
                            message: String(localized: "planner_add_more_items")
                        )
                    } else {
                        LazyVGrid(columns: columns, spacing: DS.Spacing.sm) {
                            ForEach(filteredGarments) { garment in
                                Button {
                                    onSelect(garment, selectedSlot)
                                } label: {
                                    DSGarmentThumbnail(garment, size: .medium)
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
        let filtered = allGarments.filter { !$0.isBlocked && !$0.isCurrentlyUnavailable }
        availableGarmentsCache = filtered
        availableGarmentsSignature = filtered.map { $0.id.uuidString }.sorted().joined(separator: "|")
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
