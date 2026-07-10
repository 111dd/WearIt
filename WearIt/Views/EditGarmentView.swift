import SwiftUI
import SwiftData
import UIKit

/// Item editor aligned with the redesigned AddGarment flow.
struct EditGarmentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    @Bindable var garment: Garment
    @Query(sort: \Brand.name, order: .forward) private var brands: [Brand]

    @State private var isEditingTitle = false
    @State private var showAdvancedOptions = false
    @State private var showDeleteAlert = false
    @State private var errorMessage: String?
    @State private var hasUnsavedChanges = false
    @State private var brandText = ""
    @State private var showGalleryViewer = false
    @State private var galleryStartIndex = 0
    @State private var heroImage: UIImage?
    @State private var isLoadingHero = false

    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showCropper = false
    @State private var pendingCropImage: UIImage?
    @State private var originalPickedImage: UIImage?
    @State private var cropMode: CropMode = .replaceMain

    private enum CropMode {
        case replaceMain
        case addGallery
    }

    private let feedback = UIImpactFeedbackGenerator(style: .medium)

    private var categoryColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: DS.Spacing.xs), count: 3)
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
                if shouldShowFit || shouldShowSize {
                    fitSizeCard
                }
                colorCard
                brandCard
                seasonCard
                attributesCard
                advancedCard
                dangerCard
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
        .minimalCollapsingNavBar()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            stickySaveBar
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "action_save")) {
                    feedback.impactOccurred()
                    saveChanges()
                }
            }
        }
        .onAppear {
            brandText = garment.brand ?? ""
            BrandStore.syncFromGarments(context: context)
            loadHeroImage()
        }
        .onChange(of: garment.imagePath) { _, _ in
            loadHeroImage()
        }
        .alert(String(localized: "edit_delete_title"), isPresented: $showDeleteAlert) {
            Button(String(localized: "action_cancel"), role: .cancel) {}
            Button(String(localized: "action_delete"), role: .destructive) { deleteItem() }
        } message: {
            Text(String(localized: "edit_delete_message"))
        }
        .alert(String(localized: "error_title"), isPresented: Binding(
            get: { errorMessage != nil },
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
        .fullScreenCover(isPresented: $showGalleryViewer) {
            GalleryViewer(imagePaths: galleryImagePaths, startIndex: galleryStartIndex)
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
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.sm)
            .padding(.bottom, DS.Spacing.md)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Cards

    private var heroCard: some View {
        VStack(spacing: DS.Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(Color(.secondarySystemBackground).opacity(0.45))

                if let heroImage {
                    Image(uiImage: heroImage)
                        .resizable()
                        .scaledToFill()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipped()
                } else if isLoadingHero {
                    ProgressView()
                } else {
                    VStack(spacing: DS.Spacing.xs) {
                        Image(systemName: garment.category.icon)
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text(String(localized: "garment_no_image"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(Array(galleryImagePaths.enumerated()), id: \.offset) { index, path in
                            AsyncGalleryThumb(path: path)
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

            titleEditor
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
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

                Button {
                    isEditingTitle = true
                } label: {
                    Label(String(localized: "add_garment_edit_title"), systemImage: "pencil")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.top, DS.Spacing.xxs)
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
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
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
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
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
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
    }

    private var brandCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "garment_brand"), icon: "tag")
            TextField(String(localized: "garment_brand_placeholder"), text: $brandText)
                .textFieldStyle(.plain)
                .dsFieldStyle()
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
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
    }

    private var seasonCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "garment_season"), icon: "leaf")
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
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
    }

    private var attributesCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            DSSectionHeader(String(localized: "garment_attributes"), icon: "slider.horizontal.3")

            attributeRow(icon: "thermometer.medium", title: String(localized: "garment_warmth"), value: garment.warmth, tint: .orange) {
                Stepper("", value: Binding(
                    get: { garment.warmth },
                    set: { garment.warmth = $0; hasUnsavedChanges = true }
                ), in: 1...5)
                .labelsHidden()
                .controlSize(.small)
            }

            attributeRow(icon: "briefcase", title: String(localized: "garment_formality"), value: garment.formality, tint: .accentColor) {
                Stepper("", value: Binding(
                    get: { garment.formality },
                    set: { garment.formality = $0; hasUnsavedChanges = true }
                ), in: 1...5)
                .labelsHidden()
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack {
                    Image(systemName: "heart.fill").foregroundStyle(.pink)
                    Text(String(localized: "garment_love")).font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(garment.loveScore)%")
                        .font(.caption.bold())
                        .foregroundStyle(.pink)
                }
                Slider(value: Binding(
                    get: { Double(garment.loveScore) },
                    set: { garment.loveScore = Int($0); hasUnsavedChanges = true }
                ), in: 0...100)
                .tint(.pink)
            }

            Toggle(isOn: Binding(
                get: { garment.isFavorite },
                set: { garment.isFavorite = $0; hasUnsavedChanges = true }
            )) {
                Label(String(localized: "edit_favorite"), systemImage: "star.fill")
                    .font(.subheadline.weight(.medium))
            }
            .tint(.yellow)

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
                        .foregroundStyle(.tertiary)
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
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
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
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
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
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
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

    private func loadHeroImage() {
        let path = garment.imagePath
        let data = garment.imageData
        isLoadingHero = true
        Task(priority: .userInitiated) {
            let loaded: UIImage? = await Task.detached(priority: .utility) {
                if let path, let img = ImageStore.loadThumbnail(path: path, maxPixelSize: 900)
                    ?? ImageStore.loadImage(path: path) {
                    return img
                }
                if let data { return UIImage(data: data) }
                return nil
            }.value
            await MainActor.run {
                heroImage = loaded
                isLoadingHero = false
            }
        }
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
        originalPickedImage = image
        pendingCropImage = image
        showCropper = true
    }

    private func reopenCropperForExisting() {
        Task {
            let path = garment.originalImagePath ?? garment.imagePath
            let loaded: UIImage? = await Task.detached(priority: .utility) {
                if let path { return ImageStore.loadImage(path: path) }
                return nil
            }.value
            await MainActor.run {
                guard let loaded else { return }
                cropMode = .replaceMain
                originalPickedImage = loaded
                pendingCropImage = loaded
                showCropper = true
            }
        }
    }

    private func applyCroppedImage(_ cropped: UIImage, original: UIImage) {
        switch cropMode {
        case .replaceMain:
            persistMainImage(cropped, original: original)
        case .addGallery:
            persistGalleryImage(cropped)
        }
    }

    private func persistMainImage(_ display: UIImage, original: UIImage) {
        guard let jpeg = display.jpegData(compressionQuality: 0.9),
              let imagePath = try? ImageStore.save(data: jpeg, preferredExt: "jpg") else {
            errorMessage = String(localized: "edit_image_save_failed")
            return
        }
        let thumb = ImageStore.generateAndSaveThumbnail(
            for: imagePath,
            maxPixelSize: ImageStore.thumbnailMaxPixelSize
        )
        var originalPath: String?
        if let data = original.jpegData(compressionQuality: 0.85) {
            originalPath = try? ImageStore.save(data: data, preferredExt: "jpg")
        }

        garment.imagePath = imagePath
        garment.thumbnailPath = thumb
        garment.imageData = nil
        if let originalPath {
            garment.originalImagePath = originalPath
        }
        heroImage = display
        CloudKitImageSyncService.shared.enqueueUpload(garmentID: garment.id, imagePath: imagePath)
        hasUnsavedChanges = true
        saveChanges(dismissAfter: false)
    }

    private func persistGalleryImage(_ image: UIImage) {
        guard let jpeg = image.jpegData(compressionQuality: 0.9),
              let path = try? ImageStore.save(data: jpeg, preferredExt: "jpg") else { return }
        var paths = garment.additionalImagePaths ?? []
        paths.append(path)
        garment.additionalImagePaths = paths
        hasUnsavedChanges = true
        saveChanges(dismissAfter: false)
    }

    private func removeGalleryImage(at index: Int) {
        guard var paths = garment.additionalImagePaths, paths.indices.contains(index) else { return }
        let removed = paths.remove(at: index)
        garment.additionalImagePaths = paths.isEmpty ? nil : paths
        ImageStore.delete(path: removed)
        hasUnsavedChanges = true
        saveChanges(dismissAfter: false)
    }

    private func clearImage() {
        garment.imagePath = nil
        garment.thumbnailPath = nil
        garment.imageData = nil
        heroImage = nil
        hasUnsavedChanges = true
    }

    private func saveChanges(dismissAfter: Bool = true) {
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
            errorMessage = String(
                format: NSLocalizedString("add_garment_save_failed_format", comment: ""),
                error.localizedDescription
            )
        }
    }

    private func deleteItem() {
        if let path = garment.imagePath { ImageStore.delete(path: path) }
        if let originalPath = garment.originalImagePath { ImageStore.delete(path: originalPath) }
        if let additional = garment.additionalImagePaths {
            for path in additional { ImageStore.delete(path: path) }
        }
        context.delete(garment)
        do {
            try context.save()
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

// MARK: - Lightweight gallery thumb (async decode)

private struct AsyncGalleryThumb: View {
    let path: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground).opacity(0.5))
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: path) {
            image = await Task.detached(priority: .utility) {
                ImageStore.loadThumbnail(path: path, maxPixelSize: 180)
                    ?? ImageStore.loadImage(path: path)
            }.value
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
                    GalleryFullImage(path: path)
                        .tag(index)
                        .padding()
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

private struct GalleryFullImage: View {
    let path: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: path) {
            image = await Task.detached(priority: .utility) {
                ImageStore.loadImage(path: path)
            }.value
        }
    }
}
