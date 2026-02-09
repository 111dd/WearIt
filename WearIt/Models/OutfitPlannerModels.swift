import Foundation
import SwiftData
import Observation
import UniformTypeIdentifiers

//
//  OutfitPlannerModels.swift
//  WearIt
//
//  Models for the 3-day outfit planner feature
//

// MARK: - Day Overrides (User Manual Adjustments)

/// Stores user overrides for a specific day's weather conditions
struct DayOverrides: Codable, Equatable {
    var temperatureC: Double?
    var isRaining: Bool?
    var desiredFormality: Int?
    
    var isEmpty: Bool {
        temperatureC == nil && isRaining == nil && desiredFormality == nil
    }
    
    mutating func reset() {
        temperatureC = nil
        isRaining = nil
        desiredFormality = nil
    }
}

// MARK: - Outfit Feedback Rating

enum OutfitFeedbackRating: Int, Codable {
    case rejected = -1     // "Not for me"
    case neutral = 0       // No feedback
    case worn = 1          // "Wear this"
    case loved = 2         // "Love it"
    
    var emoji: String {
        switch self {
        case .rejected: return "✕"
        case .neutral: return "•"
        case .worn: return "✓"
        case .loved: return "♥︎"
        }
    }
}

// MARK: - Temperature Feedback

enum TemperatureFeedback: String, Codable, CaseIterable, Identifiable {
    case tooCold
    case justRight
    case tooWarm
    
    var id: String { rawValue }
    
    var label: String {
        switch self {
        case .tooCold: return "Too cold"
        case .justRight: return "Just right"
        case .tooWarm: return "Too warm"
        }
    }
    
    var emoji: String {
        switch self {
        case .tooCold: return "🥶"
        case .justRight: return "👌"
        case .tooWarm: return "🥵"
        }
    }
}

// MARK: - Look Time

enum LookTime: String, Codable, CaseIterable {
    case day
    case evening
}

// MARK: - Drag Item (Transferable)

struct GarmentDragItem: Equatable, Codable {
    let garmentID: UUID
    let sourceDayIndex: Int
    let sourceSlot: OutfitSlot
    let lookTime: LookTime
}

// MARK: - Outfit Slot

enum OutfitSlot: String, Codable, CaseIterable, Identifiable, Hashable {
    case top
    case bottom
    case shoes
    case outer
    case accessory
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .top: return String(localized: "slot_top")
        case .bottom: return String(localized: "slot_bottom")
        case .shoes: return String(localized: "slot_shoes")
        case .outer: return String(localized: "slot_outer")
        case .accessory: return String(localized: "slot_accessory")
        }
    }
    
    var allowedCategories: [Category] {
        switch self {
        case .top: return [.top]
        case .bottom: return [.bottom]
        case .shoes: return [.shoes]
        case .outer: return [.outer]
        case .accessory: return [.accessory]
        }
    }
    
    static func from(category: Category) -> OutfitSlot {
        switch category {
        case .top: return .top
        case .bottom: return .bottom
        case .shoes: return .shoes
        case .outer: return .outer
        case .accessory: return .accessory
        }
    }
}

// MARK: - Slot Assignment

/// A single garment assigned to a slot
struct SlotAssignment: Equatable, Identifiable {
    let slot: OutfitSlot
    var garmentID: UUID?
    var isLocked: Bool
    
    var id: String { slot.rawValue }
    
    init(slot: OutfitSlot, garmentID: UUID? = nil, isLocked: Bool = false) {
        self.slot = slot
        self.garmentID = garmentID
        self.isLocked = isLocked
    }
}

// MARK: - Planner Day State

/// View state for a single day in the planner
struct PlannerDayState: Identifiable, Equatable {
    let id: Int  // 0 = today, 1 = tomorrow, 2 = day 3
    let date: Date
    var forecast: DayForecast?
    var overrides: DayOverrides = DayOverrides()
    var isManualMode: Bool = false
    var regenVersion: Int = 0
    var useEveningLook: Bool = false
    var eveningUsesDayBottom: Bool = false
    var eveningLinkedSlots: Set<OutfitSlot> = []
    var feedback: OutfitFeedbackRating? = nil
    var temperatureFeedback: TemperatureFeedback? = nil
    var notes: String? = nil
    var insufficientItemsWarning: Bool = false
    
    /// Slot assignments for daytime
    var slots: [OutfitSlot: SlotAssignment] = [:]
    /// Slot assignments for evening
    var eveningSlots: [OutfitSlot: SlotAssignment] = [:]
    
    /// Legacy compatibility
    var suggestedOutfit: [Garment] = []
    
    init(dayIndex: Int) {
        self.id = dayIndex
        self.date = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: dayIndex, to: Date()) ?? Date())
    }
    
    /// Effective temperature (override or forecast)
    var effectiveTemperature: Double {
        overrides.temperatureC ?? forecast?.temperatureC ?? 20
    }
    
    /// Effective rain status (override or forecast)
    var effectiveIsRaining: Bool {
        overrides.isRaining ?? forecast?.isRaining ?? false
    }
    
    /// Effective formality (override or default)
    var effectiveFormality: Int {
        overrides.desiredFormality ?? 3
    }
    
    /// All assigned garment IDs
    var assignedGarmentIDs: [UUID] {
        slots.values.compactMap { $0.garmentID }
    }
    
    /// All assigned evening garment IDs
    var eveningAssignedGarmentIDs: [UUID] {
        eveningSlots.values.compactMap { $0.garmentID }
    }
    
    /// Check if a garment ID is assigned to any slot
    func hasGarment(_ id: UUID) -> Bool {
        assignedGarmentIDs.contains(id)
    }
    
    /// Get garment ID for a slot
    func garmentID(for slot: OutfitSlot) -> UUID? {
        slots[slot]?.garmentID
    }
    
    func eveningGarmentID(for slot: OutfitSlot) -> UUID? {
        eveningSlots[slot]?.garmentID
    }
    
    /// Set garment for a slot
    mutating func setGarment(_ id: UUID?, for slot: OutfitSlot, locked: Bool = false) {
        slots[slot] = SlotAssignment(slot: slot, garmentID: id, isLocked: locked)
    }
    
    mutating func setEveningGarment(_ id: UUID?, for slot: OutfitSlot, locked: Bool = false) {
        eveningSlots[slot] = SlotAssignment(slot: slot, garmentID: id, isLocked: locked)
    }

    /// Check if evening slot is locked
    func isEveningLocked(_ slot: OutfitSlot) -> Bool {
        eveningSlots[slot]?.isLocked ?? false
    }

    mutating func setEveningLock(_ slot: OutfitSlot, locked: Bool) {
        let currentID = eveningSlots[slot]?.garmentID
        eveningSlots[slot] = SlotAssignment(slot: slot, garmentID: currentID, isLocked: locked)
    }
    
    /// Check if slot is locked
    func isLocked(_ slot: OutfitSlot) -> Bool {
        slots[slot]?.isLocked ?? false
    }
    
    /// Create a RecoContext for this day
    func toRecoContext() -> RecoContext {
        RecoContext(
            desiredFormality: effectiveFormality,
            temperatureC: effectiveTemperature,
            isRaining: effectiveIsRaining,
            now: date
        )
    }
    
    static func == (lhs: PlannerDayState, rhs: PlannerDayState) -> Bool {
        lhs.id == rhs.id &&
        lhs.date == rhs.date &&
        lhs.overrides == rhs.overrides &&
        lhs.isManualMode == rhs.isManualMode &&
        lhs.regenVersion == rhs.regenVersion &&
        lhs.useEveningLook == rhs.useEveningLook &&
        lhs.eveningUsesDayBottom == rhs.eveningUsesDayBottom &&
        lhs.eveningLinkedSlots == rhs.eveningLinkedSlots &&
        lhs.slots == rhs.slots &&
        lhs.eveningSlots == rhs.eveningSlots
    }
}

// MARK: - Planner Board State

/// Manages the state of the 3-day planner board
@MainActor
@Observable
final class PlannerBoardState {
    var days: [PlannerDayState] = []
    var draggedItem: GarmentDragItem?
    var showUnavailableAlert = false
    var alertMessage = ""
    
    init() {
        initializeDays()
    }
    
    func initializeDays() {
        days = (0..<3).map { PlannerDayState(dayIndex: $0) }
    }
    
    /// Update forecasts for all days
    func updateForecasts(_ forecasts: [DayForecast]) {
        for (index, forecast) in forecasts.prefix(3).enumerated() {
            if index < days.count {
                days[index].forecast = forecast
            }
        }
    }
    
    /// Get all garment IDs currently used across all days
    var allUsedGarmentIDs: Set<UUID> {
        Set(days.flatMap { $0.assignedGarmentIDs })
    }
    
    /// Check if a garment is used in any day
    func isGarmentUsed(_ id: UUID) -> Bool {
        allUsedGarmentIDs.contains(id)
    }
    
    /// Check if a garment is used in a different day (for duplicate detection)
    func isGarmentUsedElsewhere(_ id: UUID, excludingDay dayIndex: Int) -> Bool {
        for (index, day) in days.enumerated() {
            if index != dayIndex && day.hasGarment(id) {
                return true
            }
        }
        return false
    }
    
    /// Check if a garment is used outside a set of days
    func isGarmentUsedOutside(_ id: UUID, excludingDays: Set<Int>) -> Bool {
        for (index, day) in days.enumerated() {
            if !excludingDays.contains(index) && day.hasGarment(id) {
                return true
            }
        }
        return false
    }
    
    /// Swap garments between two slots
    /// Returns true if swap was successful
    func swapGarments(
        fromDay: Int,
        fromSlot: OutfitSlot,
        toDay: Int,
        toSlot: OutfitSlot
    ) -> Bool {
        guard fromDay < days.count, toDay < days.count else { return false }
        guard fromSlot == toSlot else {
            // Only allow same-slot swaps
            alertMessage = String(localized: "swap_error_different_slots")
            showUnavailableAlert = true
            return false
        }
        
        // Check for locked slots (source or target)
        if days[fromDay].isLocked(fromSlot) || days[toDay].isLocked(toSlot) {
            alertMessage = String(localized: "swap_error_locked")
            showUnavailableAlert = true
            return false
        }
        
        // Get current garment IDs
        let fromGarmentID = days[fromDay].garmentID(for: fromSlot)
        let toGarmentID = days[toDay].garmentID(for: toSlot)
        
        // Block duplicates across other days
        if let fromGarmentID, isGarmentUsedOutside(fromGarmentID, excludingDays: [fromDay, toDay]) {
            alertMessage = String(localized: "swap_error_duplicate")
            showUnavailableAlert = true
            return false
        }
        if let toGarmentID, isGarmentUsedOutside(toGarmentID, excludingDays: [fromDay, toDay]) {
            alertMessage = String(localized: "swap_error_duplicate")
            showUnavailableAlert = true
            return false
        }
        
        // Perform the swap
        days[fromDay].setGarment(toGarmentID, for: fromSlot)
        days[toDay].setGarment(fromGarmentID, for: toSlot)
        
        return true
    }
    
    /// Assign a garment to a slot (from drag or selection)
    func assignGarment(
        _ garmentID: UUID,
        toDay dayIndex: Int,
        toSlot slot: OutfitSlot,
        garments: [Garment],
        allowUnavailable: Bool = false
    ) -> Bool {
        guard dayIndex < days.count else { return false }
        
        // Check if garment is available
        if !allowUnavailable,
           let garment = garments.first(where: { $0.id == garmentID }),
           garment.isCurrentlyUnavailable {
            alertMessage = String(localized: "assign_error_unavailable")
            showUnavailableAlert = true
            return false
        }
        
        // Check if slot is locked
        if days[dayIndex].isLocked(slot) {
            alertMessage = String(localized: "swap_error_locked")
            showUnavailableAlert = true
            return false
        }
        
        // Check if garment would create duplicate
        if isGarmentUsedElsewhere(garmentID, excludingDay: dayIndex) {
            // Remove from other day first (if not locked)
            for (index, day) in days.enumerated() where index != dayIndex {
                for slot in OutfitSlot.allCases {
                    if day.garmentID(for: slot) == garmentID {
                        if day.isLocked(slot) {
                            alertMessage = String(localized: "swap_error_duplicate")
                            showUnavailableAlert = true
                            return false
                        }
                        days[index].setGarment(nil, for: slot)
                    }
                }
            }
        }
        
        // Assign to slot
        days[dayIndex].setGarment(garmentID, for: slot)
        return true
    }
    
    /// Clear all assignments for a day
    func clearDay(_ dayIndex: Int) {
        guard dayIndex < days.count else { return }
        for slot in OutfitSlot.allCases {
            days[dayIndex].setGarment(nil, for: slot)
        }
        for slot in OutfitSlot.allCases {
            days[dayIndex].setEveningGarment(nil, for: slot)
        }
        days[dayIndex].eveningLinkedSlots = []
        days[dayIndex].useEveningLook = false
    }
    
    /// Set outfit from garment array (legacy compatibility)
    func setOutfit(forDay dayIndex: Int, garments: [Garment], overwriteExisting: Bool = true) {
        guard dayIndex < days.count else { return }
        
        if overwriteExisting {
            // Clear non-locked slots first
            for slot in OutfitSlot.allCases {
                if !days[dayIndex].isLocked(slot) {
                    days[dayIndex].setGarment(nil, for: slot)
                }
            }
        }
        
        // Assign garments to appropriate slots
        for garment in garments {
            let slot = OutfitSlot.from(category: garment.category)
            if !days[dayIndex].isLocked(slot) && days[dayIndex].garmentID(for: slot) == nil {
                days[dayIndex].setGarment(garment.id, for: slot)
            }
        }
        
        // Store for legacy compatibility
        days[dayIndex].suggestedOutfit = garments
    }
}

// MARK: - Outfit Feedback (Model)

@Model
final class OutfitFeedback {
    var id: UUID = Foundation.UUID()
    var createdAt: Date = Foundation.Date()
    var ratingRaw: Int = OutfitFeedbackRating.neutral.rawValue
    var garmentIDs: [UUID] = []
    /// Legacy (migration-only): garment IDs as strings
    var garmentIDStrings: [String] = []
    
    init(
        id: UUID? = nil,
        createdAt: Date? = nil,
        rating: OutfitFeedbackRating = .neutral,
        garmentIDs: [UUID] = []
    ) {
        self.id = id ?? Foundation.UUID()
        self.createdAt = createdAt ?? Foundation.Date()
        self.ratingRaw = rating.rawValue
        self.garmentIDs = garmentIDs
    }

    init() {
        self.id = Foundation.UUID()
        self.createdAt = Foundation.Date()
        self.ratingRaw = OutfitFeedbackRating.neutral.rawValue
        self.garmentIDs = []
    }
    
    @Transient
    var rating: OutfitFeedbackRating {
        OutfitFeedbackRating(rawValue: ratingRaw) ?? .neutral
    }
    
}

// MARK: - Drag UTType

extension UTType {
    /// Use a safe, generic type identifier to avoid Info.plist declarations
    static let garmentDragItem = UTType.data
}
