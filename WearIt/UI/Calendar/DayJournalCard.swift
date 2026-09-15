import SwiftUI
import PhotosUI

//
//  DayJournalCard.swift
//  WearIt
//
//  The single card that represents one day on the calendar tab: date +
//  weather + status, the day/evening look, the photo strip, a short
//  "how was it?" row, and exactly one context-appropriate action.
//

// MARK: - Model

enum DayTiming: Equatable {
    case past
    case today
    case future
}

struct DayJournalModel {
    let date: Date
    let timing: DayTiming
    /// Whether the day is inside the planner's 3-day board (today + 2).
    let isInPlannerWindow: Bool
    let dayItems: [(slot: OutfitSlot, garment: Garment)]
    let eveningItems: [(slot: OutfitSlot, garment: Garment)]
    let hasEveningLook: Bool
    let lockedGarmentIDs: Set<UUID>
    let status: LookWearStatus?
    let temperatureFeedback: TemperatureFeedback?
    let notes: String
    let weather: (text: String, icon: String)?
    let photoPaths: [String]

    var hasLook: Bool { !dayItems.isEmpty || !eveningItems.isEmpty }
}

struct DayJournalActions {
    let onEditLook: () -> Void
    let onOpenPlanner: () -> Void
    let onSetStatus: (LookWearStatus?) -> Void
    let onSetTemperatureFeedback: (TemperatureFeedback) -> Void
    let onSaveNotes: (String) -> Void
    let onOpenCamera: () -> Void
    let onRemovePhoto: (Int) -> Void
}

// MARK: - Card

struct DayJournalCard: View {
    let model: DayJournalModel
    let actions: DayJournalActions
    @Binding var photosPickerItems: [PhotosPickerItem]

    @State private var lookTime: LookTime = .day
    @State private var notesDraft: String = ""
    @State private var showPhotoLibrary = false
    @FocusState private var notesFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            header
            lookSection

            if model.timing != .future {
                photoStrip
                reflectionSection
            }

            primaryAction
        }
        .padding(DS.Spacing.md)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
        .photosPicker(isPresented: $showPhotoLibrary, selection: $photosPickerItems, maxSelectionCount: 8, matching: .images)
        .onAppear { syncDrafts() }
        .onChange(of: model.date) { _, _ in
            lookTime = .day
            syncDrafts()
        }
        .onChange(of: model.notes) { _, _ in
            if !notesFocused { notesDraft = model.notes }
        }
        .onChange(of: notesFocused) { _, focused in
            if !focused { commitNotes() }
        }
    }

    private func syncDrafts() {
        notesDraft = model.notes
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.titleFormatter.string(from: model.date))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: DS.Spacing.xs) {
                    if let relative = relativeDayLabel {
                        Text(relative)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(model.timing == .today ? Color.accentColor : .secondary)
                    }
                    if let weather = model.weather {
                        Label(weather.text, systemImage: weather.icon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            if let badge = statusBadge {
                Label(badge.text, systemImage: badge.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(badge.color)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xs)
                    .liquidGlassPill(tint: badge.color.opacity(0.14))
                    .frame(minHeight: 44)
            }

            overflowMenu
        }
    }

    private var relativeDayLabel: String? {
        let calendar = Calendar.current
        if calendar.isDateInToday(model.date) { return String(localized: "day_today") }
        if calendar.isDateInTomorrow(model.date) { return String(localized: "day_tomorrow") }
        if calendar.isDateInYesterday(model.date) { return String(localized: "day_yesterday") }
        return nil
    }

    private var statusBadge: (text: String, icon: String, color: Color)? {
        switch model.status {
        case .worn:
            return (String(localized: "planner_swipe_status_worn"), "checkmark.seal.fill", .green)
        case .notWorn:
            return (String(localized: "planner_swipe_status_not_worn"), "xmark.circle", .secondary)
        case .planned:
            return (String(localized: "planner_swipe_status_planned"), "calendar.badge.clock", .accentColor)
        case nil:
            if model.timing == .future, model.hasLook {
                return (String(localized: "planner_swipe_status_planned"), "calendar.badge.clock", .accentColor)
            }
            return nil
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button(String(localized: "calendar_edit_look"), systemImage: "pencil") {
                actions.onEditLook()
            }
            if model.isInPlannerWindow {
                Button(String(localized: "calendar_open_in_planner"), systemImage: "sparkles") {
                    actions.onOpenPlanner()
                }
            }
            if model.status != nil {
                Divider()
                Button(String(localized: "planner_swipe_clear_status"), systemImage: "arrow.uturn.backward.circle") {
                    actions.onSetStatus(nil)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "planner_swipe_more_actions"))
    }

    // MARK: Look

    @ViewBuilder
    private var lookSection: some View {
        if !model.hasLook {
            emptyLook
        } else {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                if model.hasEveningLook {
                    Picker("", selection: $lookTime) {
                        Text(String(localized: "calendar_segment_day")).tag(LookTime.day)
                        Text(String(localized: "calendar_segment_evening")).tag(LookTime.evening)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                let items = lookTime == .evening ? model.eveningItems : model.dayItems
                if items.isEmpty {
                    Text(String(localized: "planner_no_outfit"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    lookGrid(items)
                        .id(lookTime)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : DS.Animation.fast, value: lookTime)
        }
    }

    private func lookGrid(_ items: [(slot: OutfitSlot, garment: Garment)]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: DS.Grid.columnSpacing)],
            spacing: DS.Grid.rowSpacing
        ) {
            ForEach(items, id: \.garment.id) { item in
                VStack(spacing: DS.Spacing.xxs) {
                    ZStack(alignment: .topTrailing) {
                        DSGarmentTile(item.garment, showTitle: false)

                        if model.lockedGarmentIDs.contains(item.garment.id) {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Color.accentColor, in: Circle())
                                .offset(x: 4, y: -4)
                                .accessibilityLabel(String(localized: "a11y_tile_locked"))
                        }
                    }

                    Text(item.slot.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.slot.title), \(item.garment.displayTitle)")
            }
        }
    }

    private var emptyLook: some View {
        VStack(spacing: DS.Spacing.xs) {
            Image(systemName: model.timing == .future ? "calendar.badge.plus" : "tshirt")
                .font(.system(size: DS.IconSize.xl, weight: .light))
                .foregroundStyle(.secondary)

            Text(String(localized: "calendar_no_outfit"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Text(model.timing == .future
                 ? String(localized: "calendar_plan_outfit")
                 : String(localized: "calendar_select_worn_items"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                DS.haptic(0.4)
                if model.timing == .future, model.isInPlannerWindow {
                    actions.onOpenPlanner()
                } else {
                    actions.onEditLook()
                }
            } label: {
                Label(
                    model.timing == .future && model.isInPlannerWindow
                        ? String(localized: "calendar_open_in_planner")
                        : String(localized: "calendar_choose_look"),
                    systemImage: model.timing == .future && model.isInPlannerWindow ? "sparkles" : "plus"
                )
            }
            .dsSecondaryButton()
            .padding(.top, DS.Spacing.xxs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.md)
    }

    // MARK: Photos

    private var photoStrip: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                DSSectionHeader(String(localized: "calendar_day_photos"), icon: "photo.on.rectangle")
                if !model.photoPaths.isEmpty {
                    Text("\(model.photoPaths.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(Array(model.photoPaths.enumerated()), id: \.offset) { index, path in
                        DSAsyncStoredImage(path: path, height: Self.photoSize, cornerRadius: DS.Radius.sm, displayWidth: Self.photoSize)
                            .frame(width: Self.photoSize, height: Self.photoSize)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                            .contextMenu {
                                if let url = ImageStore.fileURL(path: path) {
                                    ShareLink(item: url) {
                                        Label(String(localized: "action_share"), systemImage: "square.and.arrow.up")
                                    }
                                }
                                Button(role: .destructive) {
                                    actions.onRemovePhoto(index)
                                } label: {
                                    Label(String(localized: "backdrop_remove_photo"), systemImage: "trash")
                                }
                            }
                            .accessibilityLabel(String(localized: "calendar_day_photos"))
                    }

                    addPhotoTile
                }
                .padding(.vertical, DS.Spacing.xxs)
            }
        }
    }

    private static let photoSize: CGFloat = 84

    private var addPhotoTile: some View {
        Menu {
            Button(String(localized: "garment_choose_library"), systemImage: "photo.on.rectangle") {
                showPhotoLibrary = true
            }
            Button(String(localized: "garment_take_photo"), systemImage: "camera") {
                actions.onOpenCamera()
            }
        } label: {
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .foregroundStyle(.secondary.opacity(0.6))
                .frame(width: Self.photoSize, height: Self.photoSize)
                .overlay {
                    VStack(spacing: DS.Spacing.xxs) {
                        Image(systemName: "plus")
                            .font(.title3.weight(.medium))
                        Text(String(localized: "calendar_add_photo"))
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "calendar_add_photo"))
    }

    // MARK: Reflection (temperature + notes)

    private var reflectionSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if model.hasLook {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Spacing.xs) {
                        reflectionLabel
                        Spacer(minLength: DS.Spacing.xs)
                        temperatureChips
                    }
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        reflectionLabel
                        temperatureChips
                    }
                }
            }

            HStack(alignment: .top, spacing: DS.Spacing.xs) {
                Image(systemName: "note.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                TextField(String(localized: "calendar_notes_placeholder"), text: $notesDraft, axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(1...4)
                    .focused($notesFocused)
                    .submitLabel(.done)
                    .onSubmit { commitNotes() }
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .liquidGlassPill(tint: Color.primary.opacity(0.03))
        }
    }

    private var reflectionLabel: some View {
        Text(String(localized: "calendar_how_was_it"))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var temperatureChips: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(TemperatureFeedback.allCases) { feedback in
                DSChip(
                    feedback.label,
                    isSelected: model.temperatureFeedback == feedback,
                    color: chipColor(for: feedback)
                ) {
                    actions.onSetTemperatureFeedback(feedback)
                }
            }
        }
    }

    private func chipColor(for feedback: TemperatureFeedback) -> Color {
        switch feedback {
        case .tooCold: return .blue
        case .justRight: return .green
        case .tooWarm: return .orange
        }
    }

    private func commitNotes() {
        let trimmed = notesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != model.notes else { return }
        actions.onSaveNotes(trimmed)
    }

    // MARK: Primary Action

    @ViewBuilder
    private var primaryAction: some View {
        switch model.timing {
        case .future:
            if model.hasLook, model.isInPlannerWindow {
                Button {
                    DS.haptic(0.4)
                    actions.onOpenPlanner()
                } label: {
                    Label(String(localized: "calendar_open_in_planner"), systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .dsSecondaryButton()
            }
        case .past, .today:
            if model.hasLook, model.status != .worn, model.status != .notWorn {
                HStack(spacing: DS.Spacing.xs) {
                    Button {
                        DS.haptic(0.6)
                        actions.onSetStatus(.worn)
                    } label: {
                        Label(String(localized: "planner_swipe_did_wear"), systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .dsPrimaryButton()

                    Button {
                        DS.haptic(0.4)
                        actions.onSetStatus(.notWorn)
                    } label: {
                        Label(String(localized: "planner_swipe_did_not_wear"), systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .dsSecondaryButton()
                }
            }
        }
    }

    // MARK: Formatting

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE, d MMMM")
        return formatter
    }()
}
