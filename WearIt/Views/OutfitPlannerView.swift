//
//  OutfitPlannerView.swift
//  WearIt
//
//  3-day outfit planner board with drag & swap

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit
import os

struct OutfitPlannerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var weather: WeatherCenter
    @EnvironmentObject private var auth: AuthManager

    @Query(sort: \Garment.createdAt, order: .reverse) private var allGarments: [Garment]
    @Query(sort: \UserProfile.createdAt, order: .reverse) private var profiles: [UserProfile]
    @Query private var dayPlans: [DayPlan]
    @Query private var wearEvents: [WearEvent]
    @Query private var dismissedOutfits: [DismissedOutfit]
    @Query(sort: \RecommendationEvent.createdAt, order: .reverse) private var recommendationEvents: [RecommendationEvent]
    
    @State private var boardState = PlannerBoardState()
    @State private var showFeedbackAlert = false
    @State private var alertMessage = ""
    @State private var activeSheet: PlannerSheet?
    /// Single hover target — cheaper than a Set that churns on every drag frame.
    @State private var targetedSlot: SlotTarget?
    @AppStorage("planner.allowRepeatedItems") private var allowRepeatedItems = true
    @State private var garmentActionTarget: SlotTarget?
    @State private var lastForecastSignature: String = ""
    @State private var expandedDayDetails: Set<Int> = []
    @State private var selectedDayIndex: Int = 0
    @State private var availableGarmentsCache: [Garment] = []
    @State private var currentDate: Date = Date()
    @State private var availableGarmentsSignature: String = ""
    @State private var didRunWearHistoryDebug = false
    @State private var dirtyDayIndices: Set<Int> = []
    @State private var plannerSaveDebouncer = Debouncer(interval: 15.0)
    @State private var appIntentRouter = WearItAppIntentRouter.shared
    @State private var cachedTaste = TasteAffinityBuilder.Profile.empty
    @State private var cachedCombination = CombinationAffinity.empty
    @State private var cachedLatestWearByGarmentID: [UUID: Date] = [:]
    @State private var affinityCacheSignature: String = ""
    /// Days whose "What do you think?" panel is expanded.
    @State private var expandedFeedbackDays: Set<Int> = []
    @State private var cachedCalendarContexts: [Int: DayCalendarContext] = [:]
    /// Brief non-error status after a successful neutral look replacement.
    @State private var statusToast: String?
    /// Prevents concurrent action commits on the same day/look row.
    @State private var swipeBusyKeys: Set<String> = []
    /// Memoized advisor/availability results — plain class so body-time writes
    /// don't invalidate the view tree.
    @State private var advisorMemo = AdvisorMemo()
    /// Fast garment lookup for hot paths (signatures, tiles, hints).
    @State private var garmentsByID: [UUID: Garment] = [:]
    /// Bumped whenever calendar contexts are recomputed; advisor memo dependency.
    @State private var calendarContextsVersion = 0
    /// In-flight chunked outfit generation; cancelled when a newer request arrives.
    @State private var outfitGenerationTask: Task<Void, Never>?
    /// AI look explanations keyed by LookExplanationRequest.cacheKey.
    @State private var lookExplanations: [String: LookExplanationResult] = [:]
    /// Session memory of items the user already cycled past per day/look/slot,
    /// so repeated "replace" taps don't alternate between the same two pieces.
    @State private var replacementRotation: [String: [UUID]] = [:]
    @AppStorage(LookExplanationKeys.enabled) private var aiLookExplanationsEnabled = true

    init() {
        var plans = FetchDescriptor<DayPlan>(
            sortBy: [SortDescriptor(\DayPlan.date, order: .reverse)]
        )
        plans.fetchLimit = 21
        _dayPlans = Query(plans)

        var wears = FetchDescriptor<WearEvent>(
            sortBy: [SortDescriptor(\WearEvent.date, order: .reverse)]
        )
        wears.fetchLimit = 150
        _wearEvents = Query(wears)

        var dismissed = FetchDescriptor<DismissedOutfit>()
        dismissed.fetchLimit = 100
        _dismissedOutfits = Query(dismissed)
    }

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

    /// Signature-keyed memo for advisor work that used to run on every body
    /// evaluation (OutfitChangeAdvisor scoring, unworn-nudge filtering,
    /// per-tile availability). Deliberately NOT @Observable.
    private final class AdvisorMemo {
        var changeSuggestions: [String: (signature: String, value: [OutfitChangeSuggestion])] = [:]
        var unwornNudge: (signature: String, value: UnwornNudge?)?
        var availability: [String: (signature: String, value: AvailabilityStatus)] = [:]
    }
    
    // MARK: - Computed Properties
    
    private var availableGarments: [Garment] {
        availableGarmentsCache
    }

    private var latestWearByGarmentID: [UUID: Date] {
        cachedLatestWearByGarmentID
    }
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            plannerContent
                .navigationTitle(String(localized: "planner_board_title"))
                .minimalCollapsingNavBar()
                .toolbar {
                    // RTL: leading = visual right → profile. Trailing = visual left → stats.
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink {
                            ProfileView()
                                .withLocalAppBackdrop()
                        } label: {
                            plannerProfileAvatar
                        }
                        .accessibilityLabel(String(localized: "nav_profile"))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            StatsView()
                                .withLocalAppBackdrop()
                        } label: {
                            Image(systemName: "chart.bar.fill")
                                .font(.body.weight(.semibold))
                        }
                        .accessibilityLabel(String(localized: "nav_stats"))
                    }
                }
        }
        .onAppear(perform: handleAppear)
        .onChange(of: weather.forecasts) { _, newValue in
            handleForecastChange(newValue)
        }
        .onChange(of: allGarments.count) { _, newValue in
            handleGarmentChange(newValue)
            refreshAffinityCaches()
        }
        .onChange(of: wearEvents.count) { _, _ in
            refreshAffinityCaches()
        }
        .onChange(of: dismissedOutfits.count) { _, _ in
            refreshAffinityCaches()
        }
        .onChange(of: allowRepeatedItems) { _, _ in
            updateAvailableGarments()
            advisorMemo.changeSuggestions.removeAll()
            advisorMemo.availability.removeAll()
        }
        .alert(String(localized: "error_title"), isPresented: $boardState.showUnavailableAlert) {
            Button(String(localized: "action_confirm"), role: .cancel) { }
        } message: {
            Text(boardState.alertMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .confirmWornFromWidget)) { _ in
            confirmWorn(dayIndex: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPlannerDay)) { notification in
            guard let date = notification.userInfo?["date"] as? Date,
                  let index = boardState.days.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: date) })
            else { return }
            selectedDayIndex = index
            expandedDayDetails.insert(index)
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
        .onChange(of: appIntentRouter.pendingAction) { _, newAction in
            if newAction != nil {
                performPendingIntentAction()
            }
        }
    }

    private var plannerContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxl) {
                plannerSubtitle
                    .padding(.horizontal, DS.Spacing.md)

                if let nudge = unwornNudge {
                    unwornNudgeCard(nudge)
                        .padding(.horizontal, DS.Spacing.md)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if allGarments.isEmpty {
                    emptyWardrobeCard
                        .padding(.horizontal, DS.Spacing.md)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    ForEach(0..<3, id: \.self) { dayIndex in
                        if dayIndex < boardState.days.count {
                            dayColumn(for: dayIndex)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, DS.Spacing.md)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                                    removal: .opacity
                                ))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DS.Spacing.sm)
            .padding(.bottom, DS.Spacing.xxl)
        }
        .frame(maxWidth: .infinity)
        .withLocalAppBackdrop()
        .overlay(alignment: .bottom) {
            if let statusToast {
                Text(statusToast)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)
                    .liquidGlassSurface(cornerRadius: DS.Radius.chip, castsShadow: true)
                    .padding(.bottom, DS.Spacing.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(reduceMotion ? nil : DS.Animation.standard, value: statusToast)
    }

    private var emptyWardrobeCard: some View {
        DSEmptyState(
            icon: "tshirt",
            title: String(localized: "planner_empty_wardrobe_title"),
            message: String(localized: "planner_empty_wardrobe_message"),
            actionTitle: String(localized: "planner_empty_wardrobe_action")
        ) {
            activeSheet = .addNewItem(dayIndex: 0, slot: .top, lookTime: .day)
        }
        .liquidGlassSurface(cornerRadius: DS.Radius.card, padding: DS.Spacing.md, castsShadow: true)
    }

    private func handleAppear() {
        let signposter = WearItPerformance.plannerSignposter
        let interval = signposter.beginInterval("planner-restore", id: signposter.makeSignpostID())
        defer { signposter.endInterval("planner-restore", interval) }
        boardState.initializeDays()
        hydrateFromPlans()
        updateAvailableGarments()
        refreshAffinityCaches()
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
            if CalendarContextPreferences.deviceCalendarEnabled {
                _ = await CalendarContextService.shared.requestDeviceCalendarAccessIfNeeded()
            }
            refreshCalendarContextsAndApplyEvening()
            if appIntentRouter.pendingAction != nil {
                performPendingIntentAction()
            } else {
                scheduleGenerateAllOutfits(fillMissingOnly: true)
            }
        }
    }

    private func performPendingIntentAction() {
        guard let action = appIntentRouter.consumeAction() else { return }
        switch action {
        case .refreshTodayOutfit:
            guard !boardState.days.isEmpty else { return }
            selectedDayIndex = 0
            refreshDay(0)
        }
    }

    private func handleForecastChange(_ newForecasts: [DayForecast]) {
        let signature = forecastSignature(newForecasts)
        guard signature != lastForecastSignature else { return }
        lastForecastSignature = signature
        boardState.updateForecasts(newForecasts)
        scheduleGenerateAllOutfits(fillMissingOnly: true)
    }

    private func handleGarmentChange(_ _: Int) {
        hydrateFromPlans()
        updateAvailableGarments()
        scheduleGenerateAllOutfits(fillMissingOnly: true)
    }

    private func garmentSheet(_ garment: Garment) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.md) {
                    NavigationLink {
                        EditGarmentView(garment: garment)
                    } label: {
                        VStack(spacing: DS.Spacing.sm) {
                            DSGarmentThumbnail(garment, size: .large)
                            
                            Text(garment.displayTitle)
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "planner_go_to_item"))
                    
                    Text(lastWornText(for: garment))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    garmentDetailsSection(for: garment)
                    
                    VStack(spacing: DS.Spacing.md) {
                        Button {
                            markWornToday(garment)
                        } label: {
                            Label(String(localized: "planner_mark_worn_today"), systemImage: "checkmark.circle")
                        }
                        .dsPrimaryButton()
                        
                        HStack(spacing: DS.Spacing.md) {
                            Button {
                                replaceSingleItem(for: garment)
                            } label: {
                                garmentSheetIcon("arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "planner_replace_single_item"))
                            
                            NavigationLink {
                                EditGarmentView(garment: garment)
                            } label: {
                                garmentSheetIcon("pencil")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "planner_go_to_item"))
                            
                            if garment.isCurrentlyUnavailable {
                                Button {
                                    markAvailable(garment)
                                } label: {
                                    garmentSheetIcon("checkmark.circle")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(String(localized: "planner_mark_available_now"))
                            } else {
                                Menu {
                                    Button(String(localized: "planner_unavailable_1d")) {
                                        markUnavailable(garment, days: 1, target: garmentActionTarget)
                                    }
                                    Button(String(localized: "planner_unavailable_2d")) {
                                        markUnavailable(garment, days: 2, target: garmentActionTarget)
                                    }
                                    Button(String(localized: "planner_unavailable_1w")) {
                                        markUnavailable(garment, days: 7, target: garmentActionTarget)
                                    }
                                    Divider()
                                    Button(String(localized: "planner_mark_unavailable_now"), role: .destructive) {
                                        markUnavailable(garment, target: garmentActionTarget)
                                    }
                                } label: {
                                    garmentSheetIcon("moon.zzz")
                                }
                                .accessibilityLabel(String(localized: "wardrobe_snooze_menu"))
                            }
                        }
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
    
    private func garmentSheetIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
            .liquidGlassCircle(interactive: true)
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
            availableSignature: availableGarmentsSignature,
            feedbackExpanded: expandedFeedbackDays.contains(dayIndex),
            aiExplanation: aiExplanationText(for: dayIndex)
        )

        return DayCardContainer(signature: signature) {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                dayTopBar(for: state, dayIndex: dayIndex)

                if state.assignedGarmentIDs.isEmpty {
                    emptyDayOutfitPrompt(dayIndex: dayIndex)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    swipeableOutfitRow(dayIndex: dayIndex, lookTime: .day)
                        .transition(.opacity)
                    availabilityHintsView(for: dayIndex, lookTime: .day)
                }

                if state.useEveningLook {
                    eveningSection(for: dayIndex)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                let changes = changeSuggestions(for: dayIndex, lookTime: .day)
                if !changes.isEmpty {
                    changeSuggestionsView(changes, dayIndex: dayIndex)
                }

                if !state.assignedGarmentIDs.isEmpty {
                    recommendationPreview(for: dayIndex)
                    dayCardActions(for: dayIndex)
                    if isDetailsExpanded(dayIndex) {
                        dayDetailsSection(for: dayIndex)
                            .transition(.opacity)
                    }
                }

                if !state.assignedGarmentIDs.isEmpty {
                    feedbackSection(for: dayIndex)
                        .transition(.opacity)
                }

            }
            .padding(DS.Spacing.md)
            .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
        }
        .equatable()
        // Generate explanations only when their details are requested, not for
        // every hidden/collapsed card during launch. Reuse cached results.
        .task(id: lookExplanationTaskID(for: dayIndex)) {
            await generateLookExplanationIfNeeded(dayIndex: dayIndex)
        }
    }

    private func emptyDayOutfitPrompt(dayIndex: Int) -> some View {
        Button {
            DS.haptic(0.35)
            selectedDayIndex = dayIndex
            refreshDay(dayIndex)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "sparkles")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "planner_empty_day_title"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(String(localized: "planner_empty_day_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(DS.Spacing.sm)
            .liquidGlassSurface(
                cornerRadius: DS.Radius.md,
                interactive: true,
                tint: Color.accentColor.opacity(0.08)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Planner Subtitle (title lives in collapsing nav bar)
    
    private var plannerSubtitle: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
            Text(headerLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, DS.Spacing.xxs)
    }

    private struct UnwornNudge: Equatable {
        let count: Int
        let sampleTitle: String
    }

    private var unwornNudge: UnwornNudge? {
        let signature = [
            availableGarmentsSignature,
            affinityCacheSignature,
            String(Int(currentDate.timeIntervalSince1970 / 86_400)),
            boardState.days.map { forecastKey(for: $0.forecast) }.joined(separator: ",")
        ].joined(separator: "#")
        if let cached = advisorMemo.unwornNudge, cached.signature == signature {
            return cached.value
        }
        let candidates = boardRelevantStaleGarments()
        let value = candidates.first.map {
            UnwornNudge(count: candidates.count, sampleTitle: $0.displayTitle)
        }
        advisorMemo.unwornNudge = (signature, value)
        return value
    }

    private func unwornNudgeCard(_ nudge: UnwornNudge) -> some View {
        HStack(alignment: .center, spacing: DS.Spacing.sm) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "planner_unworn_nudge_title"))
                    .font(.subheadline.weight(.semibold))
                Text(
                    String(
                        format: NSLocalizedString("planner_unworn_nudge_message_format", comment: ""),
                        nudge.count,
                        nudge.sampleTitle
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Button {
                DS.haptic(0.4)
                prioritizeUnwornInToday()
            } label: {
                Text(String(localized: "planner_unworn_nudge_action"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(SoftPressButtonStyle())
            .fixedSize()
        }
        .padding(DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: DS.Radius.md, tint: Color.orange.opacity(0.08))
    }

    /// Stale garments that are temperature-suitable for at least one of the 3 board days.
    private func boardRelevantStaleGarments() -> [Garment] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -21, to: currentDate) ?? currentDate
        return allGarments.filter { garment in
            guard !garment.isCurrentlyUnavailable else { return false }
            guard isRelevantToBoardDays(garment) else { return false }
            let last = latestWearByGarmentID[garment.id] ?? garment.lastWorn
            return last.map { $0 < cutoff } ?? true
        }
    }

    private func isRelevantToBoardDays(_ garment: Garment) -> Bool {
        boardState.days.contains { day in
            garment.isSuitableFor(temperature: day.effectiveTemperature)
        }
    }

    private func prioritizeUnwornInToday() {
        // Prefer long-unworn pieces that fit the 3-day board weather, in unlocked day slots.
        func isStaleAndRelevant(_ garment: Garment) -> Bool {
            guard !garment.isCurrentlyUnavailable else { return false }
            guard isRelevantToBoardDays(garment) else { return false }
            let cutoff = Calendar.current.date(byAdding: .day, value: -21, to: currentDate) ?? currentDate
            let last = latestWearByGarmentID[garment.id] ?? garment.lastWorn
            return last.map { $0 < cutoff } ?? true
        }

        var used = Set(boardState.days.enumerated().flatMap { index, day -> [UUID] in
            if index == 0 { return [] }
            return day.assignedGarmentIDs + day.eveningAssignedGarmentIDs
        })

        for slot in OutfitSlot.allCases {
            guard !boardState.days[0].isLocked(slot) else {
                if let id = boardState.days[0].garmentID(for: slot) { used.insert(id) }
                continue
            }
            let candidates = allGarments
                .filter { slot.allowedCategories.contains($0.category) && isStaleAndRelevant($0) && !used.contains($0.id) }
                .sorted { lhs, rhs in
                    let l = latestWearByGarmentID[lhs.id] ?? lhs.lastWorn ?? .distantPast
                    let r = latestWearByGarmentID[rhs.id] ?? rhs.lastWorn ?? .distantPast
                    return l < r
                }
            if let pick = candidates.first {
                _ = boardState.assignGarment(
                    pick.id,
                    toDay: 0,
                    toSlot: slot,
                    garments: allGarments,
                    allowUnavailable: false
                )
                used.insert(pick.id)
            }
        }
        boardState.days[0].regenVersion += 1
        persistDayPlan(0)
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
            Toggle("planner_allow_repeats", isOn: $allowRepeatedItems)
            Divider()
            Button {
                refreshDay(dayIndex)
            } label: {
                Label(String(localized: "planner_refresh_day"), systemImage: "arrow.clockwise")
            }
            if dayTiming(for: dayIndex) != .future, isConfirmed(dayIndex) {
                Button {
                    unconfirmDay(dayIndex: dayIndex)
                } label: {
                    Label(String(localized: "planner_undo_confirm"), systemImage: "arrow.uturn.left")
                }
            }
            Toggle(isOn: Binding(
                get: { boardState.days[dayIndex].useEveningLook },
                set: { newValue in
                    boardState.days[dayIndex].useEveningLook = newValue
                    let date = boardState.days[dayIndex].date
                    if newValue {
                        CalendarContextPreferences.setEveningOptedOut(false, on: date)
                        generateEveningOutfit(for: dayIndex)
                    } else {
                        if calendarContext(for: dayIndex).suggestEveningLook {
                            CalendarContextPreferences.setEveningOptedOut(true, on: date)
                        }
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
                .frame(width: 44, height: 44)
                .liquidGlassCircle(interactive: true)
        }
        .accessibilityLabel(String(localized: "planner_day_options"))
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
                .liquidGlassPill(interactive: true, tint: tint.opacity(0.10))
        }
        .buttonStyle(.plain)
    }

    private func dayCardActions(for dayIndex: Int) -> some View {
        let expanded = isDetailsExpanded(dayIndex)
        return Button {
            toggleDayDetails(dayIndex)
        } label: {
            HStack {
                Text(String(localized: "planner_why_this_look"))
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: DS.Spacing.sm)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityValue(String(localized: expanded ? "planner_details_expanded" : "planner_details_collapsed"))
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
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if let explanation = aiExplanationText(for: dayIndex) {
                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let hints = combinedHints(for: dayIndex)
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                Label(hint.text, systemImage: hint.iconName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hints.isEmpty, aiExplanationText(for: dayIndex) == nil {
                weatherRecommendationsSection(for: dayIndex)
            }
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
            .liquidGlassPill()
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func recommendationPreview(for dayIndex: Int) -> some View {
        if dayIndex < boardState.days.count, let forecast = boardState.days[dayIndex].forecast {
            let profile = DayTemperatureProfile(from: forecast)
            // Keep the collapsed summary short and stable. AI text is available
            // in the expanded explanation, rather than another competing card.
            let guidance = recommendationGuidance(for: profile)
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xxs) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(guidance)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
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

    // MARK: - AI Look Explanations (Foundation Models, iOS 26+)

    /// Sendable snapshot for the on-device model. Only structured values leave
    /// the view: garment facts, rounded temps, `CalendarOccasionKind` (never
    /// raw event titles) and a couple of taste facts.
    private func lookExplanationRequest(for dayIndex: Int) -> LookExplanationRequest? {
        guard aiLookExplanationsEnabled else { return nil }
        guard dayIndex < boardState.days.count else { return nil }
        let state = boardState.days[dayIndex]
        let garments = state.assignedGarmentIDs.compactMap { garment(for: $0) }
        guard !garments.isEmpty else { return nil }

        let infos = garments.map { g in
            LookExplanationRequest.GarmentInfo(
                title: g.displayTitle,
                category: g.category.rawValue,
                colors: g.safeColorTags.prefix(2).map(\.rawValue),
                warmth: g.warmth
            )
        }

        var weatherInfo: LookExplanationRequest.WeatherInfo?
        if let forecast = state.forecast {
            let profile = DayTemperatureProfile(from: forecast)
            weatherInfo = LookExplanationRequest.WeatherInfo(
                morningTemp: profile.morningTemp,
                afternoonTemp: profile.afternoonTemp,
                eveningTemp: profile.eveningTemp,
                rainProbability: profile.rainProbability,
                condition: String(describing: forecast.condition)
            )
        }

        let occasionKind = calendarContext(for: dayIndex).occasionKind
        return LookExplanationRequest(
            date: state.date,
            lookTime: LookTime.day.rawValue,
            garmentIDs: garments.map { $0.id.uuidString },
            garments: infos,
            weather: weatherInfo,
            occasion: occasionKind == .none ? nil : occasionKind.rawValue,
            tastePoints: lookExplanationTastePoints(),
            languageCode: Locale.current.language.languageCode?.identifier ?? "en"
        )
    }

    /// A couple of dominant taste facts, only once enough wardrobe signal exists.
    private func lookExplanationTastePoints() -> [String] {
        guard cachedTaste.sourceGarmentCount >= 5 else { return [] }
        var points: [String] = []
        let colors = cachedTaste.colorShares(limit: 2).filter { $0.share >= 0.15 }
        if !colors.isEmpty {
            points.append("often wears " + colors.map(\.tag.rawValue).joined(separator: " and "))
        }
        if let style = cachedTaste.styleShares(limit: 1).first, style.share >= 0.2 {
            points.append("prefers a \(style.tag.rawValue.replacingOccurrences(of: "_", with: " ")) style")
        }
        return points
    }

    /// Ready explanation for a day, or nil (template text is shown instead).
    private func aiExplanationText(for dayIndex: Int) -> String? {
        guard let request = lookExplanationRequest(for: dayIndex) else { return nil }
        return lookExplanations[request.cacheKey]?.displayText
    }

    /// `.task(id:)` identity — changes whenever anything that affects the
    /// explanation changes, restarting (and cancelling) the generation task.
    private func lookExplanationTaskID(for dayIndex: Int) -> String {
        guard isDetailsExpanded(dayIndex), scenePhase == .active else {
            return "inactive-\(dayIndex)"
        }
        return lookExplanationRequest(for: dayIndex)?.cacheKey ?? "none-\(dayIndex)"
    }

    private func generateLookExplanationIfNeeded(dayIndex: Int) async {
        guard #available(iOS 26.0, *) else { return }
        guard isDetailsExpanded(dayIndex), scenePhase == .active, !Task.isCancelled else { return }
        guard let request = lookExplanationRequest(for: dayIndex) else { return }
        guard lookExplanations[request.cacheKey] == nil else { return }
        guard LookExplanationAvailability.isSupported else { return }
        let signposter = WearItPerformance.plannerSignposter
        let interval = signposter.beginInterval("requested-explanation", id: signposter.makeSignpostID())
        defer { signposter.endInterval("requested-explanation", interval) }
        // The generation itself loads its session; avoid prewarming a separate
        // disposable session immediately before the actual request.
        guard let result = await LookExplanationService.shared.explanation(for: request) else { return }
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
            lookExplanations[request.cacheKey] = result
        }
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
        .liquidGlassPill()
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

    /// Invalidation key for memoized advisor work. Covers everything that can
    /// change a suggestion: assignments across all days (exclusions), forecast,
    /// wardrobe availability, affinity caches, locks, links and overrides.
    private func advisorSignature(for dayIndex: Int) -> String {
        guard dayIndex < boardState.days.count else { return "" }
        let state = boardState.days[dayIndex]
        var parts: [String] = [
            forecastKey(for: state.forecast),
            availableGarmentsSignature,
            affinityCacheSignature,
            String(calendarContextsVersion),
            String(state.date.timeIntervalSince1970),
            state.overrides.desiredFormality.map(String.init) ?? "-",
            state.eveningLinkedSlots.map(\.rawValue).sorted().joined(separator: ",")
        ]
        for index in boardState.days.indices {
            parts.append(assignedGarmentSignature(for: index))
        }
        for slot in OutfitSlot.allCases {
            parts.append(state.isLocked(slot) ? "1" : "0")
            parts.append(state.isEveningLocked(slot) ? "1" : "0")
        }
        return parts.joined(separator: "#")
    }

    private func changeSuggestions(for dayIndex: Int, lookTime: LookTime) -> [OutfitChangeSuggestion] {
        guard dayIndex < boardState.days.count else { return [] }
        let day = boardState.days[dayIndex]
        let filled = lookTime == .evening ? day.eveningAssignedGarmentIDs : day.assignedGarmentIDs
        guard !filled.isEmpty else { return [] }

        let memoKey = "\(dayIndex)-\(lookTime.rawValue)"
        let signature = advisorSignature(for: dayIndex)
        if let cached = advisorMemo.changeSuggestions[memoKey], cached.signature == signature {
            return cached.value
        }

        let ctx = recoContext(for: dayIndex, isEvening: lookTime == .evening)
        let pool = recommendedPool(referenceDate: day.date, ctx: ctx)
        var excluded = Set<UUID>()
        for (index, other) in boardState.days.enumerated() where index != dayIndex {
            excluded.formUnion(other.assignedGarmentIDs)
            excluded.formUnion(other.eveningAssignedGarmentIDs)
        }
        let value = OutfitChangeAdvisor.suggestions(
            day: day,
            lookTime: lookTime,
            garments: allGarments,
            pool: pool,
            ctx: ctx,
            modelContext: context,
            excludedIDs: excluded
        )
        advisorMemo.changeSuggestions[memoKey] = (signature, value)
        return value
    }

    private func changeSuggestionsView(_ suggestions: [OutfitChangeSuggestion], dayIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(String(localized: "planner_change_title"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(suggestions.prefix(3)) { suggestion in
                Button {
                    applyChangeSuggestion(suggestion, dayIndex: dayIndex)
                } label: {
                    HStack(spacing: DS.Spacing.sm) {
                        Image(systemName: suggestion.slot == .shoes ? "shoe" : "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                String(
                                    format: NSLocalizedString("planner_change_slot_format", comment: ""),
                                    suggestion.slot.title
                                )
                            )
                            .font(.caption.weight(.semibold))
                            Text(suggestion.reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Text(String(localized: "planner_change_apply"))
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xs)
                    .liquidGlassPill(interactive: true, tint: Color.accentColor.opacity(0.08))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func applyChangeSuggestion(_ suggestion: OutfitChangeSuggestion, dayIndex: Int) {
        guard dayIndex < boardState.days.count else { return }
        if suggestion.lookTime == .evening {
            boardState.days[dayIndex].setEveningGarment(suggestion.betterGarmentID, for: suggestion.slot)
        } else {
            boardState.days[dayIndex].setGarment(suggestion.betterGarmentID, for: suggestion.slot)
        }
        persistDayPlan(dayIndex)
        DS.haptic(0.4)
    }

    private func smartHintsView(hints: [PlannerHint]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LiquidGlassGroup(spacing: DS.Spacing.xs) {
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
                        .liquidGlassPill()
                    }
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
        hints.append(contentsOf: calendarContext(for: dayIndex).hints)
        return hints
    }

    private func fitComfortHints(for state: PlannerDayState, dayIndex: Int) -> [PlannerHint] {
        let temp = state.effectiveTemperature
        let garments = state.assignedGarmentIDs.compactMap { garment(for: $0) }

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
        case .calendar:
            return .purple
        }
    }

    private func inspirationLine(for dayIndex: Int) -> String? {
        guard dayIndex < boardState.days.count else { return nil }
        let day = boardState.days[dayIndex]
        let garments = day.assignedGarmentIDs.compactMap { garment(for: $0) }

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

    private func swipeBusyKey(dayIndex: Int, lookTime: LookTime) -> String {
        "\(dayIndex)-\(lookTime.rawValue)"
    }

    private func swipeableOutfitRow(dayIndex: Int, lookTime: LookTime) -> some View {
        let busyKey = swipeBusyKey(dayIndex: dayIndex, lookTime: lookTime)
        let timing = dayTiming(for: dayIndex)
        let status = lookWearStatus(dayIndex: dayIndex, lookTime: lookTime)
        // Status badge / confirm gate use per-slot resolution only — not WearEvent presence.
        let canConfirm = status != .worn
        let confirmTitle: String = {
            switch timing {
            case .future:
                return String(localized: "planner_swipe_will_wear")
            case .today, .past:
                return String(localized: "planner_swipe_did_wear")
            }
        }()
        let notWornTitle: String = {
            switch timing {
            case .future:
                return String(localized: "planner_swipe_will_not_wear")
            case .today, .past:
                return String(localized: "planner_swipe_did_not_wear")
            }
        }()
        let badge: String? = {
            switch status {
            case .worn:
                return String(localized: timing == .future ? "planner_swipe_status_planned" : "planner_swipe_status_worn")
            case .notWorn:
                return String(localized: timing == .future ? "planner_swipe_status_not_planned" : "planner_swipe_status_not_worn")
            case .planned:
                return String(localized: "planner_swipe_status_planned")
            case .none:
                return nil
            }
        }()
        let clearTitle: String? = status == nil ? nil : String(localized: "planner_swipe_clear_status")
        let slotLabel: String = {
            switch lookTime {
            case .day:
                return String(localized: "planner_day_look_a11y")
            case .evening:
                return String(localized: "planner_evening_look")
            }
        }()

        return OutfitLookRow(
            canConfirm: canConfirm,
            isBusy: swipeBusyKeys.contains(busyKey),
            status: status,
            confirmTitle: confirmTitle,
            notWornTitle: notWornTitle,
            replaceTitle: String(localized: "planner_swipe_replace_look"),
            clearStatusTitle: clearTitle,
            statusBadge: badge,
            accessibilitySlotLabel: slotLabel,
            onConfirm: {
                handleSwipeConfirm(dayIndex: dayIndex, lookTime: lookTime)
            },
            onNotWorn: {
                handleSwipeNotWorn(dayIndex: dayIndex, lookTime: lookTime)
            },
            onReplace: {
                handleSwipeReplace(dayIndex: dayIndex, lookTime: lookTime)
            },
            onClearStatus: clearTitle == nil ? nil : {
                handleSwipeClearStatus(dayIndex: dayIndex, lookTime: lookTime)
            }
        ) {
            outfitRow(for: dayIndex, lookTime: lookTime)
        }
    }

    /// DayPlan is source of truth; board mirrors raw fields, with legacy day fallback via plan.
    private func lookWearStatus(dayIndex: Int, lookTime: LookTime) -> LookWearStatus? {
        guard dayIndex < boardState.days.count else { return nil }
        switch lookTime {
        case .day:
            if let local = boardState.days[dayIndex].dayLookWearStatus {
                return local
            }
            // Legacy only: wasWornConfirmed on the current day assignment.
            // Do not use WearEvent presence — that is history and must not stamp a replaced look.
            let date = boardState.days[dayIndex].date
            if let plan = dayPlans.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) {
                return plan.resolvedDayLookWearStatus
            }
            return nil
        case .evening:
            return boardState.days[dayIndex].eveningLookWearStatus
        }
    }

    private func handleSwipeConfirm(dayIndex: Int, lookTime: LookTime) {
        let key = swipeBusyKey(dayIndex: dayIndex, lookTime: lookTime)
        guard !swipeBusyKeys.contains(key) else { return }
        swipeBusyKeys.insert(key)
        defer { swipeBusyKeys.remove(key) }

        switch dayTiming(for: dayIndex) {
        case .future:
            if lookTime == .day {
                confirmPlan(dayIndex: dayIndex)
            }
            setLookWearStatus(dayIndex: dayIndex, lookTime: lookTime, status: .planned)
            showStatusToast(String(localized: "planner_swipe_plan_confirmed_message"))
        case .today, .past:
            if lookTime == .day {
                // Always confirm the *current* assignment so a replacement can update WearEvent garmentIDs.
                // recordWorn updates the existing planner event in place; it does not delete history.
                confirmWorn(dayIndex: dayIndex)
            } else {
                WearHistoryService.recordWorn(
                    date: boardState.days[dayIndex].date,
                    garmentIDs: boardState.days[dayIndex].eveningAssignedGarmentIDs,
                    source: .plannerEvening, context: context
                )
                setLookWearStatus(dayIndex: dayIndex, lookTime: lookTime, status: .worn)
            }
        }
    }

    /// Marks only this look slot as not worn. No taste / affinity / recommendation feedback.
    /// Does not create WearEvent. Does not delete an existing WearEvent.
    private func handleSwipeNotWorn(dayIndex: Int, lookTime: LookTime) {
        let key = swipeBusyKey(dayIndex: dayIndex, lookTime: lookTime)
        guard !swipeBusyKeys.contains(key) else { return }
        guard dayIndex < boardState.days.count else { return }
        swipeBusyKeys.insert(key)
        defer { swipeBusyKeys.remove(key) }

        setLookWearStatus(dayIndex: dayIndex, lookTime: lookTime, status: .notWorn)
        let timing = dayTiming(for: dayIndex)
        showStatusToast(
            String(
                localized: timing == .future
                    ? "planner_swipe_marked_not_planned_message"
                    : "planner_swipe_marked_not_worn_message"
            )
        )
    }

    private func handleSwipeClearStatus(dayIndex: Int, lookTime: LookTime) {
        let key = swipeBusyKey(dayIndex: dayIndex, lookTime: lookTime)
        guard !swipeBusyKeys.contains(key) else { return }
        swipeBusyKeys.insert(key)
        defer { swipeBusyKeys.remove(key) }
        setLookWearStatus(dayIndex: dayIndex, lookTime: lookTime, status: nil)
    }

    private func setLookWearStatus(dayIndex: Int, lookTime: LookTime, status: LookWearStatus?) {
        guard dayIndex < boardState.days.count else { return }
        let date = boardState.days[dayIndex].date
        let plan = DayPlanService.shared.planFor(date: date, context: context)
        switch lookTime {
        case .day:
            boardState.days[dayIndex].dayLookWearStatus = status
            plan.applyDayLookWearStatus(status)
        case .evening:
            boardState.days[dayIndex].eveningLookWearStatus = status
            plan.applyEveningLookWearStatus(status)
        }
        persistDayPlan(dayIndex, immediate: true)
    }

    /// Neutral replace for one look slot only. No taste / affinity / feedback side effects.
    private func handleSwipeReplace(dayIndex: Int, lookTime: LookTime) {
        let key = swipeBusyKey(dayIndex: dayIndex, lookTime: lookTime)
        guard !swipeBusyKeys.contains(key) else { return }
        guard dayIndex < boardState.days.count else { return }
        swipeBusyKeys.insert(key)
        defer { swipeBusyKeys.remove(key) }

        let didChange = replaceLookNeutrally(dayIndex: dayIndex, lookTime: lookTime)
        if didChange {
            // Reset only this slot. For day, applyDayLookWearStatus(nil) also clears
            // wasWornConfirmed so the replacement cannot inherit .worn via legacy fallback.
            // WearEvents are preserved.
            setLookWearStatus(dayIndex: dayIndex, lookTime: lookTime, status: nil)
            showStatusToast(String(localized: "planner_swipe_replaced_slot_message"))
        }
    }

    private func showStatusToast(_ message: String) {
        withAnimation(DS.Animation.standard) {
            statusToast = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(DS.Animation.standard) {
                if statusToast == message {
                    statusToast = nil
                }
            }
        }
    }
    
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

        return HStack(spacing: DS.Spacing.sm) {
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
                    if let id, let garment = garment(for: id) {
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
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.92).combined(with: .opacity),
                            removal: .opacity
                        ))
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
        .animation(reduceMotion ? nil : DS.Animation.standard, value: assignedSlots)
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
            Image(systemName: "plus")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: dimension, height: dimension)
                .liquidGlassSurface(cornerRadius: DS.Radius.tile, interactive: true)
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
            // No drop shadow: the glass pill provides enough separation, and
            // per-tile shadows add compositing layers during scroll.
            .liquidGlassPill()
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
            .liquidGlassPill()
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

            if boardState.days[dayIndex].eveningAssignedGarmentIDs.isEmpty {
                outfitRow(for: dayIndex, lookTime: .evening)
            } else {
                swipeableOutfitRow(dayIndex: dayIndex, lookTime: .evening)
            }
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
            let diurnal = DiurnalTemps(profile: profile)
            let effective = lookTime == .evening ? profile.eveningTemp : profile.effectiveTemp
            let policy = TemperatureComfort.outerLayerPolicy(
                temperatureC: effective,
                isRaining: profile.rainProbability > 0.35,
                lookTime: lookTime,
                diurnal: diurnal
            )
            switch policy {
            case .suppress:
                return false
            case .lightOnly, .prefer:
                if lookTime == .evening {
                    return profile.eveningJacketRecommended || profile.layeringRecommended || profile.rainProbability > 0.35
                }
                return profile.layeringRecommended || profile.lightLayeringRecommended || profile.rainProbability > 0.35
            }
        }

        return (lookTime == .evening ? state.effectiveTemperature - 2 : state.effectiveTemperature) < RecoContext.outerLayerTempThresholdC
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
                    .shadow(
                        color: isLocked ? DS.Accent.warmth.opacity(0.1) : .clear,
                        radius: isLocked ? 4 : 0
                    )
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
                garmentActionTarget = SlotTarget(dayIndex: dayIndex, slot: slot, lookTime: lookTime)
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tileAccessibilityLabel(
                garment: garment,
                slot: slot,
                status: status,
                isLocked: isLocked,
                isLinked: isLinked
            ))
            .accessibilityAddTraits(.isButton)

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

    private func tileAccessibilityLabel(
        garment: Garment,
        slot: OutfitSlot,
        status: AvailabilityStatus,
        isLocked: Bool,
        isLinked: Bool
    ) -> String {
        var parts: [String] = [garment.displayTitle, slot.title]
        switch status {
        case .available:
            break
        case .worn:
            parts.append(String(localized: "planner_badge_worn"))
        case .unavailable:
            parts.append(String(localized: "planner_badge_unavailable"))
        case .cooldown:
            parts.append(String(localized: "planner_badge_cooldown"))
        }
        if isLinked {
            parts.append(String(localized: "a11y_tile_linked"))
        }
        if isLocked {
            parts.append(String(localized: "a11y_tile_locked"))
        }
        return parts.joined(separator: ", ")
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
                    replaceSlot(dayIndex: dayIndex, slot: slot, lookTime: lookTime)
                } label: {
                    Label(String(localized: "planner_suggest_better"), systemImage: "sparkles")
                }

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
                    markUnavailable(garment, target: SlotTarget(dayIndex: dayIndex, slot: slot, lookTime: lookTime))
                } label: {
                    Label(String(localized: "planner_mark_unavailable_now"), systemImage: "xmark.circle")
                }
            }
        }

        Group {
            Button {
                garmentActionTarget = SlotTarget(dayIndex: dayIndex, slot: slot, lookTime: lookTime)
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
                    .shadow(
                        color: isLocked ? DS.Accent.warmth.opacity(0.1) : .clear,
                        radius: isLocked ? 4 : 0
                    )
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
                .liquidGlassCircle(interactive: true)
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

    @ViewBuilder
    private func feedbackSection(for dayIndex: Int) -> some View {
        let state = boardState.days[dayIndex]
        // Positive feedback already saved → keep the look card clean.
        if state.feedback == .loved {
            EmptyView()
        } else {
            let isExpanded = expandedFeedbackDays.contains(dayIndex)
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Button {
                    DS.haptic(0.3)
                    withAnimation(DS.Animation.fast) {
                        if isExpanded {
                            expandedFeedbackDays.remove(dayIndex)
                        } else {
                            expandedFeedbackDays.insert(dayIndex)
                        }
                    }
                } label: {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                        Text(String(localized: "planner_what_do_you_think"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SoftPressButtonStyle())
                .accessibilityHint(String(localized: "planner_feedback_toggle_hint"))

                if isExpanded {
                    // Primary: love / not my style
                    HStack(spacing: DS.Spacing.sm) {
                        FeedbackButton(
                            label: String(localized: "planner_love_it"),
                            icon: "heart.fill",
                            color: .pink,
                            isSelected: state.feedback == .loved
                        ) {
                            withAnimation(DS.Animation.standard) {
                                submitFeedback(for: dayIndex, rating: .loved)
                                expandedFeedbackDays.remove(dayIndex)
                            }
                        }

                        FeedbackButton(
                            label: String(localized: "planner_not_my_style"),
                            icon: "arrow.clockwise",
                            color: .orange,
                            isSelected: state.feedback == .rejected
                        ) {
                            withAnimation(DS.Animation.fast) {
                                submitFeedback(for: dayIndex, rating: .rejected)
                                expandedFeedbackDays.remove(dayIndex)
                            }
                        }
                    }

                    // Secondary tweaks — compact, optional
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Spacing.xs) {
                            TempFeedbackButton(
                                feedback: .tooWarm,
                                isSelected: state.temperatureFeedback == .tooWarm
                            ) {
                                submitTemperatureFeedback(for: dayIndex, feedback: .tooWarm)
                            }

                            TempFeedbackButton(
                                feedback: .tooCold,
                                isSelected: state.temperatureFeedback == .tooCold
                            ) {
                                submitTemperatureFeedback(for: dayIndex, feedback: .tooCold)
                            }

                            LearningFeedbackChip(
                                label: String(localized: "planner_too_formal"),
                                icon: "briefcase.fill",
                                color: .purple
                            ) {
                                submitFormalityFeedback(for: dayIndex, direction: -1)
                            }

                            LearningFeedbackChip(
                                label: String(localized: "planner_too_casual"),
                                icon: "tshirt.fill",
                                color: .blue
                            ) {
                                submitFormalityFeedback(for: dayIndex, direction: 1)
                            }
                        }
                    }
                }
            }
            .padding(DS.Spacing.sm)
            .liquidGlassSurface(cornerRadius: DS.Radius.md, tint: Color.accentColor.opacity(0.025))
            .animation(DS.Animation.fast, value: isExpanded)
        }
    }

    private var plannerProfileAvatar: some View {
        let emoji = activeProfile?.avatarEmoji ?? "🧑🏻"
        return ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.14))
                .frame(width: 30, height: 30)
            Text(emoji)
                .font(.system(size: 16))
        }
        // HIG minimum touch target without changing the 30pt visual.
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
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
        _ = refreshDayLook(dayIndex)
        if dayIndex < boardState.days.count, boardState.days[dayIndex].useEveningLook {
            _ = refreshEveningLook(dayIndex)
        }
    }

    /// Regenerates the day look only. No taste / affinity / recommendation feedback.
    @discardableResult
    private func refreshDayLook(_ dayIndex: Int) -> Bool {
        guard dayIndex < boardState.days.count else { return false }
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

        // IDs used on other days: tops/bottoms are hard-excluded, shoes/outer/
        // accessories only penalized (wearing the same shoes two days running is fine).
        let crossDay = crossDayExclusions(excludingDay: dayIndex)
        var baseExcludedIDs = crossDay.hard
        
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
        let lockedCats = lockedCategories(for: dayIndex, lookTime: .day)
        let pool = recommendedPool(referenceDate: referenceDate, ctx: ctx)
            .filter { !lockedCats.contains($0.category) }

        // Cycle through the wardrobe on repeated taps instead of ping-ponging
        // between the two highest-scoring items.
        let rotationExcludedIDs = rotationExclusions(
            key: rotationKey(dayIndex, .day),
            replacedIDs: currentUnlockedIDs,
            pool: pool,
            alreadyExcluded: baseExcludedIDs.union(cooldownExcludedIDs)
        )
        let excludedMerged = baseExcludedIDs.union(cooldownExcludedIDs).union(rotationExcludedIDs)
        
        let outfit = AIRecommender.shared.suggestOutfit(
            from: pool,
            ctx: ctx,
            modelContext: context,
            excludedIDs: excludedMerged,
            penalizedIDs: crossDay.soft
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

        return didChange
    }

    /// Regenerates the evening look only. No taste / affinity / recommendation feedback.
    @discardableResult
    private func refreshEveningLook(_ dayIndex: Int) -> Bool {
        guard dayIndex < boardState.days.count else { return false }
        guard boardState.days[dayIndex].useEveningLook else { return false }

        let previousIDs = Set(boardState.days[dayIndex].eveningAssignedGarmentIDs)
        generateEveningOutfit(for: dayIndex, rotate: true)
        let nextIDs = Set(boardState.days[dayIndex].eveningAssignedGarmentIDs)
        let didChange = previousIDs != nextIDs
        if !didChange, !previousIDs.isEmpty {
            boardState.alertMessage = String(localized: "planner_no_alternatives")
            boardState.showUnavailableAlert = true
        }
        return didChange
    }

    /// Neutral swipe-left replacement for one look slot. Does not record dislike,
    /// DismissedOutfit, RecommendationEvent, TasteProfile, or affinity updates.
    @discardableResult
    private func replaceLookNeutrally(dayIndex: Int, lookTime: LookTime) -> Bool {
        switch lookTime {
        case .day:
            return refreshDayLook(dayIndex)
        case .evening:
            return refreshEveningLook(dayIndex)
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
        let state = boardState.days[dayIndex]
        let memoKey = "\(dayIndex)|\(lookTime.rawValue)|\(garment.id.uuidString)"
        let signature = [
            forecastKey(for: state.forecast),
            availableGarmentsSignature,
            affinityCacheSignature,
            String(calendarContextsVersion),
            String(state.date.timeIntervalSince1970)
        ].joined(separator: "#")
        if let cached = advisorMemo.availability[memoKey], cached.signature == signature {
            return cached.value
        }
        let ctx = recoContext(for: dayIndex, isEvening: lookTime == .evening)
        let value = AvailabilityService.availabilityStatus(
            for: garment,
            on: state.date,
            ctx: ctx,
            latestWearMap: latestWearByGarmentID
        )
        advisorMemo.availability[memoKey] = (signature, value)
        return value
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
        let base = AvailabilityService.recommendedItemsForSlot(
            slot,
            garments: candidates,
            date: referenceDate,
            ctx: ctx,
            latestWearMap: latestWearByGarmentID
        )
        let day = boardState.days[dayIndex]
        let pairedIDs = lookTime == .evening ? day.eveningAssignedGarmentIDs : day.assignedGarmentIDs
        let paired = pairedIDs.compactMap { id in allGarments.first { $0.id == id } }
        let ranked = AIRecommender.shared.suggest(
            from: base,
            k: min(12, max(base.count, 1)),
            ctx: ctx,
            modelContext: context,
            pairedWith: paired
        )
        return ranked.isEmpty ? base : ranked
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

    /// True when another board day already uses this garment *and* the category
    /// is one we keep unique across days. Shoes/outer/accessories may repeat.
    private func isGarmentUsedElsewhere(_ id: UUID, excludingDay dayIndex: Int) -> Bool {
        if let garment = garmentsByID[id], flexibleReuseCategories.contains(garment.category) {
            return false
        }
        for (index, day) in boardState.days.enumerated() where index != dayIndex {
            if day.assignedGarmentIDs.contains(id) || day.eveningAssignedGarmentIDs.contains(id) {
                return true
            }
        }
        return false
    }

    private var preferredFormality: Int {
        let value = activeProfile?.preferredFormality ?? 3
        return min(max(value, 1), 5)
    }

    private var activeProfile: UserProfile? {
        CurrentUser.activeProfile(from: profiles, userIdentifier: auth.userIdentifier)
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

    // MARK: - Variety

    /// Categories that may repeat on consecutive board days. Cross-day use is a
    /// soft score penalty for these instead of a hard exclusion.
    private var flexibleReuseCategories: Set<Category> {
        allowRepeatedItems ? Set(Category.allCases) : [.shoes, .outer, .accessory]
    }

    /// Garments assigned on *other* board days (day + evening), split into hard
    /// exclusions (tops/bottoms) and soft penalties (shoes/outer/accessories).
    private func crossDayExclusions(excludingDay dayIndex: Int) -> (hard: Set<UUID>, soft: Set<UUID>) {
        var ids = Set<UUID>()
        for (index, day) in boardState.days.enumerated() where index != dayIndex {
            ids.formUnion(day.assignedGarmentIDs)
            ids.formUnion(day.eveningAssignedGarmentIDs)
        }
        return splitBySoftReuse(ids)
    }

    private func splitBySoftReuse(_ ids: Set<UUID>) -> (hard: Set<UUID>, soft: Set<UUID>) {
        var hard = Set<UUID>()
        var soft = Set<UUID>()
        for id in ids {
            if let garment = garmentsByID[id], flexibleReuseCategories.contains(garment.category) {
                soft.insert(id)
            } else {
                hard.insert(id)
            }
        }
        return (hard, soft)
    }

    /// Evening exclusions: the same day's day-look is always hard-excluded
    /// (except linked slots); other days follow the hard/soft split.
    private func eveningExclusions(for dayIndex: Int) -> (hard: Set<UUID>, soft: Set<UUID>) {
        let crossDay = crossDayExclusions(excludingDay: dayIndex)
        var hard = crossDay.hard
        var soft = crossDay.soft
        let day = boardState.days[dayIndex]
        if allowRepeatedItems {
            soft.formUnion(day.assignedGarmentIDs)
        } else {
            hard.formUnion(day.assignedGarmentIDs)
        }
        hard.formUnion(day.eveningAssignedGarmentIDs)
        for slot in day.eveningLinkedSlots {
            if let dayID = day.garmentID(for: slot) {
                hard.remove(dayID)
            }
        }
        return (hard, soft.subtracting(hard))
    }

    private func rotationKey(_ dayIndex: Int, _ lookTime: LookTime, slot: OutfitSlot? = nil) -> String {
        let date = Calendar.current.startOfDay(for: boardState.days[dayIndex].date).timeIntervalSince1970
        return "\(Int(date))|\(lookTime.rawValue)|\(slot?.rawValue ?? "look")"
    }

    /// Remembers what was just replaced and returns the IDs to exclude so
    /// repeated "replace" taps walk through the wardrobe. When a category has
    /// nothing unseen left, its history is reset so the cycle restarts.
    private func rotationExclusions(
        key: String,
        replacedIDs: [UUID],
        pool: [Garment],
        alreadyExcluded: Set<UUID>
    ) -> Set<UUID> {
        var history = replacementRotation[key] ?? []
        for id in replacedIDs where !history.contains(id) {
            history.append(id)
        }
        if history.count > 24 {
            history.removeFirst(history.count - 24)
        }

        let historySet = Set(history)
        var excluded = Set<UUID>()
        let candidatesByCategory = Dictionary(
            grouping: pool.filter { !alreadyExcluded.contains($0.id) },
            by: \.category
        )
        for (_, candidates) in candidatesByCategory {
            let seen = candidates.filter { historySet.contains($0.id) }
            let hasUnseen = candidates.count > seen.count
            if hasUnseen {
                excluded.formUnion(seen.map(\.id))
            } else {
                let seenIDs = Set(seen.map(\.id))
                history.removeAll { seenIDs.contains($0) }
            }
        }

        replacementRotation[key] = history
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
        let profile = activeProfile
        let baseFormality = state.overrides.desiredFormality ?? preferredFormality
        let calendar = calendarContext(for: dayIndex)
        let desiredFormality = min(5, max(1, baseFormality + calendar.formalityBump(isEvening: isEvening)))

        let temperatureC: Double
        let diurnal: DiurnalTemps?
        if let override = state.overrides.temperatureC {
            diurnal = nil
            temperatureC = override + calendar.temperatureBiasC
        } else if let forecast = state.forecast {
            let profile = DayTemperatureProfile(from: forecast)
            diurnal = DiurnalTemps(profile: profile)
            if isEvening {
                temperatureC = profile.eveningTemp + calendar.temperatureBiasC
            } else {
                temperatureC = profile.effectiveTemp + calendar.temperatureBiasC
            }
        } else {
            diurnal = nil
            temperatureC = state.effectiveTemperature + calendar.temperatureBiasC
        }

        return RecoContext(
            desiredFormality: desiredFormality,
            temperatureC: temperatureC,
            isRaining: state.effectiveIsRaining,
            now: state.date,
            profileID: profile?.id,
            warmthSensitivity: profile?.warmthSensitivity ?? 3,
            rainTolerance: profile?.rainTolerance ?? 3,
            lookTime: isEvening ? .evening : .day,
            taste: cachedTaste,
            combination: cachedCombination,
            occasionKind: calendar.occasionKind,
            diurnal: diurnal,
            thermalSamples: state.overrides.temperatureC == nil
                ? (state.forecast?.thermalSamples(for: isEvening ? .evening : .day).map {
                    ThermalWeatherSample(
                        date: $0.date,
                        temperatureC: $0.temperatureC + calendar.temperatureBiasC,
                        apparentTemperatureC: $0.apparentTemperatureC.map { $0 + calendar.temperatureBiasC },
                        rainProbability: $0.rainProbability
                    )
                } ?? []) : [],
            allowRepeatedItems: allowRepeatedItems
        )
    }

    private func calendarContext(for dayIndex: Int) -> DayCalendarContext {
        if let cached = cachedCalendarContexts[dayIndex] {
            return cached
        }
        guard dayIndex < boardState.days.count else { return .empty }
        return CalendarContextService.shared.context(for: boardState.days[dayIndex].date)
    }

    private func refreshCalendarContextsAndApplyEvening() {
        CalendarContextService.shared.invalidateCache()
        var next: [Int: DayCalendarContext] = [:]
        for index in boardState.days.indices {
            let date = boardState.days[index].date
            let context = CalendarContextService.shared.context(for: date)
            next[index] = context

            guard context.suggestEveningLook else { continue }
            guard !CalendarContextPreferences.isEveningOptedOut(on: date) else { continue }
            guard !boardState.days[index].useEveningLook else { continue }

            boardState.days[index].useEveningLook = true
            persistDayPlan(index)
        }
        cachedCalendarContexts = next
        calendarContextsVersion += 1
    }

    private func refreshAffinityCaches() {
        let signature = "\(allGarments.count)|\(wearEvents.count)|\(dismissedOutfits.count)|\(recommendationEvents.count)|\(allGarments.first?.id.uuidString ?? "")|\(wearEvents.first?.id.uuidString ?? "")"
        guard signature != affinityCacheSignature else { return }
        affinityCacheSignature = signature
        cachedTaste = TasteAffinityBuilder.build(from: allGarments)
        let recentRejections = recommendationEvents
            .filter { $0.kind == .notMyStyle }
            .prefix(40)
            .map { $0 }
        cachedCombination = CombinationAffinityBuilder.build(
            wearEvents: wearEvents,
            dismissed: dismissedOutfits,
            rejectedEvents: Array(recentRejections)
        )
        cachedLatestWearByGarmentID = WearHistoryService.latestWearMap(events: wearEvents)
        TasteProfileStore.persist(cachedTaste, profileID: activeProfile?.id, context: context)
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
                allowUnavailable: allowUnavailable,
                allowRepeats: allowRepeatedItems || flexibleReuseCategories.contains(garment.category)
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

    private func replaceSlot(dayIndex: Int, slot: OutfitSlot, lookTime: LookTime, replacingUnavailable: Bool = false) {
        guard dayIndex < boardState.days.count else { return }
        if !replacingUnavailable, lookTime == .day, boardState.days[dayIndex].isLocked(slot) {
            boardState.alertMessage = String(localized: "swap_error_locked")
            boardState.showUnavailableAlert = true
            return
        }
        if !replacingUnavailable, lookTime == .evening, boardState.days[dayIndex].isEveningLocked(slot) {
            boardState.alertMessage = String(localized: "swap_error_locked")
            boardState.showUnavailableAlert = true
            return
        }
        if !replacingUnavailable, lookTime == .evening, isEveningLinked(dayIndex: dayIndex, slot: slot) {
            boardState.alertMessage = String(localized: "swap_error_locked")
            boardState.showUnavailableAlert = true
            return
        }

        let referenceDate = boardState.days[dayIndex].date
        let ctx = recoContext(for: dayIndex, isEvening: lookTime == .evening)
        let state = boardState.days[dayIndex]
        let currentID = lookTime == .evening ? state.eveningGarmentID(for: slot) : state.garmentID(for: slot)

        // Same-day items (day + evening) are hard-excluded; other days follow the
        // hard/soft split so shoes/outerwear can repeat across consecutive days.
        let crossDay = crossDayExclusions(excludingDay: dayIndex)
        var baseExcludedIDs = crossDay.hard
        baseExcludedIDs.formUnion(state.assignedGarmentIDs)
        baseExcludedIDs.formUnion(state.eveningAssignedGarmentIDs)
        if let currentID {
            baseExcludedIDs.remove(currentID)
        }

        let cooldownExcludedIDs = buildCooldownExcludedIDs(
            referenceDate: referenceDate,
            ctx: ctx,
            baseExcludedIDs: baseExcludedIDs
        )

        let pool = recommendedPool(referenceDate: referenceDate, ctx: ctx)
            .filter { slot.allowedCategories.contains($0.category) }
            .filter { $0.id != currentID }
        var excludedMerged = baseExcludedIDs.union(cooldownExcludedIDs)
        if let currentID {
            excludedMerged.insert(currentID)
            excludedMerged.formUnion(
                rotationExclusions(
                    key: rotationKey(dayIndex, lookTime, slot: slot),
                    replacedIDs: [currentID],
                    pool: pool,
                    alreadyExcluded: excludedMerged
                )
            )
        }
        let pairedWith: [Garment] = {
            let ids = lookTime == .evening
                ? state.eveningAssignedGarmentIDs
                : state.assignedGarmentIDs
            return ids.compactMap { id in
                guard id != currentID else { return nil }
                return allGarments.first { $0.id == id }
            }
        }()
        let suggestions = AIRecommender.shared.suggest(
            from: pool,
            k: 1,
            ctx: ctx,
            modelContext: context,
            excludedIDs: excludedMerged,
            penalizedIDs: crossDay.soft,
            pairedWith: pairedWith
        )

        if let replacement = suggestions.first {
            if lookTime == .evening {
                boardState.days[dayIndex].setEveningGarment(replacement.id, for: slot)
            } else {
                boardState.days[dayIndex].setGarment(replacement.id, for: slot)
            }
            if !replacingUnavailable, let currentID {
                recordReplacement(
                    dayIndex: dayIndex,
                    replacedID: currentID,
                    replacementID: replacement.id,
                    lookTime: lookTime
                )
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

    /// Swapping a suggested piece away is a weak "not this" signal for user
    /// understanding (gaps, stats). Logged only, no model update, and saved with
    /// the next debounced planner persist instead of its own CloudKit push.
    private func recordReplacement(dayIndex: Int, replacedID: UUID, replacementID: UUID, lookTime: LookTime) {
        guard dayIndex < boardState.days.count else { return }
        let plan = DayPlanService.shared.planFor(date: boardState.days[dayIndex].date, context: context)
        RecommendationEventStore.record(
            kind: .replaced,
            selectedGarmentIDs: [replacedID],
            shownGarmentIDs: [replacementID],
            dayPlanID: plan.id,
            context: recoContext(for: dayIndex, isEvening: lookTime == .evening),
            modelContext: context,
            save: false
        )
    }

    private func findAssignment(for garmentID: UUID) -> (dayIndex: Int, slot: OutfitSlot)? {
        for (dayIndex, day) in boardState.days.enumerated() {
            for (slot, assignment) in day.slots where assignment.garmentID == garmentID {
                return (dayIndex, slot)
            }
        }
        return nil
    }
    
    /// Cancels any in-flight generation and starts a new chunked pass.
    /// Chunking (Task.yield between days) keeps the main actor responsive so
    /// the first frame of the tab isn't blocked by 3+ full recommendation passes.
    private func scheduleGenerateAllOutfits(fillMissingOnly: Bool) {
        outfitGenerationTask?.cancel()
        outfitGenerationTask = Task {
            await generateAllOutfits(fillMissingOnly: fillMissingOnly)
        }
    }

    private func generateAllOutfits(fillMissingOnly: Bool) async {
        let signposter = WearItPerformance.plannerSignposter
        let interval = signposter.beginInterval("planner-generation", id: signposter.makeSignpostID())
        defer { signposter.endInterval("planner-generation", interval) }
        refreshCalendarContextsAndApplyEvening()
        for i in 0..<boardState.days.count {
            guard !Task.isCancelled else { return }
            generateDayOutfit(dayIndex: i, fillMissingOnly: fillMissingOnly)
            await Task.yield()
        }

        for i in 0..<boardState.days.count {
            guard !Task.isCancelled else { return }
            generateEveningOutfitIfNeeded(dayIndex: i, fillMissingOnly: fillMissingOnly)
            await Task.yield()
        }
    }

    private func generateDayOutfit(dayIndex i: Int, fillMissingOnly: Bool) {
        guard i < boardState.days.count else { return }
        let state = boardState.days[i]
        let signposter = WearItPerformance.plannerSignposter
        let missingSlots = Set(OutfitSlot.allCases.filter {
            !state.isLocked($0) && state.garmentID(for: $0) == nil
        })
        if fillMissingOnly, missingSlots.isEmpty {
            signposter.emitEvent("day-generation-skipped")
            return
        }
        let ctx = recoContext(for: i)
        let referenceDate = state.date
        let crossDay = crossDayExclusions(excludingDay: i)
        let baseExcludedIDs = crossDay.hard
        let cooldownExcludedIDs = buildCooldownExcludedIDs(
            referenceDate: referenceDate,
            ctx: ctx,
            baseExcludedIDs: baseExcludedIDs
        )
        let excludedMerged = baseExcludedIDs.union(cooldownExcludedIDs)
        let lockedCats = lockedCategories(for: i, lookTime: .day)
        let pool = recommendedPool(referenceDate: referenceDate, ctx: ctx)
            .filter { !lockedCats.contains($0.category) }

        // Optional slots (e.g. an outer layer in summer) must not trigger a
        // complete recommendation pass that cannot change any assignment.
        // Keep the full pool for partial looks so combination scoring stays intact.
        if fillMissingOnly {
            let canFillMissingSlot = pool.contains { garment in
                guard missingSlots.contains(OutfitSlot.from(category: garment.category)),
                      !excludedMerged.contains(garment.id),
                      !garment.isBlocked,
                      !garment.isCurrentlyUnavailable else { return false }
                if garment.category == .outer {
                    return TemperatureComfort.outerGarmentAllowed(garment, policy: ctx.outerLayerPolicy)
                }
                return true
            }
            guard canFillMissingSlot else {
                boardState.days[i].insufficientItemsWarning = state.assignedGarmentIDs.isEmpty && i > 0
                signposter.emitEvent("day-generation-skipped")
                return
            }
        }

        let interval = signposter.beginInterval("day-recommendation", id: signposter.makeSignpostID())
        defer { signposter.endInterval("day-recommendation", interval) }
        let outfit = AIRecommender.shared.suggestOutfit(
            from: pool,
            ctx: ctx,
            modelContext: context,
            excludedIDs: excludedMerged,
            penalizedIDs: crossDay.soft
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

    /// - Parameter rotate: when true (user-initiated replace), remembers the
    ///   outgoing evening items so repeated taps cycle through alternatives.
    private func generateEveningOutfit(for dayIndex: Int, rotate: Bool = false) {
        guard dayIndex < boardState.days.count else { return }
        guard boardState.days[dayIndex].useEveningLook else { return }

        let referenceDate = boardState.days[dayIndex].date
        let ctx = recoContext(for: dayIndex, isEvening: true)
        let (baseExcludedIDs, softPenalizedIDs) = eveningExclusions(for: dayIndex)
        let previousEveningIDs = boardState.days[dayIndex].eveningAssignedGarmentIDs

        let cooldownExcludedIDs = buildCooldownExcludedIDs(
            referenceDate: referenceDate,
            ctx: ctx,
            baseExcludedIDs: baseExcludedIDs
        )
        let lockedCats = lockedCategories(for: dayIndex, lookTime: .evening)
        let pool = recommendedPool(referenceDate: referenceDate, ctx: ctx)
            .filter { !lockedCats.contains($0.category) }
        var excludedMerged = baseExcludedIDs.union(cooldownExcludedIDs)
        if rotate {
            excludedMerged.formUnion(previousEveningIDs)
            excludedMerged.formUnion(
                rotationExclusions(
                    key: rotationKey(dayIndex, .evening),
                    replacedIDs: previousEveningIDs,
                    pool: pool,
                    alreadyExcluded: excludedMerged
                )
            )
        }
        let outfit = AIRecommender.shared.suggestOutfit(
            from: pool,
            ctx: ctx,
            modelContext: context,
            excludedIDs: excludedMerged,
            penalizedIDs: softPenalizedIDs
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

    private func generateEveningOutfitIfNeeded(dayIndex i: Int, fillMissingOnly: Bool) {
        guard i < boardState.days.count else { return }
        guard boardState.days[i].useEveningLook else { return }

        let currentEveningIDs = boardState.days[i].eveningAssignedGarmentIDs
        if fillMissingOnly, !currentEveningIDs.isEmpty {
            return
        }

        let ctx = recoContext(for: i, isEvening: true)
        let referenceDate = boardState.days[i].date
        let (baseExcludedIDs, softPenalizedIDs) = eveningExclusions(for: i)
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
            excludedIDs: excludedMerged,
            penalizedIDs: softPenalizedIDs
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
                   let garment = allGarments.first(where: { $0.id == id }) {
                    boardState.days[dayIndex].setGarment(garment.id, for: slot, locked: lockedSlots.contains(slot))
                    usedIDs.insert(garment.id)
                }
            }
        } else {
            var remainingIDs = plan.selectedGarmentIDs
            for slot in OutfitSlot.allCases {
                if let id = remainingIDs.first(where: { id in
                    guard let garment = allGarments.first(where: { $0.id == id }) else { return false }
                    return OutfitSlot.from(category: garment.category) == slot
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
                   let garment = allGarments.first(where: { $0.id == id }) {
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

        boardState.days[dayIndex].feedback = plan.feedback
        boardState.days[dayIndex].temperatureFeedback = plan.temperatureFeedback
        boardState.days[dayIndex].dayLookWearStatus = plan.dayLookWearStatus
        boardState.days[dayIndex].eveningLookWearStatus = plan.eveningLookWearStatus
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
        if let feedback = day.feedback {
            plan.setFeedback(feedback)
        }
        if let temperatureFeedback = day.temperatureFeedback {
            plan.setTemperatureFeedback(temperatureFeedback)
        }
        // Per-slot wear status (optional). Writing evening must not touch wasWornConfirmed.
        plan.dayLookWearStatus = day.dayLookWearStatus
        plan.eveningLookWearStatus = day.eveningLookWearStatus
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
        guard dayIndex < boardState.days.count else { return }
        let previousRating = boardState.days[dayIndex].feedback
        guard previousRating != rating else { return }
        DS.haptic(0.5)
        boardState.days[dayIndex].feedback = rating
        
        // Update garment love scores
        let garmentIDs = boardState.days[dayIndex].assignedGarmentIDs
        for garment in allGarments where garmentIDs.contains(garment.id) {
            let delta = loveScoreAdjustment(for: rating) - loveScoreAdjustment(for: previousRating)
            garment.loveScore = max(0, min(100, garment.loveScore + delta))
        }

        let reward: Double
        switch rating {
        case .loved: reward = 0.92
        case .worn: reward = 0.75
        case .rejected: reward = 0.18
        case .neutral: reward = 0.5
        }
        let kind: RecommendationFeedbackKind
        switch rating {
        case .loved: kind = .loved
        case .rejected: kind = .notMyStyle
        case .worn: kind = .worn
        case .neutral: kind = .justRight
        }
        learnFromPlannerFeedback(dayIndex: dayIndex, kind: kind, reward: reward)
        persistDayPlan(dayIndex, immediate: true)
        try? context.save()

        if rating == .rejected {
            banCurrentOutfitCombination(dayIndex: dayIndex)
            refreshAffinityCaches()
            refreshDay(dayIndex)
        } else if rating == .loved || rating == .worn {
            refreshAffinityCaches()
        }
    }

    private func banCurrentOutfitCombination(dayIndex: Int) {
        guard dayIndex < boardState.days.count else { return }
        let selected = boardState.days[dayIndex].assignedGarmentIDs.compactMap { id in
            allGarments.first { $0.id == id }
        }
        guard selected.count >= 2 else { return }
        let key = outfitKey(for: selected)
        let existing = dismissedOutfits.contains { $0.key == key }
        guard !existing else { return }
        context.insert(DismissedOutfit(key: key))
        try? context.save()
    }

    private func submitTemperatureFeedback(for dayIndex: Int, feedback: TemperatureFeedback) {
        guard dayIndex < boardState.days.count else { return }
        guard boardState.days[dayIndex].temperatureFeedback != feedback else { return }
        DS.haptic(0.4)
        boardState.days[dayIndex].temperatureFeedback = feedback

        let kind: RecommendationFeedbackKind
        switch feedback {
        case .tooWarm: kind = .tooWarm
        case .tooCold: kind = .tooCold
        case .justRight:
            learnFromPlannerFeedback(dayIndex: dayIndex, kind: .justRight, reward: 0.7)
            persistDayPlan(dayIndex, immediate: true)
            return
        }
        applyDirectionalFeedback(dayIndex: dayIndex, kind: kind)
        persistDayPlan(dayIndex, immediate: true)
    }

    private func submitFormalityFeedback(for dayIndex: Int, direction: Int) {
        guard dayIndex < boardState.days.count else { return }
        let kind: RecommendationFeedbackKind = direction < 0 ? .tooFormal : .tooCasual
        let shownIDs = shownAlternatives(for: dayIndex).map(\.id)
        guard recordLearningEvent(
            dayIndex: dayIndex,
            kind: kind,
            shownGarmentIDs: shownIDs
        ) else { return }
        DS.haptic(0.4)
        let current = boardState.days[dayIndex].overrides.desiredFormality ?? preferredFormality
        boardState.days[dayIndex].overrides.desiredFormality = min(max(current + direction, 1), 5)
        boardState.days[dayIndex].feedback = .rejected
        AIRecommender.shared.applyDirectionalFeedback(
            kind,
            ctx: recoContext(for: dayIndex),
            modelContext: context
        )
        persistDayPlan(dayIndex, immediate: true)
        refreshDay(dayIndex)
    }

    private func loveScoreAdjustment(for rating: OutfitFeedbackRating?) -> Int {
        switch rating {
        case .loved: return 8
        case .worn: return 3
        case .rejected: return -6
        case .neutral, nil: return 0
        }
    }

    private func learnFromPlannerFeedback(
        dayIndex: Int,
        kind: RecommendationFeedbackKind,
        reward: Double
    ) {
        guard dayIndex < boardState.days.count else { return }
        let day = boardState.days[dayIndex]
        let selected = day.assignedGarmentIDs.compactMap { id in
            allGarments.first { $0.id == id }
        }
        guard !selected.isEmpty else { return }

        let shown = shownAlternatives(for: dayIndex)
        guard recordLearningEvent(
            dayIndex: dayIndex,
            kind: kind,
            shownGarmentIDs: shown.map(\.id)
        ) else { return }

        let ctx = recoContext(for: dayIndex)
        AIRecommender.shared.learn(
            from: selected,
            shown: shown,
            ctx: ctx,
            reward: reward,
            modelContext: context
        )
    }

    /// Top recommended alternatives per filled slot — used as negative samples for learning.
    private func shownAlternatives(for dayIndex: Int) -> [Garment] {
        guard dayIndex < boardState.days.count else { return [] }
        let day = boardState.days[dayIndex]
        var result: [Garment] = []
        var seen = Set<UUID>()

        func appendRecommended(for lookTime: LookTime, filledSlots: [OutfitSlot]) {
            for slot in filledSlots {
                for garment in recommendedItemsForSlot(slot, dayIndex: dayIndex, lookTime: lookTime).prefix(5) {
                    if seen.insert(garment.id).inserted {
                        result.append(garment)
                    }
                }
            }
        }

        let dayFilled = OutfitSlot.allCases.filter { day.garmentID(for: $0) != nil }
        appendRecommended(for: .day, filledSlots: dayFilled)
        if day.useEveningLook {
            let eveningFilled = OutfitSlot.allCases.filter { day.eveningGarmentID(for: $0) != nil }
            appendRecommended(for: .evening, filledSlots: eveningFilled)
        }
        return result
    }

    private func applyDirectionalFeedback(dayIndex: Int, kind: RecommendationFeedbackKind) {
        guard dayIndex < boardState.days.count else { return }
        let shownIDs = shownAlternatives(for: dayIndex).map(\.id)
        guard recordLearningEvent(
            dayIndex: dayIndex,
            kind: kind,
            shownGarmentIDs: shownIDs
        ) else { return }
        AIRecommender.shared.applyDirectionalFeedback(
            kind,
            ctx: recoContext(for: dayIndex),
            modelContext: context
        )
    }

    private func recordLearningEvent(
        dayIndex: Int,
        kind: RecommendationFeedbackKind,
        shownGarmentIDs: [UUID]
    ) -> Bool {
        guard dayIndex < boardState.days.count else { return false }
        let day = boardState.days[dayIndex]
        let garmentIDs = day.assignedGarmentIDs
        guard !garmentIDs.isEmpty else { return false }
        let plan = DayPlanService.shared.planFor(date: day.date, context: context)
        let shownIDs = Array(Set(shownGarmentIDs + garmentIDs))

        return RecommendationEventStore.record(
            kind: kind,
            selectedGarmentIDs: garmentIDs,
            shownGarmentIDs: shownIDs,
            dayPlanID: plan.id,
            context: recoContext(for: dayIndex),
            modelContext: context
        )
    }
    
    private func markUnavailable(_ garment: Garment, target: SlotTarget? = nil) {
        DS.haptic(0.4)
        garment.markUnavailable()
        try? context.save()
        updateAvailableGarments()
        activeSheet = nil
        replaceUnavailableGarment(garment, target: target)
    }

    private func markUnavailable(_ garment: Garment, days: Int, target: SlotTarget? = nil) {
        DS.haptic(0.4)
        let until = Calendar.current.date(byAdding: .day, value: days, to: Date())
        garment.markUnavailable(until: until)
        try? context.save()
        updateAvailableGarments()
        activeSheet = nil
        replaceUnavailableGarment(garment, target: target)
    }

    private func replaceUnavailableGarment(_ garment: Garment, target: SlotTarget?) {
        guard let target, boardState.days.indices.contains(target.dayIndex) else { return }
        let index = target.dayIndex
        let slot = target.slot
        let day = boardState.days[index]
        let currentID = target.lookTime == .day ? day.garmentID(for: slot) : day.eveningGarmentID(for: slot)
        // Do not rewrite an already worn look or a historical day.
        guard currentID == garment.id, dayTiming(for: index) != .past,
              lookWearStatus(dayIndex: index, lookTime: target.lookTime) != .worn else { return }
        replaceSlot(dayIndex: index, slot: slot, lookTime: target.lookTime, replacingUnavailable: true)
        let updated = boardState.days[index]
        let newID = target.lookTime == .day ? updated.garmentID(for: slot) : updated.eveningGarmentID(for: slot)
        guard newID != currentID else { return } // Existing no-replacement alert explains why.
        if target.lookTime == .evening {
            // An evening-only replacement must not silently replace the day look.
            boardState.days[index].eveningLinkedSlots.remove(slot)
            boardState.days[index].eveningUsesDayBottom = boardState.days[index].eveningLinkedSlots.contains(.bottom)
        } else if isEveningLinked(dayIndex: index, slot: slot),
                  lookWearStatus(dayIndex: index, lookTime: .evening) != .worn {
            boardState.days[index].setEveningGarment(newID, for: slot, locked: day.isEveningLocked(slot))
        }
        persistDayPlan(index, immediate: true)
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
        plan.applyDayLookWearStatus(.worn)
        boardState.days[dayIndex].dayLookWearStatus = .worn
        WearHistoryService.recordWorn(
            date: date,
            garmentIDs: garmentIDs,
            source: .planner,
            context: context,
            outfitID: nil,
            incrementTimesWorn: true,
            loveScoreDelta: 1
        )
        learnFromPlannerFeedback(dayIndex: dayIndex, kind: .worn, reward: 0.82)
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
                            .liquidGlassPill()
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
            .liquidGlassSurface(cornerRadius: DS.Radius.sm)
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
        let name = activeProfile?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
            if targetedSlot != target {
                targetedSlot = target
            }
        } else if targetedSlot == target {
            targetedSlot = nil
        }
    }

    private func isValidDropTarget(slot: OutfitSlot, lookTime: LookTime) -> Bool {
        guard let dragged = boardState.draggedItem else { return false }
        return dragged.sourceSlot == slot
    }

    private func isTargetHighlighted(dayIndex: Int, slot: OutfitSlot, lookTime: LookTime) -> Bool {
        targetedSlot == SlotTarget(dayIndex: dayIndex, slot: slot, lookTime: lookTime)
    }

    private func targetHighlightColor(dayIndex: Int, slot: OutfitSlot, lookTime: LookTime) -> Color {
        isTargetHighlighted(dayIndex: dayIndex, slot: slot, lookTime: lookTime) ? Color.accentColor.opacity(0.35) : .clear
    }

    private func targetHighlightLineWidth(dayIndex: Int, slot: OutfitSlot, lookTime: LookTime) -> CGFloat {
        isTargetHighlighted(dayIndex: dayIndex, slot: slot, lookTime: lookTime) ? 2 : 0
    }

    private func clearDragState() {
        boardState.draggedItem = nil
        targetedSlot = nil
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
        garmentsByID = Dictionary(filtered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        availableGarmentsSignature = filtered.map {
            "\($0.id.uuidString)-\($0.isWorn ? 1 : 0)-\($0.isCurrentlyUnavailable ? 1 : 0)"
        }.sorted().joined(separator: "|")
    }

    /// O(1) garment lookup for hot render paths; falls back to a linear scan
    /// before the cache is first populated.
    private func garment(for id: UUID) -> Garment? {
        if let cached = garmentsByID[id] { return cached }
        return allGarments.first { $0.id == id }
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
        if let garment = garment(for: id) {
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
    let feedbackExpanded: Bool
    /// AI explanation currently shown — the memoized card must re-render when
    /// the async generation lands.
    let aiExplanation: String?
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
            DS.haptic(0.45)
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.sm)
            .foregroundStyle(isSelected ? color : .primary)
            .liquidGlassSurface(
                cornerRadius: DS.Radius.sm,
                interactive: true,
                tint: isSelected ? color.opacity(0.18) : nil
            )
        }
        .buttonStyle(SoftPressButtonStyle())
        .animation(DS.Animation.fast, value: isSelected)
    }
}

private struct SoftPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(DS.Animation.interactive, value: configuration.isPressed)
    }
}

private struct LearningFeedbackChip: View {
    let label: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button {
            DS.haptic(0.35)
            action()
        } label: {
            Label(label, systemImage: icon)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xs)
                .foregroundStyle(color)
                .liquidGlassPill(interactive: true, tint: color.opacity(0.10))
        }
        .buttonStyle(SoftPressButtonStyle())
    }
}

// MARK: - Temperature Feedback Button

struct TempFeedbackButton: View {
    let feedback: TemperatureFeedback
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button {
            DS.haptic(0.35)
            action()
        } label: {
            HStack(spacing: 2) {
                Text(feedback.emoji)
                    .font(.caption2)
                Text(feedback.label)
                    .font(.caption2.weight(.medium))
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .liquidGlassPill(
                interactive: true,
                tint: isSelected ? Color.accentColor.opacity(0.18) : nil
            )
        }
        .buttonStyle(SoftPressButtonStyle())
    }
}
