import SwiftUI
import SwiftData
import UIKit

struct WardrobeView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var weather: WeatherCenter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Query(sort: \Garment.createdAt, order: .reverse) private var allGarments: [Garment]
    @Query private var wearEvents: [WearEvent]

    enum WardrobeSort: String, CaseIterable, Identifiable {
        case newest
        case oldest
        case name
        case brand
        case category
        case lastWorn

        var id: String { rawValue }

        var title: String {
            switch self {
            case .newest: return String(localized: "wardrobe_sort_newest")
            case .oldest: return String(localized: "wardrobe_sort_oldest")
            case .name: return String(localized: "wardrobe_sort_name")
            case .brand: return String(localized: "wardrobe_sort_brand")
            case .category: return String(localized: "wardrobe_sort_category")
            case .lastWorn: return String(localized: "wardrobe_sort_last_worn")
            }
        }
    }

    private enum SeasonScope {
        case current
        case all
    }
    
    // Filter States
    @State private var selectedCategory: Category? = nil
    @State private var selectedSeasons: Set<SeasonSuitability> = []
    @State private var seasonScope: SeasonScope = .current
    @State private var showTempSuitable: Bool = false
    @State private var showUnwornOnly: Bool = false
    @State private var showForgottenOnly: Bool = false
    @State private var showFilters: Bool = false

    @State private var selectedSort: WardrobeSort = .newest
    @State private var visibleGarments: [Garment] = []
    
    @State private var showDeleteAlert = false
    @State private var pendingDelete: Garment?
    @State private var selectedGarmentForEdit: Garment?
    @State private var currentDate: Date = Date()
    @State private var rebuildDebouncer = Debouncer(interval: 0.2)

    private var latestWearMap: [UUID: Date] {
        WearHistoryService.latestWearMap(events: wearEvents)
    }

    private var forgottenCutoff: Date {
        Calendar.current.date(byAdding: .day, value: -21, to: currentDate) ?? currentDate
    }

    // Filtered results
    private var filtered: [Garment] {
        var result = allGarments
        
        if let category = selectedCategory {
            result = result.filter { $0.category == category }
        }
        
        if !selectedSeasons.isEmpty {
            result = result.filter { garment in
                seasonMatches(garment, allowedSeasons: selectedSeasons)
            }
        } else if seasonScope == .current {
            result = result.filter {
                seasonMatches($0, allowedSeasons: [currentSeason])
            }
        }
        
        if showTempSuitable {
            let temp = weather.currentTempC
                ?? weather.forecasts.first.map { DayTemperatureProfile(from: $0).effectiveTemp }
            if let temp {
                result = result.filter { $0.isSuitableFor(temperature: temp) }
            }
        }

        if showUnwornOnly {
            result = result.filter { garment in
                AvailabilityService.lastWearDate(for: garment, latestWearMap: latestWearMap) == nil
            }
        }

        if showForgottenOnly {
            result = result.filter { garment in
                guard !garment.isCurrentlyUnavailable else { return false }
                let last = AvailabilityService.lastWearDate(for: garment, latestWearMap: latestWearMap)
                if let last { return last < forgottenCutoff }
                return garment.loveScore >= 40 || garment.isFavorite
            }
        }
        
        return result
    }

    private func rebuildVisibleGarments() {
        var result = filtered
        switch selectedSort {
        case .newest:
            result.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        case .oldest:
            result.sort { ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture) }
        case .name:
            result.sort {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
        case .brand:
            result.sort {
                normalizedBrand($0.brand).localizedCaseInsensitiveCompare(normalizedBrand($1.brand)) == .orderedAscending
            }
        case .category:
            result.sort {
                $0.category.title.localizedCaseInsensitiveCompare($1.category.title) == .orderedAscending
            }
        case .lastWorn:
            result.sort {
                let left = AvailabilityService.lastWearDate(for: $0, latestWearMap: latestWearMap) ?? .distantPast
                let right = AvailabilityService.lastWearDate(for: $1, latestWearMap: latestWearMap) ?? .distantPast
                return left < right
            }
        }
        visibleGarments = result
    }

    private func scheduleRebuildVisibleGarments() {
        rebuildDebouncer.schedule {
            NotificationCenter.default.post(name: .wardrobeRebuildVisible, object: nil)
        }
    }

    private var activeFilterCount: Int {
        var count = 0
        if selectedCategory != nil { count += 1 }
        if !selectedSeasons.isEmpty { count += selectedSeasons.count }
        if showTempSuitable { count += 1 }
        if showUnwornOnly { count += 1 }
        if showForgottenOnly { count += 1 }
        return count
    }

    var body: some View {
        NavigationStack {
            wardrobeScrollContent
                .scrollContentBackground(.hidden)
                .refreshable {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .withLocalAppBackdrop()
                .navigationTitle(String(localized: "nav_wardrobe"))
                .minimalCollapsingNavBar()
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        NavigationLink {
                            UnavailableItemsView()
                        } label: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        sortMenu
                        filterButton
                    }
                }
                .alert("Delete item?", isPresented: $showDeleteAlert) {
                    Button("Cancel", role: .cancel) { pendingDelete = nil }
                    Button("Delete", role: .destructive) {
                        if let g = pendingDelete {
                            context.delete(g)
                            try? context.save()
                            pendingDelete = nil
                            rebuildVisibleGarments()
                        }
                    }
                } message: {
                    Text("This action cannot be undone.")
                }
                .sheet(item: $selectedGarmentForEdit) { garment in
                    NavigationStack {
                        EditGarmentView(garment: garment)
                    }
                }
                .onAppear {
                    rebuildVisibleGarments()
                    refreshCurrentDate()
                }
                .onReceive(NotificationCenter.default.publisher(for: .wardrobeRebuildVisible)) { _ in
                    rebuildVisibleGarments()
                }
                .modifier(WardrobeRebuildTriggers(
                    filterSignature: wardrobeFilterSignature,
                    onRebuild: scheduleRebuildVisibleGarments,
                    onForeground: {
                        refreshCurrentDate()
                        scheduleRebuildVisibleGarments()
                    }
                ))
        }
    }

    private var wardrobeFilterSignature: String {
        [
            String(allGarments.count),
            String(wearEvents.count),
            selectedCategory?.rawValue ?? "-",
            selectedSeasons.map(\.rawValue).sorted().joined(separator: ","),
            seasonScope == .current ? "current" : "all",
            showTempSuitable ? "1" : "0",
            showUnwornOnly ? "1" : "0",
            showForgottenOnly ? "1" : "0",
            selectedSort.rawValue,
            weather.currentTempC.map { String(Int($0)) } ?? "-"
        ].joined(separator: "|")
    }

    private var wardrobeScrollContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                categoryFilter
                seasonScopeFilter
                smartFilterChips

                if showFilters {
                    advancedFilters
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if visibleGarments.isEmpty {
                    DSEmptyState(
                        icon: "tshirt",
                        title: String(localized: "wardrobe_empty_title"),
                        message: String(localized: "wardrobe_empty_message")
                    )
                    .padding(DS.Spacing.lg)
                    .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.top, DS.Spacing.lg)
                    .padding(.bottom, 100)
                } else {
                    LazyVGrid(
                        columns: wardrobeColumns,
                        spacing: DS.Grid.rowSpacing
                    ) {
                        ForEach(visibleGarments) { garment in
                            NavigationLink {
                                EditGarmentView(garment: garment)
                            } label: {
                                wardrobeTile(garment)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .contextMenu { wardrobeContextMenu(for: garment) }
                        }
                    }
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.top, DS.Spacing.xs)
                    .padding(.bottom, 100)
                }
            }
        }
    }

    @ViewBuilder
    private func wardrobeContextMenu(for garment: Garment) -> some View {
        Button {
            selectedGarmentForEdit = garment
        } label: {
            Label(String(localized: "planner_go_to_item"), systemImage: "info.circle")
        }

        Button {
            replaceInPlanner(with: garment)
        } label: {
            Label(String(localized: "planner_replace_single_item"), systemImage: "arrow.triangle.2.circlepath")
        }

        if garment.isCurrentlyUnavailable {
            Button {
                garment.markAvailable()
                try? context.save()
                rebuildVisibleGarments()
            } label: {
                Label(String(localized: "planner_mark_available_now"), systemImage: "checkmark.circle")
            }
        } else {
            Menu {
                Button(String(localized: "planner_unavailable_1d")) {
                    snoozeGarment(garment, days: 1)
                }
                Button(String(localized: "planner_unavailable_2d")) {
                    snoozeGarment(garment, days: 2)
                }
                Button(String(localized: "planner_unavailable_1w")) {
                    snoozeGarment(garment, days: 7)
                }
                Button(String(localized: "wardrobe_snooze_2w")) {
                    snoozeGarment(garment, days: 14)
                }
                Button(String(localized: "wardrobe_snooze_1m")) {
                    snoozeGarment(garment, days: 30)
                }
                Divider()
                Button(String(localized: "planner_mark_unavailable_now"), role: .destructive) {
                    garment.markUnavailable()
                    try? context.save()
                    rebuildVisibleGarments()
                }
            } label: {
                Label(String(localized: "wardrobe_snooze_menu"), systemImage: "moon.zzz")
            }
        }

        Button {} label: {
            Label(lastWornText(for: garment), systemImage: "clock")
        }
        .disabled(true)

        Button(role: .destructive) {
            pendingDelete = garment
            showDeleteAlert = true
        } label: {
            Label(String(localized: "action_delete"), systemImage: "trash")
        }
    }
    
    // MARK: - Filter Button
    
    private var filterButton: some View {
        Button {
            DS.haptic(0.3)
            withAnimation(DS.Animation.standard) {
                showFilters.toggle()
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: showFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                
                if activeFilterCount > 0 && !showFilters {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .offset(x: 2, y: -2)
                }
            }
        }
    }
    
    // MARK: - Category Filter
    
    private var categoryFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LiquidGlassGroup(spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.xs) {
                    DSChip("All", isSelected: selectedCategory == nil) {
                        selectedCategory = nil
                    }
                    ForEach(Category.allCases) { cat in
                        DSChip(cat.title, isSelected: selectedCategory == cat) {
                            selectedCategory = cat
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
        }
        .liquidGlassSurface(cornerRadius: DS.Radius.card, tint: Color.accentColor.opacity(0.02), castsShadow: false)
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.sm)
    }

    private var seasonScopeFilter: some View {
        LiquidGlassGroup(spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                DSChip(
                    String(format: NSLocalizedString("wardrobe_current_season_filter", comment: ""), currentSeason.shortTitle),
                    icon: currentSeason.icon,
                    isSelected: seasonScope == .current && selectedSeasons.isEmpty,
                    color: currentSeason.color
                ) {
                    selectedSeasons.removeAll()
                    seasonScope = .current
                }

                DSChip(
                    String(localized: "wardrobe_show_all_seasons"),
                    icon: "square.grid.2x2",
                    isSelected: seasonScope == .all && selectedSeasons.isEmpty,
                    color: .accentColor
                ) {
                    selectedSeasons.removeAll()
                    seasonScope = .all
                }

                Spacer()
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.xs)
    }
    
    // MARK: - Advanced Filters
    
    private var advancedFilters: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Season filter
            DSSectionHeader(String(localized: "wardrobe_manual_season_filter"))
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(SeasonSuitability.allCases, id: \.self) { season in
                        DSChip(
                            season.shortTitle,
                            icon: season.icon,
                            isSelected: selectedSeasons.contains(season),
                            color: season.color
                        ) {
                            toggleSeason(season)
                        }
                    }
                }
            }
            
            // Temperature toggle
            if let temp = weather.currentTempC
                ?? weather.forecasts.first.map({ DayTemperatureProfile(from: $0).effectiveTemp }) {
                HStack {
                    Toggle(isOn: $showTempSuitable) {
                        Label(
                            String(format: NSLocalizedString("wardrobe_filter_temp_format", comment: ""), Int(temp)),
                            systemImage: "thermometer.medium"
                        )
                        .font(.subheadline)
                    }
                    .tint(.accentColor)
                }
            }

            Toggle(isOn: $showUnwornOnly) {
                Label(String(localized: "wardrobe_filter_unworn"), systemImage: "sparkles")
                    .font(.subheadline)
            }
            .tint(.accentColor)

            Toggle(isOn: $showForgottenOnly) {
                Label(String(localized: "wardrobe_filter_forgotten"), systemImage: "clock.arrow.circlepath")
                    .font(.subheadline)
            }
            .tint(.accentColor)
            
            // Clear button
            if activeFilterCount > 0 {
                Button {
                    DS.haptic(0.3)
                    clearAllFilters()
                } label: {
                    Label(String(localized: "wardrobe_clear_filters"), systemImage: "xmark.circle")
                        .font(.caption.weight(.semibold))
                }
                .dsSecondaryButton()
            }
        }
        .padding(DS.Spacing.md)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
        .padding(.horizontal, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.sm)
    }
    
    // MARK: - Actions
    
    private func toggleSeason(_ season: SeasonSuitability) {
        withAnimation(DS.Animation.fast) {
            if selectedSeasons.contains(season) {
                selectedSeasons.remove(season)
            } else {
                selectedSeasons.insert(season)
                seasonScope = .all
            }
        }
    }
    
    private func clearAllFilters() {
        withAnimation(DS.Animation.standard) {
            selectedCategory = nil
            selectedSeasons.removeAll()
            seasonScope = .current
            showTempSuitable = false
            showUnwornOnly = false
            showForgottenOnly = false
        }
    }

    private var smartFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                DSChip(
                    String(localized: "wardrobe_filter_weather_chip"),
                    icon: "thermometer.medium",
                    isSelected: showTempSuitable
                ) {
                    showTempSuitable.toggle()
                    scheduleRebuildVisibleGarments()
                }
                DSChip(
                    String(localized: "wardrobe_filter_unworn_chip"),
                    icon: "sparkles",
                    isSelected: showUnwornOnly
                ) {
                    showUnwornOnly.toggle()
                    if showUnwornOnly { showForgottenOnly = false }
                    scheduleRebuildVisibleGarments()
                }
                DSChip(
                    String(localized: "wardrobe_filter_forgotten_chip"),
                    icon: "clock.arrow.circlepath",
                    isSelected: showForgottenOnly
                ) {
                    showForgottenOnly.toggle()
                    if showForgottenOnly { showUnwornOnly = false }
                    scheduleRebuildVisibleGarments()
                }
            }
            .padding(.horizontal, DS.Spacing.md)
        }
        .padding(.top, DS.Spacing.xs)
        .padding(.bottom, DS.Spacing.xxs)
    }

    private var currentSeason: SeasonSuitability {
        let month = Calendar.current.component(.month, from: currentDate)
        switch month {
        case 6...9:
            return .summer
        case 12, 1, 2:
            return .winter
        default:
            return .transitional
        }
    }

    private func seasonMatches(_ garment: Garment, allowedSeasons: Set<SeasonSuitability>) -> Bool {
        guard let season = garment.seasonSuitability else {
            return true
        }
        return season == .allSeason || allowedSeasons.contains(season)
    }

    private var wardrobeColumns: [GridItem] {
        // Flexible with no large minimum — 3 columns must fit phone width
        // without forcing tiles past the screen edge.
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: DS.Grid.columnSpacing, alignment: .top),
            count: 3
        )
    }

    private var sortMenu: some View {
        Menu {
            Picker(String(localized: "wardrobe_sort_title"), selection: $selectedSort) {
                ForEach(WardrobeSort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    private func normalizedBrand(_ brand: String?) -> String {
        let value = (brand ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "zzzz" : value
    }

    private func lastWornText(for garment: Garment) -> String {
        if let date = garment.lastWorn {
            let days = max(0, Calendar.current.dateComponents([.day], from: date, to: currentDate).day ?? 0)
            let daysText = String(format: NSLocalizedString("planner_days_ago_format", comment: ""), days)
            return String(format: NSLocalizedString("planner_last_worn_format", comment: ""), daysText)
        }
        return String(localized: "planner_never_worn")
    }

    private func refreshCurrentDate() {
        currentDate = Date()
    }

    private func replaceInPlanner(with garment: Garment) {
        let slot = OutfitSlot.from(category: garment.category)
        let today = Calendar.current.startOfDay(for: Date())
        let dates = (0..<3).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
        let plans = dates.map { DayPlanService.shared.planFor(date: $0, context: context) }

        // Abort if locked in another day
        for plan in plans {
            if plan.lockedSlots.contains(slot),
               plan.slotAssignments[slot] == garment.id {
                return
            }
        }

        // Remove from other days (if present and not locked)
        for plan in plans.dropFirst() {
            var assignments = existingAssignments(for: plan)
            let locked = plan.lockedSlots
            if assignments[slot] == garment.id {
                if locked.contains(slot) { return }
                assignments[slot] = nil
                plan.setSlotAssignments(assignments, lockedSlots: locked)
            }
        }

        // Set on today
        let target = plans[0]
        if target.lockedSlots.contains(slot) { return }
        var targetAssignments = existingAssignments(for: target)
        targetAssignments[slot] = garment.id
        target.setSlotAssignments(targetAssignments, lockedSlots: target.lockedSlots)
        try? context.save()
    }

    private func existingAssignments(for plan: DayPlan) -> [OutfitSlot: UUID?] {
        if !plan.slotAssignments.isEmpty {
            return plan.slotAssignments.mapValues { Optional($0) }
        }
        var assignments: [OutfitSlot: UUID?] = [:]
        let ids = plan.selectedGarmentIDs
        for id in ids {
            if let garment = allGarments.first(where: { $0.id == id }) {
                let slot = OutfitSlot.from(category: garment.category)
                if assignments[slot] == nil {
                    assignments[slot] = garment.id
                }
            }
        }
        return assignments
    }

    private func wardrobeTile(_ garment: Garment) -> some View {
        let model = WardrobeTileModel(
            id: garment.id,
            displayTitle: garment.displayTitle,
            metaLine: wardrobeMetaLine(for: garment),
            categoryIcon: garment.category.icon,
            thumbnailPath: garment.thumbnailPath,
            imagePath: garment.imagePath
        )
        return WardrobeTileView(model: model)
            .equatable()
    }

    private func wardrobeMetaLine(for garment: Garment) -> String {
        var parts: [String] = []
        if let season = garment.seasonSuitability?.title { parts.append(season) }
        if let fit = garment.fitTag?.title { parts.append(fit) }
        if let size = garment.sizeOption?.title { parts.append(size) }
        return parts.isEmpty ? String(localized: "garment_meta_default") : parts.joined(separator: " · ")
    }

    private func snoozeGarment(_ garment: Garment, days: Int) {
        let until = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        garment.markUnavailable(until: until)
        try? context.save()
        rebuildVisibleGarments()
        DS.haptic(0.4)
    }
}

private struct WardrobeTileModel: Equatable {
    let id: UUID
    let displayTitle: String
    let metaLine: String
    let categoryIcon: String
    let thumbnailPath: String?
    let imagePath: String?
}

private struct WardrobeTileView: View, Equatable {
    let model: WardrobeTileModel
    @State private var image: UIImage?

    static func == (lhs: WardrobeTileView, rhs: WardrobeTileView) -> Bool {
        lhs.model == rhs.model
    }

    var body: some View {
        Color.clear
            .aspectRatio(DS.AspectRatio.garmentTile, contentMode: .fit)
            .overlay {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                        .fill(Color(.secondarySystemBackground).opacity(0.35))

                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            .clipped()
                    } else {
                        Image(systemName: model.categoryIcon)
                            .font(.system(size: DS.IconSize.xl))
                            .foregroundStyle(.tertiary)
                    }

                    LinearGradient(
                        colors: [Color.black.opacity(0.55), Color.black.opacity(0.0)],
                        startPoint: .bottom,
                        endPoint: .top
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(model.metaLine)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                    .padding(DS.Spacing.xs)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
                    .blendMode(.plusLighter)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
            .task(id: "\(model.id.uuidString)|\(model.thumbnailPath ?? "")|\(model.imagePath ?? "")") {
                let cacheKey = model.id.uuidString
                if let cached = ImageStore.cachedThumbnail(cacheKey: cacheKey) {
                    image = cached
                    return
                }

                let thumbPath = model.thumbnailPath
                let imagePath = model.imagePath
                let maxPixel: CGFloat = 360

                let loaded: UIImage? = await Task.detached(priority: .utility) {
                    if let thumbPath,
                       let thumb = ImageStore.loadStoredThumbnail(path: thumbPath, cacheKey: cacheKey) {
                        return thumb
                    }
                    if let imagePath {
                        return ImageStore.loadThumbnail(path: imagePath, maxPixelSize: maxPixel)
                    }
                    return nil as UIImage?
                }.value
                image = loaded
            }
    }
}

// MARK: - SeasonSuitability UI Extensions

extension SeasonSuitability {
    var shortTitle: String {
        switch self {
        case .summer: return String(localized: "season_summer_short")
        case .winter: return String(localized: "season_winter_short")
        case .transitional: return String(localized: "season_transitional_short")
        case .allSeason: return String(localized: "season_all_short")
        }
    }
    
    var color: Color {
        switch self {
        case .summer: return .orange
        case .winter: return .blue
        case .transitional: return .green
        case .allSeason: return .purple
        }
    }
}

private struct WardrobeRebuildTriggers: ViewModifier {
    let filterSignature: String
    let onRebuild: () -> Void
    let onForeground: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: filterSignature) { _, _ in onRebuild() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                onForeground()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                onForeground()
            }
    }
}

// MARK: - Legacy Components (for compatibility)

struct GarmentTile: View {
    let g: Garment
    
    var body: some View {
        DSGarmentTile(g)
    }
}

struct Chip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    
    var body: some View {
        DSChip(title, isSelected: isOn, action: action)
    }
}

struct SeasonChip: View {
    let season: SeasonSuitability
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        DSChip(
            season.shortTitle,
            icon: season.icon,
            isSelected: isSelected,
            color: season.color,
            action: action
        )
    }
}
