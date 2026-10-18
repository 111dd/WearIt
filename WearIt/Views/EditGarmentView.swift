import SwiftUI
import SwiftData
import UIKit

/// Item editor aligned with the redesigned AddGarment flow.
struct EditGarmentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    @Bindable var garment: Garment
    let initialPhotoTool: GarmentPhotoTool?
    @State private var photoTool: GarmentPhotoTool?
    @State private var didOpenInitialPhotoTool = false
    @State private var photoAdvice: GarmentPhotoFraming.Advice?
    @Query(sort: \Brand.name, order: .forward) private var brands: [Brand]

    @State private var isEditingTitle = false
    @State private var isSuggestingName = false
    @State private var showAdvancedOptions = false
    @State private var showDetails = false
    @State private var showDeleteAlert = false
    @State private var errorMessage: String?
    @State private var hasUnsavedChanges = false
    /// Looks this item was worn in, per situation (from calendar-tagged wear history).
    @State private var occasionWearCounts: [GarmentOccasion: Int] = [:]
    @State private var brandText = ""
    @State private var showLabelScanner = false
    @State private var isScanningLabel = false
    @State private var labelScanMessage: String?
    @State private var gallerySelection: GarmentGallerySelection?
    @State private var isSavingPhoto = false
    @State private var photoTask: Task<Void, Never>?
    @State private var photoGeneration = UUID()
    @State private var heroImage: UIImage?
    @State private var isLoadingHero = false

    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showCropper = false
    @State private var pendingCropImage: UIImage?
    @State private var originalPickedImage: UIImage?
    @State private var pendingPhotoSourceURL: URL?
    @State private var cropMode: CropMode = .replaceMain

    private enum CropMode {
        case replaceMain
        case addGallery
    }

    private let feedback = UIImpactFeedbackGenerator(style: .medium)

    init(garment: Garment, initialPhotoTool: GarmentPhotoTool? = nil) {
        self.garment = garment
        self.initialPhotoTool = initialPhotoTool
    }

    private var categoryColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: DS.Spacing.xs), count: 3)
    }

    private var galleryImagePaths: [String] {
        garment.galleryPhotoPaths
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

    private var shouldShowFit: Bool {
        garment.category == .top || garment.category == .bottom
    }

    private var shouldShowSize: Bool {
        garment.category == .top || garment.category == .bottom || garment.category == .shoes
    }

    private var sizeOptions: [SizeOption] {
        SizeOption.options(for: garment.category)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.md) {
                heroCard
                essentialsCard
                ThermalProfileEditor(
                    profile: garment.thermalProfile,
                    warmthOverride: Binding(
                        get: { garment.thermalWarmthOverride },
                        set: { garment.thermalWarmthOverride = $0; hasUnsavedChanges = true }
                    ),
                    breathabilityOverride: Binding(
                        get: { garment.thermalBreathabilityOverride },
                        set: { garment.thermalBreathabilityOverride = $0; hasUnsavedChanges = true }
                    )
                )
                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(spacing: DS.Spacing.md) {
                        if shouldShowFit || shouldShowSize { fitSizeCard }
                        colorCard
                        brandCard
                        seasonCard
                        attributesCard
                        advancedCard
                        dangerCard
                    }
                    .padding(.top, DS.Spacing.sm)
                } label: {
                    Label("edit_details_and_options", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.sm)
            .padding(.bottom, DS.Spacing.xxl)
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .withLocalAppBackdrop()
        .navigationTitle(String(localized: "nav_edit_item"))
        .navigationBarTitleDisplayMode(.inline)
        .compactNavBar()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            stickySaveBar
        }
        .onAppear {
            brandText = garment.brand ?? ""
            BrandStore.syncFromGarments(context: context)
            loadOccasionWearCounts()
            prepareLegacyPrimaryIfNeeded()
            if !didOpenInitialPhotoTool {
                didOpenInitialPhotoTool = true
                photoTool = initialPhotoTool
            }
        }
        .task(id: "\(garment.imagePath ?? "")|\(garment.thumbnailPath ?? "")") {
            await loadHeroImage()
        }
        .onDisappear {
            // Covers are part of this editor's workflow, not an abandoned edit.
            if photoTool == nil, gallerySelection == nil, !showCropper, !showCamera, !showPhotoPicker, !showLabelScanner {
                cancelPhotoWork()
            }
        }
        .alert(String(localized: "edit_delete_title"), isPresented: $showDeleteAlert) {
            Button(String(localized: "action_cancel"), role: .cancel) {}
            Button(String(localized: "action_delete"), role: .destructive) { deleteItem() }
        } message: {
            Text(String(localized: "edit_delete_message"))
        }
        .alert(String(localized: "error_title"), isPresented: Binding(
            get: { errorMessage != nil && gallerySelection == nil && photoTool == nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(String(localized: "action_confirm"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? String(localized: "error_generic"))
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPickerWrapper { image in
                beginCrop(with: image)
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPickerWrapper { image in
                beginCrop(with: image)
            }
        }
        .sheet(isPresented: $showLabelScanner) {
            CameraPickerWrapper { image in
                handleLabelScan(image)
            }
        }
        .fullScreenCover(isPresented: $showCropper) {
            if let pendingCropImage {
                ImageCropperView(
                    image: pendingCropImage,
                    initialAspect: .portrait34,
                    onCancel: {
                        showCropper = false
                        self.pendingCropImage = nil
                    },
                    onDone: { cropped in
                        showCropper = false
                        self.pendingCropImage = nil
                        applyCroppedImage(cropped, original: originalPickedImage ?? cropped)
                    }
                )
            }
        }
        .fullScreenCover(item: $gallerySelection) { selection in
            GarmentPhotoViewer(
                garment: garment, startPath: selection.id,
                isBusy: $isSavingPhoto, errorMessage: $errorMessage,
                onMakePrimary: makePrimaryPhoto,
                onRoleChange: setPhotoRole,
                onRemove: removeGalleryImage
            )
        }
        .fullScreenCover(item: $photoTool) { tool in
            switch tool {
            case .subject:
                GarmentSubjectPicker(
                    imagePath: garment.originalImagePath ?? garment.imagePath,
                    fallbackImagePath: garment.imagePath,
                    legacyData: garment.imageData, category: garment.category
                ) { cutout, original in
                    let source = garment.imagePath.flatMap { garment.photoInfo(for: $0).sourceURL }.flatMap { URL(string: $0) }
                    persistNewPhoto(cutout, original: original, makePrimary: true, sourceURL: source)
                }
            case .findPhoto:
                GarmentPhotoSearchView(garment: garment) { image, source, asPrimary in
                    persistNewPhoto(image, original: image, makePrimary: asPrimary, sourceURL: source)
                }
            }
        }
    }

    // MARK: - Sticky save

    private var stickySaveBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.35)
            Button {
                feedback.impactOccurred(intensity: 1.0)
                saveChanges()
            } label: {
                Text(String(localized: "action_save_changes"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .dsPrimaryButton()
            .disabled(isSavingPhoto)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.sm)
            .padding(.bottom, DS.Spacing.md)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Cards

    private var heroCard: some View {
        VStack(spacing: DS.Spacing.sm) {
            GarmentPhotoCanvas(image: heroImage, placeholder: garment.category.icon)
                .overlay { if isLoadingHero { ProgressView() } }
            .contentShape(Rectangle())
            .onTapGesture {
                if let path = garment.imagePath {
                    gallerySelection = GarmentGallerySelection(id: path)
                }
            }
            .accessibilityAction(named: Text(String(localized: "garment_photo_open_hint"))) {
                if let path = garment.imagePath {
                    gallerySelection = GarmentGallerySelection(id: path)
                }
            }
            .aspectRatio(DS.AspectRatio.garmentTile, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 280)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
            )

            if !galleryImagePaths.isEmpty {
                GarmentPhotoGallery(
                    garment: garment, isBusy: isSavingPhoto,
                    onOpen: { gallerySelection = GarmentGallerySelection(id: $0) },
                    onMakePrimary: makePrimaryPhoto,
                    onRoleChange: setPhotoRole,
                    onRemove: removeGalleryImage
                )
            }
            if isSavingPhoto {
                HStack(spacing: DS.Spacing.sm) {
                    ProgressView()
                    Text(String(localized: "add_garment_preparing_photo"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: DS.Spacing.sm) {
                Button {
                    cropMode = .replaceMain
                    reopenCropperForExisting()
                } label: {
                    Label(String(localized: "add_garment_edit_photo"), systemImage: "crop")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .disabled(heroImage == nil && garment.originalImagePath == nil)

                Menu {
                    Button {
                        cropMode = .replaceMain
                        showCamera = true
                    } label: {
                        Label(String(localized: "garment_take_photo"), systemImage: "camera")
                    }
                    Button {
                        cropMode = .replaceMain
                        showPhotoPicker = true
                    } label: {
                        Label(String(localized: "garment_choose_library"), systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Label(String(localized: "garment_change_image"), systemImage: "photo")
                        .font(.caption.weight(.semibold))
                }

                Menu {
                    Button {
                        cropMode = .addGallery
                        showCamera = true
                    } label: {
                        Label(String(localized: "garment_take_photo"), systemImage: "camera")
                    }
                    Button {
                        cropMode = .addGallery
                        showPhotoPicker = true
                    } label: {
                        Label(String(localized: "garment_choose_library"), systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Label(String(localized: "garment_add_photo"), systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }

                Spacer(minLength: 0)

                if garment.imagePath != nil || garment.imageData != nil {
                    Button(role: .destructive) {
                        clearImage()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(.secondary)
            .disabled(isSavingPhoto)

            photoTools
            titleEditor
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface()
    }

    private var photoTools: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Spacing.sm) { photoToolButtons }
                VStack(alignment: .leading, spacing: DS.Spacing.sm) { photoToolButtons }
            }
            if let photoAdvice, photoAdvice.suggestsImprovement {
                Text(String(localized: photoAdvice.isLowResolution ? "photo_advice_low_resolution" : "photo_advice_isolate"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(isSavingPhoto)
    }

    @ViewBuilder private var photoToolButtons: some View {
        Button { photoTool = .subject } label: {
            Label(String(localized: "photo_tool_select_subject"), systemImage: "person.crop.rectangle")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .disabled(garment.imagePath == nil && garment.imageData == nil)
        Button { photoTool = .findPhoto } label: {
            Label(String(localized: "photo_tool_find_photo"), systemImage: "photo.badge.magnifyingglass")
                .font(.caption.weight(.semibold))
        }.buttonStyle(.bordered)
    }

    private var titleEditor: some View {
        VStack(spacing: DS.Spacing.xs) {
            if isEditingTitle {
                TextField(String(localized: "garment_edit_title"), text: Binding(
                    get: { garment.userTitleOverride ?? garment.autoGeneratedTitle },
                    set: {
                        garment.userTitleOverride = $0
                        hasUnsavedChanges = true
                    }
                ))
                .textFieldStyle(.plain)
                .dsFieldStyle()
                .multilineTextAlignment(.center)
                .onSubmit { isEditingTitle = false }

                Button(String(localized: "add_garment_use_auto_title")) {
                    garment.userTitleOverride = nil
                    isEditingTitle = false
                    hasUnsavedChanges = true
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text(garment.displayTitle)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: DS.Spacing.md) {
                    Button {
                        isEditingTitle = true
                    } label: {
                        Label(String(localized: "add_garment_edit_title"), systemImage: "pencil")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)

                    if LookExplanationAvailability.isSupported {
                        Button {
                            suggestNameWithAI()
                        } label: {
                            if isSuggestingName {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Label(String(localized: "garment_ai_name_suggest"), systemImage: "sparkles")
                                    .font(.caption)
                            }
                        }
                        .foregroundStyle(Color.accentColor)
                        .disabled(isSuggestingName)
                        .accessibilityLabel(String(localized: "garment_ai_name_suggest"))
                    }
                }
            }
        }
        .padding(.top, DS.Spacing.xxs)
    }

    private func suggestNameWithAI() {
        guard #available(iOS 26.0, *) else { return }
        guard !isSuggestingName else { return }
        let request = GarmentNameRequest(
            category: garment.category.rawValue,
            itemType: garment.itemType?.rawValue,
            colors: garment.safeColorTags.prefix(2).map(\.rawValue),
            material: garment.materialTags?.first?.rawValue,
            pattern: garment.patternTag?.rawValue,
            fit: garment.fitTag?.rawValue,
            brand: garment.brand,
            languageCode: Locale.current.language.languageCode?.identifier ?? "en"
        )
        isSuggestingName = true
        Task {
            let name = await LookExplanationService.shared.suggestGarmentName(for: request)
            isSuggestingName = false
            if let name {
                garment.userTitleOverride = name
                hasUnsavedChanges = true
                DS.haptic(0.4)
            }
        }
    }

    private var essentialsCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "garment_category"), icon: "square.grid.2x2")

            LazyVGrid(columns: categoryColumns, spacing: DS.Spacing.xs) {
                ForEach(Category.allCases) { cat in
                    Button {
                        feedback.impactOccurred(intensity: 0.5)
                        selectCategory(cat)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: cat.icon)
                                .font(.title3)
                            Text(cat.title)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Spacing.sm)
                        .foregroundStyle(garment.category == cat ? Color.accentColor : .primary)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                .fill(garment.category == cat ? Color.accentColor.opacity(0.14) : Color(.secondarySystemBackground).opacity(0.35))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                .strokeBorder(garment.category == cat ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(String(localized: "garment_item_type"))
                .font(.subheadline.weight(.semibold))
                .padding(.top, DS.Spacing.xxs)
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
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface()
    }

    private var fitSizeCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "fit_size_title"), icon: "ruler")
            if shouldShowFit {
                SingleTagPicker(
                    title: String(localized: "fit_label"),
                    allTags: FitTag.allCases,
                    selectedTag: Binding(
                        get: { garment.fitTag },
                        set: { garment.fitTag = $0; hasUnsavedChanges = true }
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
                        set: { garment.sizeOption = $0; hasUnsavedChanges = true }
                    ),
                    titleForTag: { $0.title }
                )
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface()
    }

    private var colorCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "paintpalette")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Text.secondary)
                Text(String(localized: "garment_colors"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Text.secondary)
                Spacer(minLength: 0)
                Text(
                    garment.safeColorTags.isEmpty
                        ? String(localized: "garment_colors_recommended")
                        : String(format: NSLocalizedString("add_garment_colors_selected_format", comment: ""), garment.safeColorTags.count)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface()
    }

    private var brandCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                DSSectionHeader(String(localized: "garment_brand"), icon: "tag")
                Spacer(minLength: 0)
                Button {
                    DS.haptic(0.4)
                    showLabelScanner = true
                } label: {
                    if isScanningLabel {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Label(String(localized: "label_scan_button"), systemImage: "text.viewfinder")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(isScanningLabel)
            }

            TextField(String(localized: "garment_brand_placeholder"), text: $brandText)
                .textFieldStyle(.plain)
                .dsFieldStyle()
                .onChange(of: brandText) { _, newValue in
                    garment.brand = newValue.isEmpty ? nil : newValue
                    hasUnsavedChanges = true
                }

            if let labelScanMessage {
                Label(labelScanMessage, systemImage: "text.viewfinder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !brandSuggestions.isEmpty || shouldShowAddBrand {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(brandSuggestions, id: \.name) { suggestion in
                        Button {
                            brandText = suggestion.name
                            garment.brand = suggestion.name
                            hasUnsavedChanges = true
                        } label: {
                            Text(suggestion.name).font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    if shouldShowAddBrand {
                        Text(String(format: NSLocalizedString("brand_add_suggestion", comment: ""), brandText))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface()
    }

    private func handleLabelScan(_ image: UIImage) {
        isScanningLabel = true
        labelScanMessage = nil
        Task {
            let result = await LabelScanService.scan(image: image)
            isScanningLabel = false

            var found: [String] = []
            if let brand = result.brand, brandText.isEmpty {
                brandText = brand
                garment.brand = brand
                found.append(brand)
            }
            if let size = result.size, garment.sizeOption == nil,
               SizeOption.options(for: garment.category).contains(size) {
                garment.sizeOption = size
                found.append(size.title)
            }
            if !result.materials.isEmpty, (garment.materialTags ?? []).isEmpty {
                garment.materialTags = result.materials
                garment.markUserEdited(ItemTypeDefaults.FieldKey.materialTags)
                found.append(result.materials.map(\.title).joined(separator: ", "))
            }

            if found.isEmpty {
                labelScanMessage = String(localized: "label_scan_nothing")
            } else {
                hasUnsavedChanges = true
                labelScanMessage = String(
                    format: NSLocalizedString("label_scan_found_format", comment: ""),
                    found.joined(separator: " · ")
                )
                DS.haptic(0.5)
            }
        }
    }

    private var seasonCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "garment_season"), icon: "leaf")
            SeasonSelector(selectedSeason: Binding(
                get: { garment.seasonSuitability },
                set: {
                    garment.seasonSuitability = $0
                    garment.markUserEdited(ItemTypeDefaults.FieldKey.season)
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
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface()
    }

    /// "Right for": everyday, work, evening out, formal, workouts, outdoors, home.
    /// Starts from what the item implies and what it was worn for; a tap sets the
    /// user's own answer (work and workouts also feed reminders and work days).
    private var occasionFitsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                Label(String(localized: "fits_title"), systemImage: "checkmark.seal")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if !garment.occasionFits.isEmpty || !garment.occasionNotFits.isEmpty {
                    Button(String(localized: "fits_reset")) {
                        for occasion in GarmentOccasion.allCases {
                            garment.setOccasionAnswer(nil, for: occasion)
                        }
                        hasUnsavedChanges = true
                    }
                    .font(.caption.weight(.medium))
                }
            }
            Text(String(localized: "fits_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: DS.Spacing.xs)], spacing: DS.Spacing.xs) {
                ForEach(GarmentOccasion.allCases) { occasion in
                    occasionChip(occasion)
                }
            }
        }
    }

    private func occasionChip(_ occasion: GarmentOccasion) -> some View {
        let fits = GarmentOccasionProfile.fits(garment, occasion, wornFor: occasionWearCounts[occasion] ?? 0)
        return Button {
            DS.haptic(0.3)
            garment.setOccasionAnswer(!fits, for: occasion)
            hasUnsavedChanges = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: fits ? "checkmark" : occasion.icon)
                    .font(.caption.weight(.semibold))
                Text(occasion.title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .padding(.horizontal, 6)
            .foregroundStyle(fits ? Color.white : Color.primary)
            .background(
                Capsule().fill(fits ? Color.accentColor : Color.secondary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(fits ? .isSelected : [])
    }

    private func loadOccasionWearCounts() {
        let descriptor = FetchDescriptor<WearEvent>(
            predicate: #Predicate { event in event.occasionRaw != nil }
        )
        let events = (try? context.fetch(descriptor)) ?? []
        let id = garment.id
        occasionWearCounts = GarmentOccasionProfile.wearCounts(
            from: events.filter { $0.garmentIDs.contains(id) }
        )[id] ?? [:]
    }

    private var attributesCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            DSSectionHeader(String(localized: "garment_attributes"), icon: "slider.horizontal.3")

            attributeRow(icon: "briefcase", title: String(localized: "garment_formality"), value: garment.formality, tint: .accentColor) {
                Stepper(String(localized: "garment_formality"), value: Binding(
                    get: { garment.formality },
                    set: {
                        garment.formality = $0
                        garment.markUserEdited(ItemTypeDefaults.FieldKey.formality)
                        hasUnsavedChanges = true
                    }
                ), in: 1...5)
                .labelsHidden()
                .controlSize(.small)
            }

            Toggle(isOn: Binding(
                get: { garment.isFavorite },
                set: { garment.isFavorite = $0; hasUnsavedChanges = true }
            )) {
                Label(String(localized: "edit_favorite"), systemImage: "star.fill")
                    .font(.subheadline.weight(.medium))
            }
            .tint(.yellow)

            occasionFitsSection

            if garment.category == .top {
                HStack {
                    Label(String(localized: "garment_sleeve"), systemImage: "tshirt")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Picker(String(localized: "garment_sleeve"), selection: Binding<SleeveLength?>(
                        get: { garment.sleeveLength },
                        set: { garment.sleeveLength = $0; hasUnsavedChanges = true }
                    )) {
                        ForEach(SleeveLength.allCases) { sleeve in
                            Text(sleeve.title).tag(Optional(sleeve))
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            HStack {
                Image(systemName: "calendar").foregroundStyle(.secondary)
                Text(String(localized: "edit_last_worn")).font(.subheadline.weight(.medium))
                Spacer()
                if let lastWorn = garment.lastWorn {
                    Text(lastWorn.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "crop_reset")) {
                        garment.lastWorn = nil
                        hasUnsavedChanges = true
                    }
                    .font(.caption)
                } else {
                    Text(String(localized: "edit_never_worn"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Image(systemName: "number").foregroundStyle(.secondary)
                Text(String(localized: "edit_times_worn")).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(garment.timesWorn)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface()
    }

    private var advancedCard: some View {
        DisclosureGroup(String(localized: "garment_more_options"), isExpanded: $showAdvancedOptions) {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                SingleTagPicker(
                    title: String(localized: "garment_pattern"),
                    allTags: PatternTag.allCases,
                    selectedTag: Binding(
                        get: { garment.patternTag },
                        set: { garment.patternTag = $0; hasUnsavedChanges = true }
                    ),
                    titleForTag: { $0.title }
                )

                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text(String(localized: "edit_notes"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "edit_notes_placeholder"), text: Binding(
                        get: { garment.notes ?? "" },
                        set: { garment.notes = $0.isEmpty ? nil : $0; hasUnsavedChanges = true }
                    ), axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.plain)
                    .dsFieldStyle()
                }
            }
            .padding(.top, DS.Spacing.sm)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface()
    }

    private var dangerCard: some View {
        VStack(spacing: DS.Spacing.sm) {
            Button {
                if let url = URL(string: "wearit://planner") {
                    openURL(url)
                }
            } label: {
                Label(String(localized: "edit_open_planner"), systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .dsSecondaryButton()

            Button(role: .destructive) {
                feedback.impactOccurred(intensity: 0.5)
                showDeleteAlert = true
            } label: {
                Text(String(localized: "action_delete_item"))
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity)
        .contentSurface()
    }

    private func attributeRow<Trailing: View>(
        icon: String,
        title: String,
        value: Int,
        tint: Color,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { i in
                    Circle()
                        .fill(i <= value ? tint : Color.secondary.opacity(0.2))
                        .frame(width: 8, height: 8)
                }
            }
            trailing()
        }
    }

    // MARK: - Image helpers

    private func loadHeroImage() async {
        let path = garment.imagePath
        let data = garment.imageData
        heroImage = nil
        isLoadingHero = true
        let result: (UIImage?, GarmentPhotoFraming.Advice?) = await Task.detached(priority: .utility) {
            let image = ImageStore.loadGarmentPreview(imagePath: path, legacyData: data, maxPixelSize: 900)
            return (image, image.map { GarmentPhotoFraming.advice(for: $0) })
        }.value
        guard !Task.isCancelled else { return }
        heroImage = result.0
        photoAdvice = result.1
        isLoadingHero = false
    }

    private func selectCategory(_ cat: Category) {
        let previous = garment.category
        garment.category = cat
        hasUnsavedChanges = true
        if previous != cat, let current = garment.itemType, !cat.itemTypes.contains(current) {
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
    }

    private func beginCrop(with image: UIImage) {
        pendingPhotoSourceURL = nil
        originalPickedImage = image
        pendingCropImage = image
        showCropper = true
    }

    private func reopenCropperForExisting() {
        guard !isSavingPhoto else { return }
        let generation = UUID()
        photoGeneration = generation
        isSavingPhoto = true
        let path = garment.originalImagePath ?? garment.imagePath
        let legacyData = garment.imageData
        let sourceURL = garment.imagePath.flatMap { garment.photoInfo(for: $0).sourceURL }.flatMap { URL(string: $0) }
        photoTask = Task { @MainActor in
            defer { finishPhotoWork(generation: generation) }
            let loaded: UIImage? = await Task.detached(priority: .utility) {
                if let path { return ImageStore.loadThumbnail(path: path, maxPixelSize: 2400) }
                if let legacyData { return ImageStore.downsample(data: legacyData, maxPixelSize: 2400) }
                return nil
            }.value
            guard !Task.isCancelled, photoGeneration == generation else { return }
            guard let loaded else {
                errorMessage = String(localized: "edit_image_save_failed")
                return
            }
            cropMode = .replaceMain
            pendingPhotoSourceURL = sourceURL
            originalPickedImage = loaded
            pendingCropImage = loaded
            showCropper = true
        }
    }

    private func applyCroppedImage(_ cropped: UIImage, original: UIImage) {
        switch cropMode {
        case .replaceMain:
            persistNewPhoto(cropped, original: original, makePrimary: true, sourceURL: pendingPhotoSourceURL)
        case .addGallery:
            persistNewPhoto(cropped, original: original, makePrimary: false)
        }
        pendingPhotoSourceURL = nil
    }

    /// Snapshot only photo fields so a failed media save cannot discard unrelated edits.
    private struct PhotoState {
        let image: String?
        let thumbnail: String?
        let original: String?
        let additional: [String]?
        let metadata: String?
        let legacyData: Data?
        let files: Set<String>

        init(_ garment: Garment) {
            image = garment.imagePath
            thumbnail = garment.thumbnailPath
            original = garment.originalImagePath
            additional = garment.additionalImagePaths
            metadata = garment.photoMetadataRaw
            legacyData = garment.imageData
            files = garment.allPhotoFilePaths
        }

        func restore(on garment: Garment) {
            garment.imagePath = image
            garment.thumbnailPath = thumbnail
            garment.originalImagePath = original
            garment.additionalImagePaths = additional
            garment.photoMetadataRaw = metadata
            garment.imageData = legacyData
        }
    }

    private func prepareLegacyPrimaryIfNeeded() {
        guard garment.imagePath == nil, let data = garment.imageData, !isSavingPhoto else { return }
        let generation = UUID()
        photoGeneration = generation
        isSavingPhoto = true
        photoTask = Task { @MainActor in
            defer { finishPhotoWork(generation: generation) }
            do {
                let files = try await GarmentImagePersistence.shared.persistLegacy(data)
                guard !Task.isCancelled, photoGeneration == generation, garment.imagePath == nil else {
                    await GarmentImagePersistence.shared.remove(paths: files.paths)
                    return
                }
                let previous = PhotoState(garment)
                garment.imagePath = files.image
                garment.originalImagePath = files.original
                garment.thumbnailPath = files.thumbnail
                garment.imageData = nil
                garment.setPhotoInfo(
                    GarmentPhotoMetadata(originalPath: files.original, thumbnailPath: files.thumbnail), for: files.image
                )
                if !savePhotoChanges(previous) {
                    await GarmentImagePersistence.shared.remove(paths: files.paths)
                }
            } catch {
                guard !Task.isCancelled, photoGeneration == generation else { return }
                errorMessage = String(localized: "edit_image_save_failed")
            }
        }
    }

    private func persistNewPhoto(_ display: UIImage, original: UIImage, makePrimary: Bool, sourceURL: URL? = nil) {
        guard !isSavingPhoto else { return }
        let generation = UUID()
        photoGeneration = generation
        isSavingPhoto = true
        photoTask = Task { @MainActor in
            defer { finishPhotoWork(generation: generation) }
            do {
                let files = try await GarmentImagePersistence.shared.persist(display: display, original: original)
                guard !Task.isCancelled, photoGeneration == generation else {
                    await GarmentImagePersistence.shared.remove(paths: files.paths)
                    return
                }
                let previous = PhotoState(garment)
                let role = makePrimary ? garment.imagePath.map { garment.photoInfo(for: $0).role } ?? .other : .other
                garment.rememberPrimaryPhoto()
                var additional = garment.additionalImagePaths ?? []
                if makePrimary || garment.imagePath == nil {
                    // Keep the previous cover in the gallery, including its original crop source.
                    if let old = garment.imagePath, !additional.contains(old) { additional.insert(old, at: 0) }
                    garment.imagePath = files.image
                    garment.thumbnailPath = files.thumbnail
                    garment.originalImagePath = files.original
                    garment.imageData = nil
                } else {
                    additional.append(files.image)
                }
                garment.additionalImagePaths = additional.isEmpty ? nil : additional
                garment.setPhotoInfo(
                    GarmentPhotoMetadata(role: role, originalPath: files.original, thumbnailPath: files.thumbnail,
                                         sourceURL: sourceURL?.absoluteString),
                    for: files.image
                )
                if !savePhotoChanges(previous) {
                    await GarmentImagePersistence.shared.remove(paths: files.paths)
                }
            } catch {
                guard !Task.isCancelled, photoGeneration == generation else { return }
                errorMessage = String(localized: "edit_image_save_failed")
            }
        }
    }

    private func makePrimaryPhoto(_ path: String) {
        guard !isSavingPhoto, path != garment.imagePath, galleryImagePaths.contains(path) else { return }
        let generation = UUID()
        photoGeneration = generation
        isSavingPhoto = true
        photoTask = Task { @MainActor in
            defer { finishPhotoWork(generation: generation) }
            do {
                let thumbnail = try await GarmentImagePersistence.shared.prepareThumbnail(for: path)
                guard !Task.isCancelled, photoGeneration == generation, galleryImagePaths.contains(path) else {
                    await GarmentImagePersistence.shared.remove(paths: [thumbnail])
                    return
                }
                let previous = PhotoState(garment)
                garment.rememberPrimaryPhoto()
                let info = garment.photoInfo(for: path)
                let additional = galleryImagePaths.filter { $0 != path }
                garment.imagePath = path
                garment.thumbnailPath = thumbnail
                garment.originalImagePath = info.originalPath ?? path
                garment.imageData = nil
                garment.additionalImagePaths = additional.isEmpty ? nil : additional
                garment.setPhotoInfo(
                    GarmentPhotoMetadata(role: info.role, originalPath: info.originalPath, thumbnailPath: thumbnail,
                                         sourceURL: info.sourceURL), for: path
                )
                if !savePhotoChanges(previous) {
                    await GarmentImagePersistence.shared.remove(paths: [thumbnail])
                }
            } catch {
                guard !Task.isCancelled, photoGeneration == generation else { return }
                errorMessage = String(localized: "edit_image_save_failed")
            }
        }
    }

    private func setPhotoRole(_ path: String, role: GarmentPhotoRole) {
        guard !isSavingPhoto, galleryImagePaths.contains(path) else { return }
        let previous = PhotoState(garment)
        var info = garment.photoInfo(for: path)
        info.role = role
        garment.setPhotoInfo(info, for: path)
        _ = savePhotoChanges(previous)
    }

    private func removeGalleryImage(_ path: String) {
        guard !isSavingPhoto, galleryImagePaths.contains(path) else { return }
        let remaining = galleryImagePaths.filter { $0 != path }
        guard path == garment.imagePath, let replacement = remaining.first else {
            applyPhotoRemoval(path, replacement: nil, thumbnail: nil)
            return
        }
        let generation = UUID()
        photoGeneration = generation
        isSavingPhoto = true
        photoTask = Task { @MainActor in
            defer { finishPhotoWork(generation: generation) }
            do {
                let thumbnail = try await GarmentImagePersistence.shared.prepareThumbnail(for: replacement)
                guard !Task.isCancelled, photoGeneration == generation,
                      garment.imagePath == path, galleryImagePaths.contains(replacement) else {
                    await GarmentImagePersistence.shared.remove(paths: [thumbnail])
                    return
                }
                if !applyPhotoRemoval(path, replacement: replacement, thumbnail: thumbnail) {
                    await GarmentImagePersistence.shared.remove(paths: [thumbnail])
                }
            } catch {
                guard !Task.isCancelled, photoGeneration == generation else { return }
                errorMessage = String(localized: "edit_image_save_failed")
            }
        }
    }

    @discardableResult
    private func applyPhotoRemoval(_ path: String, replacement: String?, thumbnail: String?) -> Bool {
        let previous = PhotoState(garment)
        let replacementInfo = replacement.map { garment.photoInfo(for: $0) }
        let primary = path == garment.imagePath ? replacement : garment.imagePath
        let additional = galleryImagePaths.filter { $0 != path && $0 != primary }
        garment.additionalImagePaths = additional.isEmpty ? nil : additional
        if path == garment.imagePath {
            garment.imagePath = replacement
            garment.originalImagePath = replacementInfo?.originalPath ?? replacement
            garment.thumbnailPath = thumbnail
            garment.imageData = nil
        }
        var metadata = garment.photoMetadata
        metadata.removeValue(forKey: path)
        if let replacement, var info = replacementInfo {
            info.thumbnailPath = thumbnail
            metadata[replacement] = info
        }
        garment.photoMetadata = metadata
        return savePhotoChanges(previous)
    }

    @discardableResult
    private func savePhotoChanges(_ previous: PhotoState) -> Bool {
        hasUnsavedChanges = true
        guard saveChanges(dismissAfter: false, notifyUpdate: false) else {
            previous.restore(on: garment)
            return false
        }
        if previous.image != garment.imagePath {
            ImageStore.evictStoredThumbnail(cacheKey: garment.id.uuidString)
            CloudKitImageSyncService.shared.enqueueUpload(garmentID: garment.id, imagePath: garment.imagePath)
            WidgetSnapshotService.refresh(context: context)
        }
        NotificationCenter.default.post(name: .garmentUpdated, object: garment.id)
        let unused = Array(previous.files.subtracting(garment.allPhotoFilePaths))
        if !unused.isEmpty {
            Task { await GarmentImagePersistence.shared.remove(paths: unused) }
        }
        return true
    }

    private func clearImage() {
        if let path = garment.imagePath {
            removeGalleryImage(path)
        } else {
            let previous = PhotoState(garment)
            garment.imageData = nil
            garment.originalImagePath = nil
            garment.thumbnailPath = nil
            _ = savePhotoChanges(previous)
            heroImage = nil
        }
    }

    private func finishPhotoWork(generation: UUID) {
        guard photoGeneration == generation else { return }
        isSavingPhoto = false
        photoTask = nil
    }

    private func cancelPhotoWork() {
        photoTask?.cancel()
        photoTask = nil
        photoGeneration = UUID()
        isSavingPhoto = false
    }

    @discardableResult
    private func saveChanges(dismissAfter: Bool = true, notifyUpdate: Bool = true) -> Bool {
        do {
            try context.save()
            if let trimmed = garment.brand, !trimmed.isEmpty {
                BrandStore.upsert(name: trimmed, context: context)
            }
            hasUnsavedChanges = false
            if notifyUpdate {
                NotificationCenter.default.post(name: .garmentUpdated, object: garment.id)
            }
            if dismissAfter {
                dismiss()
            }
            return true
        } catch {
            errorMessage = String(
                format: NSLocalizedString("add_garment_save_failed_format", comment: ""),
                error.localizedDescription
            )
            return false
        }
    }

    private func deleteItem() {
        cancelPhotoWork()
        let photoPaths = Array(garment.allPhotoFilePaths)
        context.delete(garment)
        do {
            try context.save()
            Task { await GarmentImagePersistence.shared.remove(paths: photoPaths) }
            NotificationCenter.default.post(name: .garmentDeleted, object: garment.id)
            dismiss()
        } catch {
            errorMessage = String(
                format: NSLocalizedString("add_garment_save_failed_format", comment: ""),
                error.localizedDescription
            )
        }
    }
}
