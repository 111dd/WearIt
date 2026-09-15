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

    private static let slotOrder: [OutfitSlot] = [.top, .bottom, .shoes, .outer, .accessory]

    private var garmentsByID: [UUID: Garment] {
        Dictionary(uniqueKeysWithValues: garments.map { ($0.id, $0) })
    }

    private var candidates: [Garment] {
        let allowed = activeSlot.allowedCategories
        var items = garments.filter { allowed.contains($0.category) }
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
            activeSlot = Self.slotOrder.first(where: { initialAssignments[$0] == nil }) ?? .top
        }
        .presentationDetents([.large])
    }

    // MARK: Slot strip

    private var slotStrip: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(Self.slotOrder, id: \.self) { slot in
                slotChip(slot)
            }
        }
    }

    private func slotChip(_ slot: OutfitSlot) -> some View {
        let isActive = slot == activeSlot
        let assigned = assignments[slot].flatMap { garmentsByID[$0] }

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
                                Image(systemName: slot.allowedCategories.first?.icon ?? "questionmark")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                    }
                    if lockedSlots.contains(slot), assigned != nil {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Color.accentColor, in: Circle())
                            .offset(x: 3, y: -3)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                        .strokeBorder(isActive ? Color.accentColor : .clear, lineWidth: 2)
                )

                Text(slot.title)
                    .font(.caption2.weight(isActive ? .bold : .medium))
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(slot.title)
        .accessibilityValue(assigned?.displayTitle ?? String(localized: "calendar_slot_empty"))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: Candidates

    private func candidateCell(_ garment: Garment) -> some View {
        let isSelected = assignments[activeSlot] == garment.id
        let usedElsewhere = assignments.contains { $0.key != activeSlot && $0.value == garment.id }

        return Button {
            DS.haptic(0.4)
            withAnimation(DS.Animation.fast) {
                if isSelected {
                    assignments[activeSlot] = nil
                    lockedSlots.remove(activeSlot)
                } else {
                    assignments[activeSlot] = garment.id
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
                    .opacity(usedElsewhere ? 0.45 : 1)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.white, Color.accentColor)
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(usedElsewhere)
        .accessibilityLabel(garment.displayTitle)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func advanceToNextEmptySlot() {
        guard let index = Self.slotOrder.firstIndex(of: activeSlot) else { return }
        let remaining = Self.slotOrder[(index + 1)...]
        if let next = remaining.first(where: { assignments[$0] == nil }) {
            activeSlot = next
        }
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
                DS.haptic(0.4)
                withAnimation(DS.Animation.fast) {
                    assignments[activeSlot] = nil
                    lockedSlots.remove(activeSlot)
                }
            } label: {
                Label(String(localized: "action_remove"), systemImage: "minus.circle")
                    .frame(maxWidth: .infinity)
            }
            .dsSecondaryButton()
        }
    }
}
