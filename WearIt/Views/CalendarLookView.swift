import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct CalendarLookView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var auth: AuthManager

    @State private var selectedDate: Date = Date()
    @State private var photosPickerItems: [PhotosPickerItem] = []
    @State private var showCamera: Bool = false
    @State private var isSaving: Bool = false
    @State private var message: String?
    @State private var showAlert: Bool = false
    @State private var showGarmentPicker: Bool = false
    @State private var currentDate: Date = Date()

    @Query(sort: \DailyLook.date, order: .reverse) private var dailyLooks: [DailyLook]
    @Query(sort: \DayPlan.date, order: .reverse) private var dayPlans: [DayPlan]
    @Query(sort: \Garment.createdAt, order: .reverse) private var allGarments: [Garment]

    private var looksForSelectedDay: DailyLook? {
        let day = Calendar.current.startOfDay(for: selectedDate)
        return dailyLooks.first(where: { Calendar.current.isDate($0.date, inSameDayAs: day) })
    }
    
    private var planForSelectedDay: DayPlan? {
        let day = Calendar.current.startOfDay(for: selectedDate)
        return dayPlans.first(where: { Calendar.current.isDate($0.date, inSameDayAs: day) })
    }
    
    private var isSelectedDatePast: Bool {
        Calendar.current.startOfDay(for: selectedDate) < Calendar.current.startOfDay(for: currentDate)
    }
    
    private var isSelectedDateToday: Bool {
        Calendar.current.isDate(selectedDate, inSameDayAs: currentDate)
    }
    
    private var isSelectedDateFuture: Bool {
        Calendar.current.startOfDay(for: selectedDate) > Calendar.current.startOfDay(for: currentDate)
    }
    
    /// Get garments for the current plan
    private var plannedGarments: [Garment] {
        guard let plan = planForSelectedDay else { return [] }
        return plan.selectedGarmentIDs.compactMap { id in
            allGarments.first { $0.id == id }
        }
    }

    private func refreshCurrentDate() {
        currentDate = Date()
    }

    var body: some View {
        ZStack {
            LiquidGlassBackdrop()
            
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    // Date Picker
                    DatePicker(
                        String(localized: "calendar_title"),
                        selection: $selectedDate,
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.graphical)
                    .dsCard(padding: DS.Spacing.sm)
                    
                    // Day status badge
                    dayStatusBadge
                    
                    // Planned outfit section (editable for past/today/future)
                    plannedOutfitSection
                    
                    // Photo section for past/today
                    if !isSelectedDateFuture {
                        actionButtons
                        
                        if let look = looksForSelectedDay, !look.photoPaths.isEmpty {
                            photoSection(for: look)
                        } else if !isSelectedDateFuture {
                            emptyState
                        }
                    }
                    
                    // History
                    historySection
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.sm)
                .padding(.bottom, 100)
            }
        }
        .navigationTitle(String(localized: "nav_calendar"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onChange(of: photosPickerItems) { _, _ in
            handlePhotosPicker()
        }
        .onAppear {
            refreshCurrentDate()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshCurrentDate()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            refreshCurrentDate()
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                if let img = image {
                    Task { await save(images: [img]) }
                }
            }
        }
        .sheet(isPresented: $showGarmentPicker) {
            GarmentPickerSheet(
                garments: allGarments,
                selectedIDs: plannedGarments.map { $0.id },
                lockedIDs: planForSelectedDay?.lockedGarmentIDs ?? []
            ) { selectedIDs, lockedIDs in
                updatePlan(selectedIDs: selectedIDs, lockedIDs: lockedIDs)
            }
        }
        .alert(String(localized: "success_title"), isPresented: $showAlert, presenting: message) { _ in
            Button(String(localized: "action_close"), role: .cancel) { }
        } message: { msg in
            Text(msg)
        }
    }
    
    // MARK: - Day Status Badge
    
    private var dayStatusBadge: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            Text(statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
            
            Spacer()
            
            if let plan = planForSelectedDay, plan.wasWornConfirmed {
                Label(String(localized: "calendar_mark_as_worn"), systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .background(statusColor.opacity(0.1), in: Capsule())
    }
    
    private var statusIcon: String {
        if isSelectedDatePast { return "clock.arrow.circlepath" }
        if isSelectedDateToday { return "sun.max.fill" }
        return "calendar.badge.plus"
    }
    
    private var statusColor: Color {
        if isSelectedDatePast { return .secondary }
        if isSelectedDateToday { return .orange }
        return .blue
    }
    
    private var statusText: String {
        if isSelectedDatePast { return String(localized: "calendar_past_day") }
        if isSelectedDateToday { return String(localized: "day_today") }
        return String(localized: "calendar_future_day")
    }
    
    // MARK: - Planned Outfit Section
    
    private var plannedOutfitSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                DSSectionHeader(
                    isSelectedDateFuture ? String(localized: "calendar_plan_outfit") : String(localized: "calendar_outfit_for_day"),
                    icon: "tshirt.fill"
                )
                
                Spacer()
                
                Button {
                    DS.haptic(0.4)
                    showGarmentPicker = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.subheadline)
                }
            }
            
            if plannedGarments.isEmpty {
                DSEmptyState(
                    icon: "calendar.badge.plus",
                    title: String(localized: "calendar_no_outfit"),
                    message: isSelectedDateFuture
                        ? String(localized: "calendar_plan_outfit")
                        : String(localized: "calendar_select_worn_items"),
                    actionTitle: String(localized: "action_add")
                ) {
                    showGarmentPicker = true
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 70, maximum: 90), spacing: DS.Spacing.xs)],
                    spacing: DS.Spacing.xs
                ) {
                    ForEach(plannedGarments) { garment in
                        ZStack(alignment: .topTrailing) {
                            DSGarmentThumbnail(garment, size: .medium)
                            
                            // Lock indicator
                            if planForSelectedDay?.lockedGarmentIDs.contains(garment.id) == true {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .background(Color.accentColor, in: Circle())
                                    .offset(x: 4, y: -4)
                            }
                        }
                    }
                }
                .dsCard(padding: DS.Spacing.sm)
                
                // Actions for past/today
                if !isSelectedDateFuture && !plannedGarments.isEmpty {
                    if planForSelectedDay?.wasWornConfirmed != true {
                        Button {
                            DS.haptic(0.6)
                            confirmWorn()
                        } label: {
                            Label(String(localized: "calendar_mark_as_worn"), systemImage: "checkmark.seal.fill")
                        }
                        .dsPrimaryButton()
                    }
                }
            }
        }
        .dsCard()
    }

    // MARK: - UI Sections

    private var actionButtons: some View {
        VStack(spacing: DS.Spacing.xs) {
            PhotosPicker(selection: $photosPickerItems, maxSelectionCount: 8, matching: .images) {
                Label(String(localized: "garment_choose_library"), systemImage: "photo.on.rectangle")
            }
            .dsPrimaryButton()

            Button {
                showCamera = true
            } label: {
                Label(String(localized: "garment_take_photo"), systemImage: "camera")
                    .frame(maxWidth: .infinity)
            }
            .dsSecondaryButton()
        }
        .dsCard(padding: DS.Spacing.sm)
    }

    private func photoSection(for look: DailyLook) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                DSSectionHeader(String(format: NSLocalizedString("calendar_worn_on", comment: ""), formattedDate(look.date)))
                Spacer()
                Text("\(look.photoPaths.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: DS.Spacing.xs)], spacing: DS.Spacing.xs) {
                ForEach(Array(look.photoPaths.enumerated()), id: \.offset) { index, path in
                    if let img = ImageStore.loadImage(path: path) {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 120)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))

                            Button {
                                removePhoto(at: index, from: look)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.white, .black.opacity(0.5))
                            }
                            .padding(DS.Spacing.xxs)
                        }
                    } else {
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .fill(Color(.systemGray6))
                            .frame(height: 120)
                            .overlay {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                            }
                    }
                }
            }
        }
        .dsCard()
    }

    private var emptyState: some View {
        DSEmptyState(
            icon: "photo.on.rectangle.angled",
            title: String(localized: "calendar_no_outfit"),
            message: String(localized: "calendar_add_photos")
        )
        .dsCardCompact()
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "calendar_outfit_log"), icon: "clock.fill")
            
            if dailyLooks.isEmpty && dayPlans.isEmpty {
                Text(String(localized: "calendar_add_photos"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                // Combined history from looks and plans
                let combined = combinedHistory()
                ForEach(combined, id: \.date) { entry in
                    HistoryRow(
                        date: entry.date,
                        photoCount: entry.photoCount,
                        hasOutfit: entry.hasOutfit,
                        wasWorn: entry.wasWorn
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedDate = entry.date
                    }
                }
            }
        }
        .dsCard()
    }
    
    private func combinedHistory() -> [HistoryEntry] {
        var entries: [Date: (photoCount: Int, hasOutfit: Bool, wasWorn: Bool)] = [:]
        
        for look in dailyLooks {
            let day = Calendar.current.startOfDay(for: look.date)
            entries[day] = (look.photoPaths.count, false, false)
        }
        
        for plan in dayPlans {
            let day = Calendar.current.startOfDay(for: plan.date)
            let existing = entries[day] ?? (0, false, false)
            entries[day] = (existing.photoCount, plan.hasSelectedItems, plan.wasWornConfirmed)
        }
        
        return entries
            .map { HistoryEntry(date: $0.key, photoCount: $0.value.photoCount, hasOutfit: $0.value.hasOutfit, wasWorn: $0.value.wasWorn) }
            .sorted { $0.date > $1.date }
            .prefix(15)
            .map { $0 }
    }

    // MARK: - Actions

    private func handlePhotosPicker() {
        guard !photosPickerItems.isEmpty else { return }
        Task {
            var images: [UIImage] = []
            for item in photosPickerItems {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    images.append(img)
                }
            }
            photosPickerItems = []
            await save(images: images)
        }
    }

    private func save(images: [UIImage]) async {
        guard !images.isEmpty else { return }
        await MainActor.run { isSaving = true }
        do {
            let resized = images.map { $0.resized(max: 1400) }
            var newPaths: [String] = []
            for img in resized {
                if let jpg = img.jpegData(compressionQuality: 0.9) {
                    let path = try ImageStore.save(data: jpg, preferredExt: "jpg")
                    newPaths.append(path)
                }
            }

            await MainActor.run {
                let day = Calendar.current.startOfDay(for: selectedDate)
                let look = looksForSelectedDay ?? createLook(for: day)
                look.photoPaths.append(contentsOf: newPaths)
                try? context.save()
                message = String(localized: "success_saved")
                showAlert = true
            }
        } catch {
            await MainActor.run {
                message = String(localized: "error_save_failed")
                showAlert = true
            }
        }
        await MainActor.run { isSaving = false }
    }

    private func createLook(for day: Date) -> DailyLook {
        let look = DailyLook(date: day, photoPaths: [])
        if let profile = currentUserProfile() {
            look.ownerID = profile.id
            if !profile.dailyLookIDs.contains(look.id) {
                profile.dailyLookIDs.append(look.id)
            }
        }
        context.insert(look)
        return look
    }

    private func removePhoto(at index: Int, from look: DailyLook) {
        guard look.photoPaths.indices.contains(index) else { return }
        let path = look.photoPaths.remove(at: index)
        ImageStore.delete(path: path)
        try? context.save()
        message = String(localized: "success_deleted")
        showAlert = true
    }

    private func refresh() {
        message = String(localized: "success_updated")
        showAlert = true
    }
    
    private func confirmWorn() {
        let plan = planForSelectedDay ?? DayPlanService.shared.planFor(date: selectedDate, context: context)
        plan.confirmWorn()
        
        // Also update garment lastWorn dates
        for garment in plannedGarments {
            if garment.lastWorn == nil || garment.lastWorn! < selectedDate {
                garment.lastWorn = selectedDate
                garment.timesWorn += 1
                garment.loveScore = min(100, garment.loveScore + 1)
            }
        }
        
        WearEventStore.markWorn(
            date: selectedDate,
            outfitID: plan.id,
            garmentIDs: plannedGarments.map(\.id),
            source: .calendar,
            context: context
        )

        try? context.save()
        message = String(localized: "success_saved")
        showAlert = true
    }
    
    private func updatePlan(selectedIDs: [UUID], lockedIDs: [UUID]) {
        let plan = planForSelectedDay ?? DayPlanService.shared.planFor(date: selectedDate, context: context)
        plan.setSelectedGarments(selectedIDs)
        plan.lockedGarmentIDs = lockedIDs
        try? context.save()
    }

    private func currentUserProfile() -> UserProfile? {
        guard let uid = auth.userIdentifier else { return nil }
        let desc = FetchDescriptor<UserProfile>()
        return (try? context.fetch(desc))?.first(where: { $0.userIdentifier == uid })
    }

    // MARK: - Helpers

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - History Entry

private struct HistoryEntry: Identifiable {
    let date: Date
    let photoCount: Int
    let hasOutfit: Bool
    let wasWorn: Bool
    
    var id: Date { date }
}

// MARK: - History Row

private struct HistoryRow: View {
    let date: Date
    let photoCount: Int
    let hasOutfit: Bool
    let wasWorn: Bool
    
    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(formattedDate)
                    .font(.subheadline)
                
                HStack(spacing: DS.Spacing.xs) {
                    if photoCount > 0 {
                        Label("\(photoCount)", systemImage: "photo")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if hasOutfit {
                        Label("", systemImage: "tshirt.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer()
            
            if wasWorn {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, DS.Spacing.xxs)
    }
    
    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - Garment Picker Sheet

struct GarmentPickerSheet: View {
    let garments: [Garment]
    let selectedIDs: [UUID]
    let lockedIDs: [UUID]
    let onSave: ([UUID], [UUID]) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var localSelectedIDs: Set<UUID> = []
    @State private var localLockedIDs: Set<UUID> = []
    @State private var selectedCategory: Category? = nil
    
    var filteredGarments: [Garment] {
        if let category = selectedCategory {
            return garments.filter { $0.category == category }
        }
        return garments
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Category filter
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.xs) {
                        DSChip(String(localized: "wardrobe_filter_all"), isSelected: selectedCategory == nil) {
                            selectedCategory = nil
                        }
                        ForEach(Category.allCases) { cat in
                            DSChip(cat.title, isSelected: selectedCategory == cat) {
                                selectedCategory = cat
                            }
                        }
                    }
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)
                }
                
                // Garment grid
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 80, maximum: 100), spacing: DS.Spacing.xs)],
                        spacing: DS.Spacing.xs
                    ) {
                        ForEach(filteredGarments) { garment in
                            GarmentPickerCell(
                                garment: garment,
                                isSelected: localSelectedIDs.contains(garment.id),
                                isLocked: localLockedIDs.contains(garment.id)
                            ) {
                                toggleSelection(garment.id)
                            } onLongPress: {
                                toggleLock(garment.id)
                            }
                        }
                    }
                    .padding(DS.Spacing.md)
                }
            }
            .navigationTitle(String(localized: "calendar_plan_outfit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action_save")) {
                        onSave(Array(localSelectedIDs), Array(localLockedIDs))
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            localSelectedIDs = Set(selectedIDs)
            localLockedIDs = Set(lockedIDs)
        }
        .presentationDetents([.medium, .large])
    }
    
    private func toggleSelection(_ id: UUID) {
        DS.haptic(0.4)
        if localSelectedIDs.contains(id) {
            localSelectedIDs.remove(id)
            localLockedIDs.remove(id)
        } else {
            localSelectedIDs.insert(id)
        }
    }
    
    private func toggleLock(_ id: UUID) {
        DS.haptic(0.6)
        if !localSelectedIDs.contains(id) {
            localSelectedIDs.insert(id)
        }
        
        if localLockedIDs.contains(id) {
            localLockedIDs.remove(id)
        } else {
            localLockedIDs.insert(id)
        }
    }
}

// MARK: - Garment Picker Cell

private struct GarmentPickerCell: View {
    let garment: Garment
    let isSelected: Bool
    let isLocked: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            DSGarmentThumbnail(garment, size: .medium)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                )
                .opacity(isSelected ? 1.0 : 0.6)
            
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Color.accentColor, in: Circle())
                    .offset(x: 4, y: -4)
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.white, Color.accentColor)
                    .offset(x: 4, y: -4)
            }
        }
        .onTapGesture {
            onTap()
        }
        .onLongPressGesture {
            onLongPress()
        }
    }
}

// MARK: - Camera Picker

private struct CameraPicker: UIViewControllerRepresentable {
    var completion: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completion: (UIImage?) -> Void
        init(completion: @escaping (UIImage?) -> Void) {
            self.completion = completion
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            completion(nil)
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            picker.dismiss(animated: true)
            let img = info[.originalImage] as? UIImage
            completion(img)
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


