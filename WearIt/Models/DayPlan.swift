import Foundation
import SwiftData

//
//  DayPlan.swift
//  WearIt
//
//  Calendar-based outfit planning model for past and future days
//

// MARK: - Planner Hint

struct PlannerHint: Equatable, Identifiable {
    enum Style: String {
        case info
        case temp
        case rain
        case calendar
    }

    let id = UUID()
    let text: String
    let iconName: String
    let style: Style
}

// MARK: - Day Plan Model

@Model
final class DayPlan {
    var id: UUID = Foundation.UUID()
    
    /// The date this plan is for (normalized to start of day)
    var date: Date = Foundation.Date()
    
    /// Garments selected for this day
    var selectedGarmentIDs: [UUID] = []
    
    /// Garments locked to this day (user explicitly chose these)
    var lockedGarmentIDs: [UUID] = []

    /// Slot-specific assignments (slot rawValue -> garment UUID)
    var slotAssignmentIDs: [String: UUID]?

    /// Legacy (migration-only): selected garment IDs as strings
    var selectedGarmentIDStrings: [String] = []

    /// Legacy (migration-only): locked garment IDs as strings
    var lockedGarmentIDStrings: [String] = []

    /// Legacy (migration-only): slot assignments (slot rawValue -> garment UUID string)
    var slotAssignmentRaw: [String: String]?

    /// Locked slots (slot rawValue)
    var lockedSlotRaw: [String]?

    /// Evening slot assignments (slot rawValue -> garment UUID)
    var eveningSlotAssignmentIDs: [String: UUID]?

    /// Evening locked slots (slot rawValue)
    var eveningLockedSlotRaw: [String]?

    /// Evening linked slots (slot rawValue)
    var eveningLinkedSlotRaw: [String]?

    /// Legacy (migration-only): evening slot assignments (slot rawValue -> garment UUID string)
    var eveningSlotAssignmentRaw: [String: String]?

    /// Whether an evening look is enabled for this day
    var eveningEnabled: Bool?
    
    /// If true, evening bottom uses the day bottom
    var eveningUsesDayBottom: Bool = false
    
    /// Whether the user confirmed they actually wore this outfit
    var wasWornConfirmed: Bool = false
    
    /// Feedback rating for this day's outfit
    var feedbackRating: Int?  // OutfitFeedbackRating.rawValue
    
    /// Temperature feedback
    var temperatureFeedbackRaw: String?
    
    /// User notes for this day
    var notes: String?
    
    /// Weather context when plan was created/executed
    var contextTempHigh: Double?
    var contextTempLow: Double?
    var contextWasRaining: Bool?
    var contextMorningTemp: Double?
    var contextAfternoonTemp: Double?
    var contextEveningTemp: Double?
    var contextRainProbability: Double?
    
    /// Timestamps
    var createdAt: Date = Foundation.Date()
    var updatedAt: Date = Foundation.Date()
    
    /// Owner relationship
    var ownerID: UUID? = nil
    
    // MARK: - Initialization
    
    init(
        id: UUID? = nil,
        date: Date,
        selectedGarmentIDs: [UUID] = [],
        lockedGarmentIDs: [UUID] = [],
        wasWornConfirmed: Bool = false,
        ownerID: UUID? = nil
    ) {
        self.id = id ?? Foundation.UUID()
        self.date = Calendar.current.startOfDay(for: date)
        self.selectedGarmentIDs = selectedGarmentIDs
        self.lockedGarmentIDs = lockedGarmentIDs
        self.wasWornConfirmed = wasWornConfirmed
        self.eveningEnabled = false
        self.eveningUsesDayBottom = false
        self.createdAt = Foundation.Date()
        self.updatedAt = Foundation.Date()
        self.ownerID = ownerID
    }

    init() {
        self.id = Foundation.UUID()
        self.date = Foundation.Date()
        self.selectedGarmentIDs = []
        self.lockedGarmentIDs = []
        self.wasWornConfirmed = false
        self.createdAt = Foundation.Date()
        self.updatedAt = Foundation.Date()
        self.ownerID = nil
        self.eveningUsesDayBottom = false
    }
    
    // MARK: - Computed Properties
    
    @Transient
    var slotAssignments: [OutfitSlot: UUID] {
        guard let raw = slotAssignmentIDs, !raw.isEmpty else { return [:] }
        var result: [OutfitSlot: UUID] = [:]
        for (key, value) in raw {
            if let slot = OutfitSlot(rawValue: key) {
                result[slot] = value
            }
        }
        return result
    }

    @Transient
    var lockedSlots: Set<OutfitSlot> {
        guard let raw = lockedSlotRaw else { return [] }
        return Set(raw.compactMap { OutfitSlot(rawValue: $0) })
    }

    @Transient
    var eveningSlotAssignments: [OutfitSlot: UUID] {
        guard let raw = eveningSlotAssignmentIDs, !raw.isEmpty else { return [:] }
        var result: [OutfitSlot: UUID] = [:]
        for (key, value) in raw {
            if let slot = OutfitSlot(rawValue: key) {
                result[slot] = value
            }
        }
        return result
    }

    @Transient
    var eveningLockedSlots: Set<OutfitSlot> {
        guard let raw = eveningLockedSlotRaw else { return [] }
        return Set(raw.compactMap { OutfitSlot(rawValue: $0) })
    }

    @Transient
    var eveningLinkedSlots: Set<OutfitSlot> {
        guard let raw = eveningLinkedSlotRaw else { return [] }
        return Set(raw.compactMap { OutfitSlot(rawValue: $0) })
    }
    
    @Transient
    var feedback: OutfitFeedbackRating? {
        guard let raw = feedbackRating else { return nil }
        return OutfitFeedbackRating(rawValue: raw)
    }
    
    @Transient
    var temperatureFeedback: TemperatureFeedback? {
        guard let raw = temperatureFeedbackRaw else { return nil }
        return TemperatureFeedback(rawValue: raw)
    }
    
    @Transient
    var isPastDay: Bool {
        date < Calendar.current.startOfDay(for: Date())
    }
    
    @Transient
    var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }
    
    @Transient
    var isFutureDay: Bool {
        date > Calendar.current.startOfDay(for: Date())
    }
    
    @Transient
    var hasLockedItems: Bool {
        !lockedGarmentIDs.isEmpty
    }
    
    @Transient
    var hasSelectedItems: Bool {
        !selectedGarmentIDs.isEmpty
    }
    
    // MARK: - Mutation Methods
    
    func setSelectedGarments(_ ids: [UUID]) {
        selectedGarmentIDs = ids
        updatedAt = Date()
    }

    func setSlotAssignments(_ assignments: [OutfitSlot: UUID?], lockedSlots: Set<OutfitSlot>) {
        var newAssignments: [String: UUID] = [:]
        for (slot, id) in assignments {
            if let id {
                newAssignments[slot.rawValue] = id
            }
        }
        slotAssignmentIDs = newAssignments.isEmpty ? nil : newAssignments
        lockedSlotRaw = lockedSlots.isEmpty ? nil : lockedSlots.map { $0.rawValue }

        let orderedSelected = OutfitSlot.allCases.compactMap { newAssignments[$0.rawValue] }
        selectedGarmentIDs = orderedSelected

        let orderedLocked = OutfitSlot.allCases.compactMap { slot -> UUID? in
            lockedSlots.contains(slot) ? newAssignments[slot.rawValue] : nil
        }
        lockedGarmentIDs = orderedLocked
        updatedAt = Date()
    }

    func setEveningSlotAssignments(_ assignments: [OutfitSlot: UUID?], lockedSlots: Set<OutfitSlot> = []) {
        var newAssignments: [String: UUID] = [:]
        for (slot, id) in assignments {
            if let id {
                newAssignments[slot.rawValue] = id
            }
        }
        eveningSlotAssignmentIDs = newAssignments.isEmpty ? nil : newAssignments
        eveningLockedSlotRaw = lockedSlots.isEmpty ? nil : lockedSlots.map { $0.rawValue }
        updatedAt = Date()
    }

    func setEveningLinkedSlots(_ slots: Set<OutfitSlot>) {
        eveningLinkedSlotRaw = slots.isEmpty ? nil : slots.map { $0.rawValue }
        updatedAt = Date()
    }
    
    func lockGarment(_ id: UUID) {
        if !lockedGarmentIDs.contains(id) {
            lockedGarmentIDs.append(id)
        }
        // Also add to selected if not present
        if !selectedGarmentIDs.contains(id) {
            selectedGarmentIDs.append(id)
        }
        updatedAt = Date()
    }
    
    func unlockGarment(_ id: UUID) {
        lockedGarmentIDs.removeAll { $0 == id }
        updatedAt = Date()
    }
    
    func removeGarment(_ id: UUID) {
        selectedGarmentIDs.removeAll { $0 == id }
        lockedGarmentIDs.removeAll { $0 == id }
        updatedAt = Date()
    }
    
    func confirmWorn() {
        wasWornConfirmed = true
        updatedAt = Date()
    }
    
    func setFeedback(_ rating: OutfitFeedbackRating) {
        feedbackRating = rating.rawValue
        updatedAt = Date()
    }
    
    func setTemperatureFeedback(_ feedback: TemperatureFeedback) {
        temperatureFeedbackRaw = feedback.rawValue
        updatedAt = Date()
    }
    
    func setWeatherContext(high: Double?, low: Double?, raining: Bool?) {
        contextTempHigh = high
        contextTempLow = low
        contextWasRaining = raining
        updatedAt = Date()
    }

    func setWeatherProfile(_ profile: DayTemperatureProfile) {
        contextTempHigh = profile.highTemp
        contextTempLow = profile.lowTemp
        contextWasRaining = profile.rainProbability > 0.3
        contextMorningTemp = profile.morningTemp
        contextAfternoonTemp = profile.afternoonTemp
        contextEveningTemp = profile.eveningTemp
        contextRainProbability = profile.rainProbability
        updatedAt = Date()
    }
}

// MARK: - Day Plan Service

@MainActor
final class DayPlanService {
    static let shared = DayPlanService()
    private init() {}
    
    /// Get or create a DayPlan for a specific date
    func planFor(date: Date, context: ModelContext) -> DayPlan {
        let startOfDay = Calendar.current.startOfDay(for: date)
        
        var descriptor = FetchDescriptor<DayPlan>(
            predicate: #Predicate { $0.date == startOfDay }
        )
        descriptor.fetchLimit = 1
        
        if let existing = try? context.fetch(descriptor).first {
            if existing.ownerID == nil {
                let profile = UserProfile.current(in: context)
                existing.ownerID = profile.id
                if !profile.dayPlanIDs.contains(existing.id) {
                    profile.dayPlanIDs.append(existing.id)
                }
            }
            return existing
        }
        
        // Create new plan
        let plan = DayPlan(date: startOfDay)
        let profile = UserProfile.current(in: context)
        plan.ownerID = profile.id
        if !profile.dayPlanIDs.contains(plan.id) {
            profile.dayPlanIDs.append(plan.id)
        }
        context.insert(plan)
        return plan
    }
    
    /// Get plans for a date range
    func plans(from startDate: Date, to endDate: Date, context: ModelContext) -> [DayPlan] {
        let start = Calendar.current.startOfDay(for: startDate)
        let end = Calendar.current.startOfDay(for: endDate)
        
        let descriptor = FetchDescriptor<DayPlan>(
            predicate: #Predicate { $0.date >= start && $0.date <= end },
            sortBy: [SortDescriptor(\.date)]
        )
        
        return (try? context.fetch(descriptor)) ?? []
    }
    
    /// Get locked garment IDs for future days (for exclusion in planning)
    func lockedGarmentIDsForFuture(excluding date: Date, context: ModelContext) -> Set<UUID> {
        let startOfDay = Calendar.current.startOfDay(for: date)
        let futureStart = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        
        let descriptor = FetchDescriptor<DayPlan>(
            predicate: #Predicate { $0.date >= futureStart }
        )
        
        let plans = (try? context.fetch(descriptor)) ?? []
        var lockedIDs = Set<UUID>()
        
        for plan in plans {
            lockedIDs.formUnion(plan.lockedGarmentIDs)
        }
        
        return lockedIDs
    }
}

// MARK: - Day Temperature Profile

/// Extended temperature information for smarter outfit planning
struct DayTemperatureProfile: Equatable {
    let date: Date
    let morningTemp: Double      // ~8:00 AM
    let afternoonTemp: Double    // ~2:00 PM (peak)
    let eveningTemp: Double      // ~7:00 PM
    let lowTemp: Double          // Daily minimum
    let highTemp: Double         // Daily maximum
    let rainProbability: Double  // 0.0 - 1.0
    let condition: WeatherCondition
    
    /// Temperature delta throughout the day
    var temperatureRange: Double {
        highTemp - lowTemp
    }
    
    /// Whether layering is recommended based on temperature range
    var layeringRecommended: Bool {
        temperatureRange >= 8  // 8°C or more difference
    }
    
    /// Whether evening jacket is recommended
    var eveningJacketRecommended: Bool {
        eveningTemp < morningTemp - 5 || eveningTemp < 15
    }
    
    /// Whether it's a "cold morning, warm afternoon" scenario
    var warmAfternoonCoolMorning: Bool {
        afternoonTemp - morningTemp >= 6
    }
    
    /// Average effective temperature for outfit selection
    var effectiveTemp: Double {
        // Weight towards afternoon (main part of day)
        (morningTemp * 0.25 + afternoonTemp * 0.5 + eveningTemp * 0.25)
    }
    
    /// Get smart recommendation hints
    var smartHints: [PlannerHint] {
        var hints: [PlannerHint] = []

        if layeringRecommended {
            hints.append(
                PlannerHint(
                    text: String(localized: "hint_layering_recommended"),
                    iconName: "thermometer.medium",
                    style: .temp
                )
            )
        }

        if eveningJacketRecommended {
            hints.append(
                PlannerHint(
                    text: String(localized: "hint_evening_jacket"),
                    iconName: "thermometer.snowflake",
                    style: .temp
                )
            )
        }

        if warmAfternoonCoolMorning {
            hints.append(
                PlannerHint(
                    text: String(localized: "hint_warm_afternoon_cool_morning"),
                    iconName: "thermometer.sun",
                    style: .temp
                )
            )
        }

        if rainProbability > 0.3 {
            hints.append(
                PlannerHint(
                    text: String(localized: "hint_rain_expected"),
                    iconName: "cloud.rain",
                    style: .rain
                )
            )
        }

        return hints
    }
    
    /// Create from DayForecast (with estimated time-of-day temps)
    init(from forecast: DayForecast) {
        self.date = forecast.date
        self.lowTemp = forecast.lowTempC
        self.highTemp = forecast.highTempC
        self.rainProbability = forecast.rainProbability
        self.condition = forecast.condition
        
        // Estimate time-of-day temperatures based on high/low
        let range = highTemp - lowTemp
        self.morningTemp = lowTemp + (range * 0.3)  // Morning is ~30% up from low
        self.afternoonTemp = highTemp               // Afternoon is typically the high
        self.eveningTemp = lowTemp + (range * 0.5)  // Evening is ~50% between
    }
    
    /// Create with explicit temperatures
    init(
        date: Date,
        morningTemp: Double,
        afternoonTemp: Double,
        eveningTemp: Double,
        lowTemp: Double,
        highTemp: Double,
        rainProbability: Double,
        condition: WeatherCondition
    ) {
        self.date = date
        self.morningTemp = morningTemp
        self.afternoonTemp = afternoonTemp
        self.eveningTemp = eveningTemp
        self.lowTemp = lowTemp
        self.highTemp = highTemp
        self.rainProbability = rainProbability
        self.condition = condition
    }
}
