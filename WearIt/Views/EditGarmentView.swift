//
//  EditGarmentView.swift
//  WearIt
//
//  Unified structured editing flow with auto-generated titles.
//  Same experience as AddGarmentView for consistency.

import SwiftUI
import SwiftData
import UIKit

struct EditGarmentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    @Bindable var garment: Garment
    
    @Query(sort: \Brand.name, order: .forward) private var brands: [Brand]

    // MARK: - Image Editing
    @StateObject private var imageService = ImageEditingService()
    
    // MARK: - Local State (for editing)
    @State private var isEditingTitle = false
    @State private var showAdvancedOptions = false
    @State private var showDeleteAlert = false
    @State private var errorMessage: String?
    @State private var hasUnsavedChanges = false
    @State private var brandText: String = ""
    @State private var showGalleryViewer = false
    @State private var galleryStartIndex = 0
    
    private let feedback = UIImpactFeedbackGenerator(style: .medium)

    // MARK: - Body

    var body: some View {
        ZStack {
            DS.Surface.bg
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    imageSection

                    contentArea
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Edit Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DS.Surface.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .imageEditing(service: imageService)
        .fullScreenCover(isPresented: $showGalleryViewer) {
            GalleryViewer(
                imagePaths: galleryImagePaths,
                startIndex: galleryStartIndex
            )
        }
        .onAppear {
            brandText = garment.brand ?? ""
            BrandStore.syncFromGarments(context: context)
        }
        .alert("Delete Item?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteItem() }
        } message: {
            Text("This action cannot be undone.")
        }
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "Something went wrong.")
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    feedback.impactOccurred()
                    saveChanges()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.Text.inverted)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(DS.Surface.inverted, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(DS.Border.subtle, lineWidth: 0.6)
                )
            }
        }
    }

    // MARK: - Sections

    private var imageSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .fill(DS.Surface.card)

            if let image = garment.resolvedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay(
                        LinearGradient(
                            colors: [Color.black.opacity(0.0), Color.black.opacity(0.35)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                    )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: garment.category.icon)
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(DS.Text.tertiary)
                    Text(String(localized: "garment_no_image"))
                        .font(.caption)
                        .foregroundStyle(DS.Text.secondary)
                }
            }

            if imageService.isProcessing {
                Color.black.opacity(0.3)
                ProgressView()
                    .tint(DS.Text.inverted)
            }
        }
        .frame(height: 260)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.18)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
        )
        .overlay(
            Rectangle()
                .strokeBorder(DS.Border.subtle, lineWidth: 1)
        )
    }

    private var contentArea: some View {
        VStack(spacing: DS.Spacing.xl) {
            coreDetailsCard
            seasonCard
            attributesCard
            advancedCard
            actionsCard
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 24)
    }

    private var coreDetailsCard: some View {
        card {
            imageActionsSection
            titleSection
            categorySection
            itemTypeSection
            if shouldShowFit || shouldShowSize {
                fitSizeSection
            }
            colorSection
            brandSection
        }
    }

    private var seasonCard: some View {
        card { seasonSection }
    }

    private var attributesCard: some View {
        card { attributesSection }
    }

    private var advancedCard: some View {
        card { advancedSection }
    }

    private var actionsCard: some View {
        card { actionsSection }
    }

    private var imageActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !galleryImagePaths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(galleryImagePaths.enumerated()), id: \.offset) { index, path in
                            if let image = ImageStore.loadImage(path: path) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .onTapGesture {
                                        galleryStartIndex = index
                                        showGalleryViewer = true
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            removeGalleryImage(at: index)
                                        } label: {
                                            Label(String(localized: "action_remove_photo"), systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Menu {
                    Button {
                        feedback.impactOccurred()
                        imageService.selectFromCamera { result in
                            applyImageResult(result)
                        }
                    } label: {
                        Label(String(localized: "garment_take_photo"), systemImage: "camera")
                    }

                    Button {
                        feedback.impactOccurred()
                        imageService.selectFromLibrary { result in
                            applyImageResult(result)
                        }
                    } label: {
                        Label(String(localized: "garment_choose_library"), systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Label(String(localized: "garment_change_image"), systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Menu {
                    Button {
                        feedback.impactOccurred()
                        imageService.selectFromCamera { result in
                            addGalleryImage(result)
                        }
                    } label: {
                        Label(String(localized: "garment_take_photo"), systemImage: "camera")
                    }

                    Button {
                        feedback.impactOccurred()
                        imageService.selectFromLibrary { result in
                            addGalleryImage(result)
                        }
                    } label: {
                        Label(String(localized: "garment_choose_library"), systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Label(String(localized: "garment_add_photo"), systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if garment.imagePath != nil || garment.imageData != nil {
                    Button(role: .destructive) {
                        feedback.impactOccurred(intensity: 0.5)
                        clearImage()
                    } label: {
                        Label(String(localized: "action_remove_photo"), systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
        }
    }

    private func card<Content: View>(
        cornerRadius: CGFloat = 16,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            content()
        }
        .padding(16)
        .sectionSurface(cornerRadius: cornerRadius)
    }

    private var galleryImagePaths: [String] {
        garment.additionalImagePaths ?? []
    }

    private var brandSuggestions: [Brand] {
        let text = brandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return Array(brands.filter { $0.name.localizedCaseInsensitiveContains(text) }.prefix(5))
    }

    private var shouldShowAddBrand: Bool {
        let text = brandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return !brands.contains(where: { $0.name.lowercased() == text.lowercased() })
    }
    
    private var titleSection: some View {
        VStack(spacing: 8) {
            if isEditingTitle {
                TextField("Custom title", text: Binding(
                    get: { garment.userTitleOverride ?? garment.autoGeneratedTitle },
                    set: { 
                        garment.userTitleOverride = $0
                        hasUnsavedChanges = true
                    }
                ))
                .textFieldStyle(.plain)
                .dsFieldStyle()
                .foregroundStyle(DS.Text.primary)
                .multilineTextAlignment(.center)
                .onSubmit { isEditingTitle = false }
                
                Button("Use Auto Title") {
                    garment.userTitleOverride = nil
                    isEditingTitle = false
                    hasUnsavedChanges = true
                }
                .font(.caption)
                .foregroundStyle(DS.Text.secondary)
            } else {
                Text(garment.displayTitle)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DS.Text.primary)
                
                Button {
                    isEditingTitle = true
                } label: {
                    Label("Edit Title", systemImage: "pencil")
                        .font(.caption)
                }
                .foregroundStyle(DS.Text.secondary)
            }
        }
    }
    
    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "garment_category"))
                .font(.headline)
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 10) {
                ForEach(Category.allCases) { cat in
                    Button {
                        feedback.impactOccurred(intensity: 0.5)
                        let previousCategory = garment.category
                        garment.category = cat
                        hasUnsavedChanges = true
                        
                        // Reset item type if it doesn't belong to new category
                        if previousCategory != cat, let current = garment.itemType, !cat.itemTypes.contains(current) {
                            garment.itemType = nil
                        }
                        if cat != .top && cat != .bottom {
                            garment.fitTag = nil
                        }
                        if cat != .top && cat != .bottom && cat != .shoes {
                            garment.sizeOption = nil
                        } else if let current = garment.sizeOption, !SizeOption.options(for: cat).contains(current) {
                            garment.sizeOption = nil
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: cat.icon)
                                .font(.title2)
                            Text(cat.title)
                                .font(.caption2.bold())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            garment.category == cat ? DS.Accent.primary.opacity(0.15) : DS.Surface.card,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .foregroundStyle(garment.category == cat ? DS.Accent.primary : DS.Text.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(garment.category == cat ? DS.Accent.primary : DS.Border.subtle, lineWidth: garment.category == cat ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    private var itemTypeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "garment_item_type"))
                .font(.headline)
            
            ItemTypeSelector(
                category: garment.category,
                selectedType: Binding(
                    get: { garment.itemType },
                    set: { 
                        garment.itemType = $0
                        hasUnsavedChanges = true
                    }
                )
            )
        }
    }

    private var shouldShowFit: Bool {
        garment.category == .top || garment.category == .bottom
    }

    private var shouldShowSize: Bool {
        garment.category == .top || garment.category == .bottom || garment.category == .shoes
    }

    private var sizeOptions: [SizeOption] {
        SizeOption.options(for: garment.category)
    }

    private var fitSizeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "fit_size_title"))
                .font(.headline)

            if shouldShowFit {
                SingleTagPicker(
                    title: String(localized: "fit_label"),
                    allTags: FitTag.allCases,
                    selectedTag: Binding(
                        get: { garment.fitTag },
                        set: {
                            garment.fitTag = $0
                            hasUnsavedChanges = true
                        }
                    ),
                    titleForTag: { $0.title }
                )
            }

            if shouldShowSize {
                SingleTagPicker(
                    title: String(localized: "size_label"),
                    allTags: sizeOptions,
                    selectedTag: Binding(
                        get: { garment.sizeOption },
                        set: {
                            garment.sizeOption = $0
                            hasUnsavedChanges = true
                        }
                    ),
                    titleForTag: { $0.title }
                )
            }
        }
    }
    
    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "garment_colors"))
                    .font(.headline)
                Spacer()
                if !garment.safeColorTags.isEmpty {
                    Text("\(garment.safeColorTags.count) selected")
                        .font(.caption)
                        .foregroundStyle(DS.Text.secondary)
                } else {
                    Text(String(localized: "garment_colors_recommended"))
                        .font(.caption)
                        .foregroundStyle(DS.Text.secondary)
                }
            }
            
            ColorTagSelector(selectedColors: Binding(
                get: { garment.safeColorTags },
                set: { 
                    garment.safeColorTags = $0
                    hasUnsavedChanges = true
                }
            ))
            
            Text(String(localized: "tag_bilingual_hint"))
                .font(.caption2)
                .foregroundStyle(DS.Text.secondary)
        }
    }
    
    private var brandSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "garment_brand"))
                .font(.headline)
            
            TextField(String(localized: "garment_brand_placeholder"), text: $brandText)
                .textFieldStyle(.plain)
                .dsFieldStyle()
                .foregroundStyle(DS.Text.primary)
                .onChange(of: brandText) { _, newValue in
                    garment.brand = newValue.isEmpty ? nil : newValue
                    hasUnsavedChanges = true
                }

            if !brandSuggestions.isEmpty || shouldShowAddBrand {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(brandSuggestions, id: \.name) { suggestion in
                        Button {
                            brandText = suggestion.name
                            garment.brand = suggestion.name
                            hasUnsavedChanges = true
                        } label: {
                            Text(suggestion.name)
                                .font(.caption)
                                .foregroundStyle(DS.Text.primary)
                        }
                        .buttonStyle(.plain)
                    }

                    if shouldShowAddBrand {
                        Button {
                            // Keep the typed brand
                        } label: {
                            Text(String(format: NSLocalizedString("brand_add_suggestion", comment: ""), brandText))
                                .font(.caption)
                                .foregroundStyle(DS.Text.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
    
    private var seasonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "garment_season"))
                .font(.headline)
            
            SeasonSelector(selectedSeason: Binding(
                get: { garment.seasonSuitability },
                set: { 
                    garment.seasonSuitability = $0
                    hasUnsavedChanges = true
                }
            ))
            
            if garment.seasonSuitability != nil {
                DisclosureGroup(String(localized: "garment_temperature_range")) {
                    TemperatureRangeSlider(
                        minTemp: Binding(
                            get: { garment.minTempC },
                            set: { garment.minTempC = $0; hasUnsavedChanges = true }
                        ),
                        maxTemp: Binding(
                            get: { garment.maxTempC },
                            set: { garment.maxTempC = $0; hasUnsavedChanges = true }
                        ),
                        defaultRange: garment.seasonSuitability?.defaultTempRange ?? (10, 25)
                    )
                }
                .font(.subheadline)
            }
        }
    }
    
    private var attributesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "garment_attributes"))
                .font(.headline)
            
            // Warmth
            HStack {
                Image(systemName: "thermometer.medium")
                    .foregroundStyle(.secondary)
                Text(String(localized: "garment_warmth"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { i in
                        Circle()
                            .fill(i <= garment.warmth ? DS.Accent.warmth : DS.Border.subtle.opacity(0.6))
                            .frame(width: 8, height: 8)
                    }
                }
                Stepper("", value: Binding(
                    get: { garment.warmth },
                    set: { garment.warmth = $0; hasUnsavedChanges = true }
                ), in: 1...5)
                .labelsHidden()
                .controlSize(.small)
            }
            
            // Formality
            HStack {
                Image(systemName: "briefcase")
                    .foregroundStyle(.secondary)
                Text(String(localized: "garment_formality"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { i in
                        Circle()
                            .fill(i <= garment.formality ? DS.Accent.primary : DS.Border.subtle.opacity(0.6))
                            .frame(width: 8, height: 8)
                    }
                }
                Stepper("", value: Binding(
                    get: { garment.formality },
                    set: { garment.formality = $0; hasUnsavedChanges = true }
                ), in: 1...5)
                .labelsHidden()
                .controlSize(.small)
            }
            
            // Love
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(DS.Accent.love)
                    Text(String(localized: "garment_love"))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(garment.loveScore)%")
                        .font(.caption.bold())
                        .foregroundStyle(DS.Accent.love)
                }
                Slider(value: Binding(
                    get: { Double(garment.loveScore) },
                    set: { garment.loveScore = Int($0); hasUnsavedChanges = true }
                ), in: 0...100)
                .tint(DS.Accent.love)
            }
            
            // Favorite
            Toggle(isOn: Binding(
                get: { garment.isFavorite },
                set: { garment.isFavorite = $0; hasUnsavedChanges = true }
            )) {
                Label("Favorite", systemImage: "star.fill")
                    .font(.subheadline.weight(.medium))
            }
            .tint(.yellow)
            
            // Last Worn
            HStack {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                Text("Last Worn")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let lastWorn = garment.lastWorn {
                    Text(lastWorn.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline)
                        .foregroundStyle(DS.Text.secondary)
                    
                    Button("Reset") {
                        garment.lastWorn = nil
                        hasUnsavedChanges = true
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Text("Never")
                        .font(.subheadline)
                        .foregroundStyle(DS.Text.tertiary)
                }
            }
            
            // Times Worn
            HStack {
                Image(systemName: "number")
                    .foregroundStyle(.secondary)
                Text("Times Worn")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(garment.timesWorn)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var advancedSection: some View {
        DisclosureGroup(String(localized: "garment_more_options"), isExpanded: $showAdvancedOptions) {
            VStack(alignment: .leading, spacing: 16) {
                SingleTagPicker(
                    title: String(localized: "garment_pattern"),
                    allTags: PatternTag.allCases,
                    selectedTag: Binding(
                        get: { garment.patternTag },
                        set: { garment.patternTag = $0; hasUnsavedChanges = true }
                    ),
                    titleForTag: { $0.title }
                )
                
                // Notes
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes")
                        .font(.caption.bold())
                        .foregroundStyle(DS.Text.secondary)
                        .textCase(.uppercase)
                    
                    TextField("Add notes...", text: Binding(
                        get: { garment.notes ?? "" },
                        set: { garment.notes = $0.isEmpty ? nil : $0; hasUnsavedChanges = true }
                    ), axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.plain)
                    .dsFieldStyle()
                    .foregroundStyle(DS.Text.primary)
                }
            }
            .padding(.top, 12)
        }
    }

    private var actionsSection: some View {
        VStack(spacing: 12) {
            Button {
                feedback.impactOccurred(intensity: 1.0)
                saveChanges()
            } label: {
                Text(String(localized: "action_save_changes"))
                    .font(.headline)
                    .foregroundStyle(DS.Text.inverted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(DS.Surface.inverted)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Button {
                if let url = URL(string: "wearit://planner") {
                    openURL(url)
                }
            } label: {
                Label("Open Today's Plan", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            
            Button(role: .destructive) {
                feedback.impactOccurred(intensity: 0.5)
                showDeleteAlert = true
            } label: {
                Text(String(localized: "action_delete_item"))
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    // MARK: - Actions

    private func applyImageResult(_ result: ImageEditingResult) {
        garment.imagePath = result.imagePath
        garment.thumbnailPath = result.thumbnailPath
        garment.imageData = result.jpegData

        if let path = garment.imagePath {
            CloudKitImageSyncService.shared.enqueueUpload(garmentID: garment.id, imagePath: path)
        }
        
        if let originalPath = result.originalPath {
            garment.originalImagePath = originalPath
        }
        
        hasUnsavedChanges = true
        saveChanges()
    }

    private func addGalleryImage(_ result: ImageEditingResult) {
        guard let path = result.imagePath else { return }
        var paths = garment.additionalImagePaths ?? []
        paths.append(path)
        garment.additionalImagePaths = paths
        hasUnsavedChanges = true
        saveChanges(dismissAfter: false)
    }

    private func removeGalleryImage(at index: Int) {
        guard var paths = garment.additionalImagePaths, paths.indices.contains(index) else { return }
        let removedPath = paths.remove(at: index)
        garment.additionalImagePaths = paths.isEmpty ? nil : paths
        ImageStore.delete(path: removedPath)
        hasUnsavedChanges = true
        saveChanges(dismissAfter: false)
    }
    
    private func clearImage() {
        garment.imagePath = nil
        garment.thumbnailPath = nil
        garment.imageData = nil
        hasUnsavedChanges = true
    }

    private func saveChanges(dismissAfter: Bool = true) {
        // Validate
        // Colors are optional for legacy garments
        // Don't block save if no colors selected
        
        do {
            try context.save()
            if let trimmed = garment.brand, !trimmed.isEmpty {
                BrandStore.upsert(name: trimmed, context: context)
            }
            hasUnsavedChanges = false
            NotificationCenter.default.post(name: .garmentUpdated, object: garment.id)
            if dismissAfter {
                dismiss()
            }
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }

    private func deleteItem() {
        if let path = garment.imagePath {
            ImageStore.delete(path: path)
        }
        if let originalPath = garment.originalImagePath {
            ImageStore.delete(path: originalPath)
        }
        if let additional = garment.additionalImagePaths {
            for path in additional {
                ImageStore.delete(path: path)
            }
        }
        
        context.delete(garment)
        
        do {
            try context.save()
            NotificationCenter.default.post(name: .garmentDeleted, object: garment.id)
            dismiss()
        } catch {
            errorMessage = "Failed to delete: \(error.localizedDescription)"
        }
    }
}

private struct GalleryViewer: View {
    let imagePaths: [String]
    let startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int

    init(imagePaths: [String], startIndex: Int) {
        self.imagePaths = imagePaths
        self.startIndex = startIndex
        _selection = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(Array(imagePaths.enumerated()), id: \.offset) { index, path in
                    if let image = ImageStore.loadImage(path: path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .tag(index)
                            .padding()
                    } else {
                        Color.black
                            .tag(index)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding()
            }
        }
    }
}

private extension View {
    func sectionSurface(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(DS.Surface.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(DS.Border.subtle, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
