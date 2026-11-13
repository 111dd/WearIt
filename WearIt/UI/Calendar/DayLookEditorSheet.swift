import SwiftUI

//
//  DayLookEditorSheet.swift
//  WearIt
//
//  Slot-based editor for a calendar day's look. Mirrors the planner's data
//  model (one garment per OutfitSlot, optional lock per slot) so calendar and
//  planner write the same fields on DayPlan.
//

struct DayLookEditorSheet: View {
    let garments: [Garment]
    let initialAssignments: [OutfitSlot: UUID]
    let initialLockedSlots: Set<OutfitSlot>
    let onSave: ([OutfitSlot: UUID?], Set<OutfitSlot>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var assignments: [OutfitSlot: UUID] = [:]
    @State private var lockedSlots: Set<OutfitSlot> = []
    @State private var activeSlot: OutfitSlot = .top
    @State private var query: String = ""

    /// Older saved looks can hold a dress in `.top`. Keep that assignment
    /// unchanged until an explicit edit while presenting its real silhouette.
    private var onePieceSlot: OutfitSlot? {
        OutfitSlot.displayOrder.first { slot in
            guard let id = assignments[slot] else { return false }
            return slot == .onePiece || garmentsByID[id]?.itemType?.isOnePiece == true
        }
    }

    private func presentedSlot(_ slot: OutfitSlot) -> OutfitSlot {
        slot == onePieceSlot ? .onePiece : slot
    }

    private var slotOrder: [OutfitSlot] {
        let hasOnePiece = onePieceSlot != nil
        let assignedIDs = Set(assignments.values)
        let canAddAccessory = garments.contains { $0.category == .accessory && !assignedIDs.contains($0.id) }
        let nextAccessory = canAddAccessory ? OutfitSlot.accessorySlots.first { assignments[$0] == nil } : nil
        return OutfitSlot.displayOrder.filter { slot in
            if slot.isAccessory { return assignments[slot] != nil || slot == nextAccessory }
            if slot == .onePiece {
                return assignments[slot] != nil
                    || (!hasOnePiece && garments.contains { $0.itemType?.isOnePiece == true })
            }
            if slot == .top || slot == .bottom { return !hasOnePiece || assignments[slot] != nil }
            return true
        }
    }

    private var garmentsByID: [UUID: Garment] {
        Dictionary(uniqueKeysWithValues: garments.map { ($0.id, $0) })
    }

    private var candidates: [Garment] {
        let targetSlot = presentedSlot(activeSlot)
        var items = garments.filter { targetSlot.accepts($0) }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            items = items.filter {
                $0.displayTitle.localizedCaseInsensitiveContains(trimmed)
                    || ($0.brand?.localizedCaseInsensitiveContains(trimmed) ?? false)
            }
        }
        return items
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                slotStrip
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)

                Divider().opacity(0.4)

                ScrollView {
                    if candidates.isEmpty {
                        Text(String(localized: "calendar_no_items_for_slot"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, DS.Spacing.xl)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 88, maximum: 110), spacing: DS.Spacing.xs)],
                            spacing: DS.Spacing.xs
                        ) {
                            ForEach(candidates) { garment in
                                candidateCell(garment)
                            }
                        }
                        .padding(DS.Spacing.md)
                        .padding(.bottom, 80)
                    }
                }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic))
            }
            .safeAreaInset(edge: .bottom) {
                if assignments[activeSlot] != nil {
                    slotActions
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.sm)
                        .background(.ultraThinMaterial)
                }
            }
            .navigationTitle(String(localized: "calendar_edit_look"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action_save")) {
                        var result: [OutfitSlot: UUID?] = [:]
                        for slot in OutfitSlot.allCases {
                            result[slot] = assignments[slot]
                        }
                        onSave(result, lockedSlots.filter { assignments[$0] != nil })
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            assignments = initialAssignments
            lockedSlots = initialLockedSlots
            activeSlot = slotOrder.first(where: { initialAssignments[$0] == nil }) ?? slotOrder.first ?? .top
        }
        .presentationDetents([.large])
    }

    // MARK: Slot strip

    private var slotStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                ForEach(slotOrder, id: \.self) { slot in
                    slotChip(slot)
                }
            }
        }
    }

    private func slotChip(_ slot: OutfitSlot) -> some View {
        let isActive = slot == activeSlot
        let assigned = assignments[slot].flatMap { garmentsByID[$0] }
        let presentation = presentedSlot(slot)

        return Button {
            DS.haptic(0.3)
            withAnimation(DS.Animation.fast) { activeSlot = slot }
        } label: {
            VStack(spacing: DS.Spacing.xxs) {
                ZStack(alignment: .topTrailing) {
                    if let assigned {
                        DSGarmentThumbnail(assigned, size: .small)
                    } else {
                        RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .frame(width: 50, height: 50)
                            .overlay {
                                Image(systemName: presentation.allowedCategories.first?.icon ?? "questionmark")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                    }
                    if lockedSlots.contains(slot), assigned != nil {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(DS.Accent.onFill)
                            .padding(3)
                            .background(Color.accentColor, in: Circle())
                            .offset(x: 3, y: -3)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                        .strokeBorder(isActive ? Color.accentColor : .clear, lineWidth: 2)
                )

                Text(presentation.title)
                    .font(.caption2.weight(isActive ? .bold : .medium))
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 68)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(presentation.title)
        .accessibilityValue(assigned?.displayTitle ?? String(localized: "calendar_slot_empty"))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: Candidates

    private func candidateCell(_ garment: Garment) -> some View {
        let targetSlot = presentedSlot(activeSlot)
        let conflicts = structuralConflicts(for: targetSlot)
        let isSelected = assignments[activeSlot] == garment.id
        let usedElsewhere = assignments.contains { $0.key != activeSlot && $0.value == garment.id }
        let isLocked = lockedSlots.contains(activeSlot)
        let hasLockedConflict = conflicts.contains {
            assignments[$0] != nil && lockedSlots.contains($0)
        }
        let isDisabled = usedElsewhere || isLocked || hasLockedConflict

        return Button {
            guard !isDisabled else { return }
            DS.haptic(0.4)
            withAnimation(DS.Animation.fast) {
                if isSelected {
                    assignments[activeSlot] = nil
                    lockedSlots.remove(activeSlot)
                    keepActiveSlotVisible()
                } else {
                    for conflict in conflicts {
                        assignments[conflict] = nil
                    }
                    assignments[targetSlot] = garment.id
                    activeSlot = targetSlot
                    advanceToNextEmptySlot()
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                DSGarmentThumbnail(garment, size: .large)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                    )
                    .opacity(isDisabled && !isSelected ? 0.45 : 1)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(DS.Accent.onFill, Color.accentColor)
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(garment.displayTitle)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func structuralConflicts(for slot: OutfitSlot) -> Set<OutfitSlot> {
        var conflicts = slot.conflictingSlots
        if slot == .bottom, let id = assignments[.top],
           garmentsByID[id]?.itemType?.isOnePiece == true {
            conflicts.insert(.top)
        }
        return conflicts
    }

    private func advanceToNextEmptySlot() {
        let order = slotOrder
        guard let index = order.firstIndex(of: activeSlot) else { return }
        let remaining = order[(index + 1)...]
        if let next = remaining.first(where: { assignments[$0] == nil }) {
            activeSlot = next
        }
    }

    private func keepActiveSlotVisible() {
        let order = slotOrder
        if !order.contains(activeSlot) { activeSlot = order.first ?? .top }
    }

    // MARK: Slot actions

    private var slotActions: some View {
        HStack(spacing: DS.Spacing.xs) {
            Button {
                DS.haptic(0.4)
                withAnimation(DS.Animation.fast) {
                    if lockedSlots.contains(activeSlot) {
                        lockedSlots.remove(activeSlot)
                    } else {
                        lockedSlots.insert(activeSlot)
                    }
                }
            } label: {
                Label(
                    String(localized: lockedSlots.contains(activeSlot) ? "calendar_unlock_garment" : "calendar_lock_garment"),
                    systemImage: lockedSlots.contains(activeSlot) ? "lock.open" : "lock"
                )
                .frame(maxWidth: .infinity)
            }
            .dsSecondaryButton()

            Button(role: .destructive) {
                guard !lockedSlots.contains(activeSlot) else { return }
                DS.haptic(0.4)
                withAnimation(DS.Animation.fast) {
                    assignments[activeSlot] = nil
                    lockedSlots.remove(activeSlot)
                    keepActiveSlotVisible()
                }
            } label: {
                Label(String(localized: "action_remove"), systemImage: "minus.circle")
                    .frame(maxWidth: .infinity)
            }
            .dsSecondaryButton()
            .disabled(lockedSlots.contains(activeSlot))
        }
    }
}
