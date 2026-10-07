import SwiftUI
import SwiftData
import PhotosUI
import UIKit
import EventKit

//
//  CalendarLookView.swift
//  WearIt
//
//  Calendar tab: a week strip (expandable to a month) above a single card
//  for the selected day. The planner owns the next 3 days; this tab is the
//  journal — look, photos, wear status, and a short reflection per day.
//

struct CalendarLookView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var weather: WeatherCenter

    @State private var selectedDate: Date = Date()
    @State private var isStripExpanded = false
    @State private var photosPickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showDatePicker = false
    @State private var jumpDate = Date()
    @State private var showLookEditor = false
    @State private var statusToast: String?
    @State private var currentDate: Date = Date()
    /// Drives the card's directional transition when swiping between days.
    @State private var lastDayStep: Int = 1
    @State private var dayEvents: [DayJournalEvent] = []
    @State private var horizonEvents: [CalendarDisplayEvent] = []
    @State private var detectedTrips: [TripSpan] = []
    @State private var manualTrips: [TripSpan] = []
    @State private var packingTrip: TripSpan?
    @State private var showPlanTrip = false

    @Query(sort: \DailyLook.date, order: .reverse) private var dailyLooks: [DailyLook]
    @Query(sort: \DayPlan.date, order: .reverse) private var dayPlans: [DayPlan]
    @Query(sort: \Garment.createdAt, order: .reverse) private var allGarments: [Garment]

    private static let slotOrder: [OutfitSlot] = [.top, .bottom, .shoes, .outer, .accessory]
    private static let plannerWindowDays = 3

    // MARK: - Derived

    private var calendar: Calendar { Calendar.current }

    private var selectedDay: Date { calendar.startOfDay(for: selectedDate) }

    private var lookForSelectedDay: DailyLook? {
        dailyLooks.first(where: { calendar.isDate($0.date, inSameDayAs: selectedDay) })
    }

    private var planForSelectedDay: DayPlan? {
        dayPlans.first(where: { calendar.isDate($0.date, inSameDayAs: selectedDay) })
    }

    private var timing: DayTiming {
        let today = calendar.startOfDay(for: currentDate)
        if selectedDay == today { return .today }
        return selectedDay < today ? .past : .future
    }

    private var isInPlannerWindow: Bool {
        let today = calendar.startOfDay(for: currentDate)
        guard let offset = calendar.dateComponents([.day], from: today, to: selectedDay).day else { return false }
        return offset >= 0 && offset < Self.plannerWindowDays
    }

    private var garmentsByID: [UUID: Garment] {
        Dictionary(allGarments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Per-day indicators for the strip, keyed by start-of-day.
    private var dayIndicators: [Date: CalendarDayIndicators] {
        var result: [Date: CalendarDayIndicators] = [:]
        for look in dailyLooks where !look.photoPaths.isEmpty {
            result[calendar.startOfDay(for: look.date), default: CalendarDayIndicators()].hasPhotos = true
        }
        for plan in dayPlans {
            let day = calendar.startOfDay(for: plan.date)
            var indicators = result[day, default: CalendarDayIndicators()]
            indicators.hasOutfit = plan.hasSelectedItems || !plan.eveningSlotAssignments.isEmpty
            indicators.wasWorn = plan.resolvedDayLookWearStatus == .worn
            result[day] = indicators
        }
        return result
    }

    private var journalModel: DayJournalModel {
        let plan = planForSelectedDay
        let lookup = garmentsByID
        let dayItems = Self.dayItems(for: plan, lookup: lookup)
        let eveningItems = Self.eveningItems(for: plan, lookup: lookup)
        let hasEvening = plan.map { $0.eveningEnabled == true || !$0.eveningSlotAssignments.isEmpty } ?? false

        return DayJournalModel(
            date: selectedDay,
            timing: timing,
            isInPlannerWindow: isInPlannerWindow,
            dayItems: dayItems,
            eveningItems: eveningItems,
            hasEveningLook: hasEvening && !eveningItems.isEmpty,
            lockedGarmentIDs: Set(plan?.lockedGarmentIDs ?? []),
            status: plan?.resolvedDayLookWearStatus,
            temperatureFeedback: plan?.temperatureFeedback,
            notes: plan?.notes ?? "",
            weather: weatherSummary(for: plan),
            photoPaths: lookForSelectedDay?.photoPaths ?? [],
            events: dayEvents
        )
    }

    private var journalActions: DayJournalActions {
        DayJournalActions(
            onEditLook: { showLookEditor = true },
            onOpenPlanner: { openInPlanner() },
            onSetStatus: { setWearStatus($0) },
            onSetTemperatureFeedback: { setTemperatureFeedback($0) },
            onSaveNotes: { saveNotes($0) },
            onOpenCamera: { showCamera = true },
            onRemovePhoto: { removePhoto(at: $0) }
        )
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                CalendarDateStrip(
                    selectedDate: $selectedDate,
                    isExpanded: $isStripExpanded,
                    indicators: dayIndicators
                )

                if let trip = featuredTrip {
                    tripBanner(trip)
                }
                planTripButton

                DayJournalCard(
                    model: journalModel,
                    actions: journalActions,
                    photosPickerItems: $photosPickerItems
                )
                .id(selectedDay)
                .transition(dayTransition)
                .gesture(daySwipeGesture)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.sm)
            .padding(.bottom, 100)
            .animation(reduceMotion ? nil : DS.Animation.standard, value: selectedDay)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .navigationTitle(String(localized: "nav_calendar"))
        .minimalCollapsingNavBar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    jumpDate = selectedDate
                    showDatePicker = true
                } label: {
                    Label("calendar_jump_date", systemImage: "calendar.badge.clock")
                }
            }
            if timing != .today {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "day_today")) {
                        DS.haptic(0.3)
                        jump(to: currentDate)
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
        }
        .onChange(of: photosPickerItems) { _, _ in
            handlePhotosPicker()
        }
        .onAppear {
            refreshCurrentDate()
            reloadTripsAndEvents()
        }
        .onChange(of: selectedDate) { _, _ in
            reloadDayEvents()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshCurrentDate()
            reloadTripsAndEvents()
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            reloadTripsAndEvents()
        }
        .onReceive(NotificationCenter.default.publisher(for: .calendarUnderstandingChanged)) { _ in
            reloadTripsAndEvents()
        }
        .sheet(item: $packingTrip) { trip in
            TripPackingView(
                trip: trip,
                garments: allGarments,
                onDelete: trip.isManual ? { deleteManualTrip(trip) } : nil
            )
        }
        .sheet(isPresented: $showPlanTrip) {
            PlanTripSheet { trip in
                var trips = TripPackingStore.manualTrips().filter { $0.id != trip.id }
                trips.append(trip)
                TripPackingStore.saveManual(trips)
                manualTrips = TripPackingStore.manualTrips()
                packingTrip = trip
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            refreshCurrentDate()
        }
        .sheet(isPresented: $showCamera) {
            CameraPickerWrapper { image in
                Task { await save(images: [image]) }
            }
        }
        .sheet(isPresented: $showLookEditor) {
            DayLookEditorSheet(
                garments: allGarments,
                initialAssignments: Self.effectiveDayAssignments(for: planForSelectedDay, lookup: garmentsByID),
                initialLockedSlots: Self.effectiveLockedSlots(for: planForSelectedDay, lookup: garmentsByID)
            ) { assignments, lockedSlots in
                updateLook(assignments: assignments, lockedSlots: lockedSlots)
            }
        }
        .sheet(isPresented: $showDatePicker) {
            NavigationStack {
                Form {
                    DatePicker("calendar_jump_date", selection: $jumpDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }
                .navigationTitle(String(localized: "calendar_jump_date"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("action_cancel") { showDatePicker = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("calendar_go_to_date") {
                            jump(to: jumpDate)
                            showDatePicker = false
                        }
                    }
                }
            }
        }
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

    // MARK: - Day navigation

    private var dayTransition: AnyTransition {
        if reduceMotion { return .opacity }
        // Visual "forward" is leading→trailing in LTR and the reverse in RTL.
        let forwardEdge: Edge = layoutDirection == .rightToLeft ? .leading : .trailing
        let backwardEdge: Edge = layoutDirection == .rightToLeft ? .trailing : .leading
        let stepForward = lastDayStep > 0
        return .asymmetric(
            insertion: .move(edge: stepForward ? forwardEdge : backwardEdge).combined(with: .opacity),
            removal: .move(edge: stepForward ? backwardEdge : forwardEdge).combined(with: .opacity)
        )
    }

    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 32)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                let forward = value.translation.width < 0
                let step = (layoutDirection == .rightToLeft ? !forward : forward) ? 1 : -1
                shiftDay(by: step)
            }
    }

    private func shiftDay(by step: Int) {
        guard let next = calendar.date(byAdding: .day, value: step, to: selectedDay) else { return }
        DS.haptic(0.3)
        lastDayStep = step
        withAnimation(reduceMotion ? nil : DS.Animation.standard) {
            selectedDate = next
        }
    }

    private func jump(to date: Date) {
        lastDayStep = calendar.startOfDay(for: date) > selectedDay ? 1 : -1
        withAnimation(reduceMotion ? nil : DS.Animation.standard) {
            selectedDate = date
        }
    }

    private var featuredTrip: TripSpan? {
        TripFinder.featured(
            in: detectedTrips + manualTrips,
            selectedDay: selectedDay,
            today: currentDate
        )
    }

    private func tripBanner(_ trip: TripSpan) -> some View {
        let range = tripRangeText(trip)
        let onThisDay = trip.contains(selectedDay)
        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                Image(systemName: "suitcase")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trip.placeName.isEmpty ? trip.title : trip.placeName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(onThisDay ? String(localized: "calendar_trip_includes_day") : range)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if onThisDay {
                        Text(range)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Button {
                DS.haptic(0.4)
                packingTrip = trip
            } label: {
                Label(String(localized: "calendar_trip_pack"), systemImage: "checklist")
                    .frame(maxWidth: .infinity)
            }
            .dsSecondaryButton()
        }
        .padding(DS.Spacing.md)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
    }

    private var planTripButton: some View {
        Button {
            DS.haptic(0.3)
            showPlanTrip = true
        } label: {
            Label(
                String(localized: featuredTrip == nil ? "calendar_plan_trip" : "calendar_plan_another_trip"),
                systemImage: "plus"
            )
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    private func tripRangeText(_ trip: TripSpan) -> String {
        let start = trip.start.formatted(.dateTime.day().month(.abbreviated))
        let end = trip.end.formatted(.dateTime.day().month(.abbreviated))
        if calendar.isDate(trip.start, inSameDayAs: trip.end) { return start }
        return "\(start)–\(end)"
    }

    private func reloadTripsAndEvents() {
        manualTrips = TripPackingStore.manualTrips()
        let today = calendar.startOfDay(for: currentDate)
        let start = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 45, to: today) ?? today
        horizonEvents = CalendarContextService.shared.displayEvents(from: start, to: end)
        detectedTrips = TripFinder.trips(
            from: horizonEvents.map(\.tripInput),
            home: weather.homeCoordinate?.location
        )
        reloadDayEvents()
        // A typed trip location looked up for the first time can turn a vacation into a trip.
        Task {
            if await TypedEventPlaceResolver.shared.resolvePending(near: weather.homeCoordinate?.location) {
                reloadTripsAndEvents()
            }
        }
    }

    private func reloadDayEvents() {
        dayEvents = horizonEvents
            .filter { covers($0, day: selectedDay) }
            .map { event in
                DayJournalEvent(id: event.id, title: event.title, detail: event.detail, icon: event.icon)
            }
    }

    private func covers(_ event: CalendarDisplayEvent, day: Date) -> Bool {
        let start = calendar.startOfDay(for: event.start)
        var end = calendar.startOfDay(for: event.end)
        if event.isAllDay, end > start {
            end = calendar.date(byAdding: .day, value: -1, to: end) ?? start
        }
        let day = calendar.startOfDay(for: day)
        return day >= start && day <= end
    }

    private func deleteManualTrip(_ trip: TripSpan) {
        let remaining = TripPackingStore.manualTrips().filter { $0.id != trip.id }
        TripPackingStore.saveManual(remaining)
        manualTrips = remaining
        packingTrip = nil
    }

    private func refreshCurrentDate() {
        currentDate = Date()
    }

    // MARK: - Slot resolution

    /// Day-look items in slot order. Prefers slot assignments; falls back to a
    /// flat `selectedGarmentIDs` list (legacy / migration) with inferred slots.
    private static func dayItems(for plan: DayPlan?, lookup: [UUID: Garment]) -> [(slot: OutfitSlot, garment: Garment)] {
        guard let plan else { return [] }
        return effectiveDayAssignments(for: plan, lookup: lookup)
            .compactMap { slot, id in lookup[id].map { (slot, $0) } }
            .sorted { slotRank($0.slot) < slotRank($1.slot) }
    }

    private static func eveningItems(for plan: DayPlan?, lookup: [UUID: Garment]) -> [(slot: OutfitSlot, garment: Garment)] {
        guard let plan else { return [] }
        var assignments = plan.eveningSlotAssignments
        let day = effectiveDayAssignments(for: plan, lookup: lookup)
        for slot in plan.eveningLinkedSlots {
            if let dayID = day[slot] { assignments[slot] = dayID }
        }
        return slotOrder.compactMap { slot in
            guard let id = assignments[slot], let garment = lookup[id] else { return nil }
            return (slot, garment)
        }
    }

    /// Slot map for the day look, inferring slots for legacy flat plans.
    private static func effectiveDayAssignments(for plan: DayPlan?, lookup: [UUID: Garment]) -> [OutfitSlot: UUID] {
        guard let plan else { return [:] }
        if !plan.slotAssignments.isEmpty { return plan.slotAssignments }
        var result: [OutfitSlot: UUID] = [:]
        for id in plan.selectedGarmentIDs {
            guard let garment = lookup[id] else { continue }
            let slot = OutfitSlot.from(category: garment.category)
            if result[slot] == nil { result[slot] = id }
        }
        return result
    }

    private static func effectiveLockedSlots(for plan: DayPlan?, lookup: [UUID: Garment]) -> Set<OutfitSlot> {
        guard let plan else { return [] }
        if !plan.lockedSlots.isEmpty { return plan.lockedSlots }
        let assignments = effectiveDayAssignments(for: plan, lookup: lookup)
        return Set(assignments.filter { plan.lockedGarmentIDs.contains($0.value) }.keys)
    }

    private static func slotRank(_ slot: OutfitSlot) -> Int {
        slotOrder.firstIndex(of: slot) ?? slotOrder.count
    }

    private func weatherSummary(for plan: DayPlan?) -> (text: String, icon: String)? {
        guard let plan, let high = plan.contextTempHigh, let low = plan.contextTempLow else { return nil }
        let raining = plan.contextWasRaining == true || (plan.contextRainProbability ?? 0) > 0.3
        return ("\(Int(low.rounded()))°–\(Int(high.rounded()))°", raining ? "cloud.rain" : "thermometer.medium")
    }

    // MARK: - Actions

    private func openInPlanner() {
        NotificationCenter.default.post(name: .openPlannerDay, object: nil, userInfo: ["date": selectedDay])
    }

    /// Single write path for wear status — same fields the planner uses, so
    /// both tabs agree. `.worn` also records wear history for the day look.
    private func setWearStatus(_ status: LookWearStatus?) {
        let plan = planForSelectedDay ?? DayPlanService.shared.planFor(date: selectedDay, context: context)
        plan.applyDayLookWearStatus(status)

        if status == .worn {
            let ids = Self.dayItems(for: plan, lookup: garmentsByID).map(\.garment.id)
            WearHistoryService.recordWorn(
                date: selectedDay,
                garmentIDs: ids,
                source: .calendar,
                context: context,
                outfitID: nil,
                incrementTimesWorn: true,
                loveScoreDelta: 1
            )
        }

        try? context.save()
        switch status {
        case .worn: showStatusToast(String(localized: "success_saved"))
        case .notWorn: showStatusToast(String(localized: "planner_swipe_marked_not_worn_message"))
        case .planned, nil: break
        }
    }

    /// Writes slot assignments (planner-compatible) and resets wear status if
    /// the look actually changed, so a new look can't inherit "worn".
    private func updateLook(assignments: [OutfitSlot: UUID?], lockedSlots: Set<OutfitSlot>) {
        let plan = planForSelectedDay ?? DayPlanService.shared.planFor(date: selectedDay, context: context)
        let before = Self.effectiveDayAssignments(for: plan, lookup: garmentsByID)
        plan.setSlotAssignments(assignments, lockedSlots: lockedSlots)
        if plan.slotAssignments != before {
            plan.applyDayLookWearStatus(nil)
            if timing != .future {
                learnActualWear(plan: plan, before: before, after: plan.slotAssignments)
            }
        }
        try? context.save()
        DS.haptic(0.5)
        showStatusToast(String(localized: "success_saved"))
    }

    /// Correcting today's or a past look is "what I actually wore": each changed
    /// slot teaches the recommender the worn piece beats the planned one.
    /// Saved by the caller's single save.
    private func learnActualWear(plan: DayPlan, before: [OutfitSlot: UUID], after: [OutfitSlot: UUID]) {
        let profile = CurrentUser.activeProfile(in: context, userIdentifier: auth.userIdentifier, createIfNeeded: false)
        let temperatureC: Double = {
            if let high = plan.contextTempHigh, let low = plan.contextTempLow { return (high + low) / 2 }
            return plan.contextAfternoonTemp ?? plan.contextTempHigh ?? 20
        }()
        let ctx = RecoContext(
            desiredFormality: profile?.preferredFormality ?? 3,
            temperatureC: temperatureC,
            isRaining: plan.contextWasRaining ?? false,
            now: plan.date,
            profileID: profile?.id,
            warmthSensitivity: profile?.warmthSensitivity ?? 3,
            rainTolerance: profile?.rainTolerance ?? 3
        )
        for (slot, oldID) in before {
            guard let newID = after[slot], newID != oldID,
                  let worn = garmentsByID[newID],
                  let planned = garmentsByID[oldID] else { continue }
            AIRecommender.shared.learnPreference(
                chosen: worn,
                over: planned,
                ctx: ctx,
                modelContext: context,
                save: false
            )
        }
    }

    private func setTemperatureFeedback(_ feedback: TemperatureFeedback) {
        let plan = planForSelectedDay ?? DayPlanService.shared.planFor(date: selectedDay, context: context)
        if plan.temperatureFeedback == feedback {
            plan.temperatureFeedbackRaw = nil
            plan.updatedAt = Date()
        } else {
            plan.setTemperatureFeedback(feedback)
        }
        try? context.save()
    }

    private func saveNotes(_ notes: String) {
        let plan = planForSelectedDay ?? DayPlanService.shared.planFor(date: selectedDay, context: context)
        plan.notes = notes.isEmpty ? nil : notes
        plan.updatedAt = Date()
        try? context.save()
    }

    // MARK: - Photos

    private func handlePhotosPicker() {
        guard !photosPickerItems.isEmpty else { return }
        let items = photosPickerItems
        photosPickerItems = []
        Task {
            var images: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    images.append(img)
                }
            }
            await save(images: images)
        }
    }

    private func save(images: [UIImage]) async {
        guard !images.isEmpty else { return }
        let day = selectedDay
        let encoded: [Data] = await Task.detached(priority: .userInitiated) {
            images.compactMap { $0.resized(max: 1400).jpegData(compressionQuality: 0.9) }
        }.value

        do {
            var newPaths: [String] = []
            for jpg in encoded {
                newPaths.append(try ImageStore.save(data: jpg, preferredExt: "jpg"))
            }
            let look = lookForSelectedDay ?? createLook(for: day)
            look.photoPaths.append(contentsOf: newPaths)
            try? context.save()
            DS.haptic(0.5)
            showStatusToast(String(localized: "success_saved"))
        } catch {
            showStatusToast(String(localized: "error_save_failed"))
        }
    }

    private func createLook(for day: Date) -> DailyLook {
        let look = DailyLook(date: day, photoPaths: [])
        if let profile = CurrentUser.activeProfile(in: context, userIdentifier: auth.userIdentifier, createIfNeeded: false) {
            look.ownerID = profile.id
            if !profile.dailyLookIDs.contains(look.id) {
                profile.dailyLookIDs.append(look.id)
            }
        }
        context.insert(look)
        return look
    }

    private func removePhoto(at index: Int) {
        guard let look = lookForSelectedDay, look.photoPaths.indices.contains(index) else { return }
        let path = look.photoPaths.remove(at: index)
        ImageStore.delete(path: path)
        try? context.save()
        DS.haptic(0.5)
        showStatusToast(String(localized: "success_deleted"))
    }

    // MARK: - Toast

    private func showStatusToast(_ message: String) {
        withAnimation(reduceMotion ? nil : DS.Animation.standard) {
            statusToast = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(reduceMotion ? nil : DS.Animation.standard) {
                if statusToast == message {
                    statusToast = nil
                }
            }
        }
    }
}

// MARK: - UIImage resize helper

private extension UIImage {
    func resized(max: CGFloat) -> UIImage {
        let maxSide = Swift.max(size.width, size.height)
        guard maxSide > max else { return self }
        let scale = max / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
