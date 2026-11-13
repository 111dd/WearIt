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
        case .tooCold: return String(localized: "planner_too_cold")
        case .justRight: return String(localized: "planner_just_right")
        case .tooWarm: return String(localized: "planner_too_warm")
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

/// Per look-slot wear outcome. Persist only `rawValue` on DayPlan; nil = undecided.
enum LookWearStatus: String, Codable, Sendable, Equatable {
    case planned
    case worn
    case notWorn
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
    case onePiece
    case accessory2, accessory3, accessory4, accessory5, accessory6
    
    var id: String { rawValue }

    static let accessorySlots: [OutfitSlot] = [.accessory, .accessory2, .accessory3, .accessory4, .accessory5, .accessory6]
    static let displayOrder: [OutfitSlot] = [.onePiece, .top, .bottom, .shoes, .outer] + accessorySlots

    var isAccessory: Bool { Self.accessorySlots.contains(self) }

    /// Structural alternatives are exclusive only when making an explicit edit.
    /// Reading a stored plan must never discard its assignments or wear history.
    var conflictingSlots: Set<OutfitSlot> {
        switch self {
        case .onePiece: return [.top, .bottom]
        case .top, .bottom: return [.onePiece]
        default: return []
        }
    }
    
    var title: String {
        switch self {
        case .top: return String(localized: "slot_top")
        case .bottom: return String(localized: "slot_bottom")
        case .shoes: return String(localized: "slot_shoes")
        case .outer: return String(localized: "slot_outer")
        case .accessory: return String(localized: "slot_accessory")
        case .onePiece: return String(localized: "slot_one_piece")
        case .accessory2, .accessory3, .accessory4, .accessory5, .accessory6:
            return String(localized: "slot_additional_accessory")
        }
    }
    
    var allowedCategories: [Category] {
        switch self {
        case .top: return [.top]
        case .bottom: return [.bottom]
        case .shoes: return [.shoes]
        case .outer: return [.outer]
        case .accessory: return [.accessory]
        case .onePiece: return [.top]
        case .accessory2, .accessory3, .accessory4, .accessory5, .accessory6:
            return [.accessory]
        }
    }

    func accepts(_ garment: Garment) -> Bool {
        guard allowedCategories.contains(garment.category) else { return false }
        if self == .onePiece { return garment.itemType?.isOnePiece == true }
        if self == .top { return garment.itemType?.isOnePiece != true }
        return true
    }

    static func from(garment: Garment) -> OutfitSlot {
        if garment.category == .top, garment.itemType?.isOnePiece == true { return .onePiece }
        return from(category: garment.category)
    }

    /// Retains an existing accessory's identity before taking the next free place.
    static func allocationSlot(for garment: Garment, assignments: [OutfitSlot: UUID]) -> OutfitSlot? {
        if let existing = displayOrder.first(where: { assignments[$0] == garment.id && $0.accepts(garment) }) { return existing }
        if garment.category == .accessory {
            return accessorySlots.first(where: { assignments[$0] == nil })
        }
        return from(garment: garment)
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
    /// Derived from DayPlan (source of truth). nil = undecided.
    var dayLookWearStatus: LookWearStatus? = nil
    /// Derived from DayPlan (source of truth). nil = undecided.
    var eveningLookWearStatus: LookWearStatus? = nil
    
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
        lhs.feedback == rhs.feedback &&
        lhs.temperatureFeedback == rhs.temperatureFeedback &&
        lhs.slots == rhs.slots &&
        lhs.eveningSlots == rhs.eveningSlots &&
        lhs.dayLookWearStatus == rhs.dayLookWearStatus &&
        lhs.eveningLookWearStatus == rhs.eveningLookWearStatus
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
        guard days.indices.contains(fromDay), days.indices.contains(toDay) else { return false }
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

        if (toGarmentID != nil && fromSlot.conflictingSlots.contains(where: { days[fromDay].isLocked($0) && days[fromDay].garmentID(for: $0) != nil })) ||
            (fromGarmentID != nil && toSlot.conflictingSlots.contains(where: { days[toDay].isLocked($0) && days[toDay].garmentID(for: $0) != nil })) {
            alertMessage = String(localized: "assign_error_structure_locked")
            showUnavailableAlert = true
            return false
        }
        
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
        if toGarmentID != nil {
            for conflict in fromSlot.conflictingSlots { days[fromDay].setGarment(nil, for: conflict) }
        }
        if fromGarmentID != nil {
            for conflict in toSlot.conflictingSlots { days[toDay].setGarment(nil, for: conflict) }
        }
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
        allowUnavailable: Bool = false,
        allowRepeats: Bool = false
    ) -> Bool {
        guard days.indices.contains(dayIndex),
              let garment = garments.first(where: { $0.id == garmentID }),
              slot.accepts(garment) else { return false }
        
        // Check if garment is available
        if !allowUnavailable, garment.isCurrentlyUnavailable {
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

        // A saved dress may still live under the legacy top key. Interpret its
        // garment type for an explicit edit without rewriting the stored plan.
        let conflictingSlots = slot.conflictingSlots.union(OutfitSlot.displayOrder.filter { existingSlot in
            guard let existingID = days[dayIndex].garmentID(for: existingSlot),
                  let existing = garments.first(where: { $0.id == existingID }) else { return false }
            return slot.conflictingSlots.contains(OutfitSlot.from(garment: existing))
        })
        if conflictingSlots.contains(where: { days[dayIndex].isLocked($0) && days[dayIndex].garmentID(for: $0) != nil }) {
            alertMessage = String(localized: "assign_error_structure_locked")
            showUnavailableAlert = true
            return false
        }

        let previousSlots = OutfitSlot.displayOrder.filter { $0 != slot && days[dayIndex].garmentID(for: $0) == garmentID }
        if previousSlots.contains(where: { days[dayIndex].isLocked($0) }) {
            alertMessage = String(localized: "swap_error_locked")
            showUnavailableAlert = true
            return false
        }
        
        // Check if garment would create duplicate
        if !allowRepeats, isGarmentUsedElsewhere(garmentID, excludingDay: dayIndex) {
            // Validate every source before making any change.
            if days.enumerated().contains(where: { index, day in
                index != dayIndex && OutfitSlot.allCases.contains(where: { day.garmentID(for: $0) == garmentID && day.isLocked($0) })
            }) {
                alertMessage = String(localized: "swap_error_duplicate")
                showUnavailableAlert = true
                return false
            }
            for (index, day) in days.enumerated() where index != dayIndex {
                for slot in OutfitSlot.allCases {
                    if day.garmentID(for: slot) == garmentID {
                        days[index].setGarment(nil, for: slot)
                    }
                }
            }
        }
        
        // Assign to slot
        for conflict in conflictingSlots { days[dayIndex].setGarment(nil, for: conflict) }
        for previous in previousSlots { days[dayIndex].setGarment(nil, for: previous) }
        days[dayIndex].setGarment(garmentID, for: slot)
        return true
    }
    
    /// Clear all assignments for a day
    func clearDay(_ dayIndex: Int) {
        guard days.indices.contains(dayIndex) else { return }
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
        guard days.indices.contains(dayIndex) else { return }
        let original = days[dayIndex]
        var updated = original

        // Reject a structural replacement before clearing any existing pieces.
        if overwriteExisting, garments.contains(where: { garment in
            let slot = OutfitSlot.from(garment: garment)
            return slot.conflictingSlots.contains(where: {
                original.isLocked($0) && original.garmentID(for: $0) != nil
            })
        }) {
            alertMessage = String(localized: "assign_error_structure_locked")
            showUnavailableAlert = true
            return
        }

        if overwriteExisting {
            // Clear non-locked slots first
            for slot in OutfitSlot.allCases {
                if !updated.isLocked(slot) {
                    updated.setGarment(nil, for: slot)
                }
            }
        }

        // Place retained IDs first so adding or removing another accessory does
        // not move their stable slot keys (locks and evening links use those keys).
        let existingAssignments = original.slots.compactMapValues(\.garmentID)
        let orderedGarments = garments.filter { garment in
            OutfitSlot.displayOrder.contains { existingAssignments[$0] == garment.id && $0.accepts(garment) }
        } + garments.filter { garment in
            !OutfitSlot.displayOrder.contains { existingAssignments[$0] == garment.id && $0.accepts(garment) }
        }

        // Keep a single core structure and preserve each locked accessory.
        var assignedCore: Set<OutfitSlot> = []
        for garment in orderedGarments {
            let assignments = updated.slots.compactMapValues(\.garmentID)
            guard !assignments.values.contains(garment.id) else { continue }
            let previousSlot = OutfitSlot.displayOrder.first {
                existingAssignments[$0] == garment.id && $0.accepts(garment)
                    && (assignments[$0] == nil || assignments[$0] == garment.id)
            }
            guard let slot = previousSlot ?? OutfitSlot.allocationSlot(for: garment, assignments: assignments),
                  slot.accepts(garment),
                  !updated.isLocked(slot),
                  updated.garmentID(for: slot) == nil,
                  slot.conflictingSlots.isDisjoint(with: assignedCore),
                  overwriteExisting || !slot.conflictingSlots.contains(where: { updated.garmentID(for: $0) != nil }),
                  !slot.conflictingSlots.contains(where: { updated.isLocked($0) && updated.garmentID(for: $0) != nil }) else { continue }
            for conflict in slot.conflictingSlots { updated.setGarment(nil, for: conflict) }
            updated.setGarment(garment.id, for: slot)
            assignedCore.insert(slot)
        }

        // Store for legacy compatibility
        let assignedIDs = Set(updated.assignedGarmentIDs)
        updated.suggestedOutfit = garments.filter { assignedIDs.contains($0.id) }
        days[dayIndex] = updated
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
