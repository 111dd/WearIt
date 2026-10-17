import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// Structured garment capture: pick → crop/edit → details.
struct AddGarmentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Brand.name, order: .forward) private var brands: [Brand]

    private enum FlowState: Equatable {
        case selectImage
        case enterDetails
        case batchReview
    }

    @State private var flowState: FlowState = .selectImage

    // MARK: Batch upload state

    struct BatchItem: Identifiable {
        enum Status: Equatable {
            case processing
            case ready
            case needsCategory
        }

        let id = UUID()
        let original: UIImage
        var display: UIImage?
        var status: Status = .processing
        var category: Category?
        var itemType: ItemType?
        var colorTags: [ColorTag] = []
        var aiConfidence: Float = 0
        var usedAI = false
        /// The user picked the category on the card; AI refinement keeps it.
        var categoryConfirmed = false
        var pattern: PatternTag?
        var sleeveLength: SleeveLength?
    }

    @State private var batchItems: [BatchItem] = []
    @State private var isSavingBatch = false

    // MARK: Label scan state

    @State private var showLabelScanner = false
    @State private var isScanningLabel = false
    @State private var labelScanMessage: String?
    /// Materials read off the physical care label — user-verified facts.
    @State private var scannedMaterials: [MaterialTag] = []

    // Structured fields
    @State private var category: Category? = nil
    @State private var itemType: ItemType? = nil
    @State private var brand = ""
    @State private var colorTags: [ColorTag] = []
    @State private var userTitleOverride: String? = nil
    @State private var isEditingTitle = false
    @State private var isSuggestingName = false
    /// Provenance: attribute fields the user touched by hand. Enrichment
    /// (type defaults / on-device AI) never overwrites these.
    @State private var userEditedFields: Set<String> = []
    /// Which detail card is expanded from a quick-chip tap (nil = collapsed).
    @State private var focusedSection: FocusSection? = nil
    /// Reveals the full detail form (brand, size, season...) for power users.
    @State private var showAllDetails = false

    private enum FocusSection {
        case essentials
        case colors
        case attributes
        case fit
        case brand
        case details
    }
    /// Values as the app filled them (per field key). A field shows the ✨
    /// "filled for you" mark only while it still holds that value.
    @State private var autoValues: [String: String] = [:]
    @State private var patternTag: PatternTag? = nil
    @State private var fitTag: FitTag? = nil
    @State private var sizeOption: SizeOption? = nil
    @State private var seasonSuitability: SeasonSuitability? = nil
    @State private var minTempC: Double? = nil
    @State private var maxTempC: Double? = nil
    @State private var warmth = 3
    @State private var thermalWarmthOverride: Int?
    @State private var thermalBreathabilityOverride: Int?
    @State private var formality = 3

    // Image
    @State private var selectedImage: UIImage?
    @State private var originalPickedImage: UIImage?
    @State private var pendingCropImage: UIImage?
    @State private var showCropper = false
    @State private var savedImagePath: String?
    @State private var savedThumbnailPath: String?
    @State private var savedOriginalImagePath: String?
    /// Up to two more photos of the same item (other shop angles, the care label, the user's own).
    @State private var extraImages: [UIImage] = []
    @State private var showExtraPhotoPicker = false
    private static let maxExtraImages = 2

    // AI
    @State private var isAnalyzing = false
    @State private var aiConfidence: Float = 0
    @State private var didApplyAISuggestions = false
    @State private var aiSuggestedCategory: Category?
    @State private var aiSuggestedItemType: ItemType?
    @State private var aiSuggestedColors: [ColorTag] = []
    @State private var aiSuggestedPattern: PatternTag?
    @State private var aiSuggestedFit: FitTag?
    /// Seen by on-device AI; saved for tops so the sleeve question isn't asked.
    @State private var sleeveLength: SleeveLength?
    /// Cutout choices + photo problems from the last analysis.
    @State private var cutoutSuggestion: AutoFillSuggestion?
    /// Drops late AI results after the photo or cutout choice changed.
    @State private var aiGeneration = UUID()
    @State private var isRefining = false

    // UI
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showBarcodeScanner = false
    @State private var showProductLinkSheet = false
    @State private var productLinkText = ""
    @State private var isLookingUpBarcode = false
    @State private var isFetchingProductPage = false
    /// Product lookup filled the form but no image came back — user still needs a photo.
    @State private var barcodeNeedsPhoto = false
    /// Ignores late image downloads from a previous barcode scan.
    @State private var barcodeLookupGeneration = UUID()
    @State private var showSuccess = false
    @State private var showAdvancedOptions = false
    @State private var errorMessage: String?

    private let feedback = UIImpactFeedbackGenerator(style: .medium)
    private let onSave: ((Garment) -> Void)?

    init(initialCategory: Category? = nil, onSave: ((Garment) -> Void)? = nil) {
        self.onSave = onSave
        _category = State(initialValue: initialCategory)
    }

    private var autoGeneratedTitle: String {
        var parts: [String] = []
        if let primaryColor = colorTags.first {
            parts.append(primaryColor.title)
        }
        if let type = itemType {
            parts.append(type.title.lowercased())
        } else if let cat = category {
            parts.append(cat.title.lowercased())
        }
        var title = parts.joined(separator: " ")
        if let first = title.first {
            title = first.uppercased() + title.dropFirst()
        }
        if !brand.isEmpty {
            title += " — \(brand)"
        }
        return title.isEmpty ? String(localized: "add_garment_new_item") : title
    }

    private var displayTitle: String {
        if let override = userTitleOverride, !override.isEmpty {
            return override
        }
        return autoGeneratedTitle
    }

    private var canSave: Bool { category != nil && selectedImage != nil }
    /// Details are ready but wardrobe photo is still missing (typical after barcode/QR).
    private var needsPhotoBeforeSave: Bool { category != nil && selectedImage == nil }

    private var brandSuggestions: [Brand] {
        let text = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return Array(brands.filter { $0.name.localizedCaseInsensitiveContains(text) }.prefix(5))
    }

    private var shouldShowAddBrand: Bool {
        let text = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return !brands.contains(where: { $0.name.lowercased() == text.lowercased() })
    }

    private var shouldShowFit: Bool {
        guard let cat = category else { return false }
        return cat == .top || cat == .bottom
    }

    private var shouldShowSize: Bool {
        guard let cat = category else { return false }
        return cat == .top || cat == .bottom || cat == .shoes
    }

    private var sizeOptions: [SizeOption] {
        guard let cat = category else { return [] }
        return SizeOption.options(for: cat)
    }

    private var categoryColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: DS.Spacing.xs), count: 3)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                switch flowState {
                case .selectImage:
                    imageSelectionView
                case .enterDetails:
                    detailsFormView
                case .batchReview:
                    batchReviewView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(navigationTitle)
            .compactNavBar()
            .withLocalAppBackdrop()
            .toolbar { toolbarContent }
            .alert(String(localized: "add_garment_success_title"), isPresented: $showSuccess) {
                Button(String(localized: "action_done")) { resetAndDismiss() }
            } message: {
                Text(String(localized: "add_garment_success_message"))
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
                MultiPhotoPickerWrapper(selectionLimit: 10) { images in
                    if images.count == 1, let image = images.first {
                        processPickedImage(image)
                    } else {
                        startBatch(with: images)
                    }
                }
            }
            .sheet(isPresented: $showExtraPhotoPicker) {
                MultiPhotoPickerWrapper(selectionLimit: max(1, Self.maxExtraImages - extraImages.count)) { images in
                    addExtraImages(images)
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPickerWrapper { image in
                    processPickedImage(image)
                }
            }
            .sheet(isPresented: $showLabelScanner) {
                CameraPickerWrapper { image in
                    handleLabelScan(image)
                }
            }
            .fullScreenCover(isPresented: $showBarcodeScanner) {
                BarcodeScannerScreen(
                    onCode: { code in
                        showBarcodeScanner = false
                        lookupBarcode(code)
                    },
                    onCancel: {
                        showBarcodeScanner = false
                    }
                )
            }
            .sheet(isPresented: $showProductLinkSheet) {
                productLinkSheet
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
                            confirmCroppedImage(cropped, original: originalPickedImage ?? cropped)
                        }
                    )
                }
            }
            .onAppear {
                BrandStore.syncFromGarments(context: context)
            }
        }
    }

    private var navigationTitle: String {
        switch flowState {
        case .selectImage: return String(localized: "nav_add_item")
        case .enterDetails: return String(localized: "add_garment_details_title")
        case .batchReview: return String(localized: "batch_review_title")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if flowState == .enterDetails {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "action_back")) {
                    withAnimation(DS.Animation.standard) {
                        flowState = .selectImage
                    }
                }
            }
        } else if flowState == .batchReview {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "action_back")) {
                    withAnimation(DS.Animation.standard) {
                        batchItems = []
                        flowState = .selectImage
                    }
                }
                .disabled(isSavingBatch)
            }
        }
    }

    // MARK: - Select image

    private var imageSelectionView: some View {
        ZStack {
            VStack(spacing: DS.Spacing.xl) {
                Spacer(minLength: DS.Spacing.lg)

                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 112, height: 112)
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: DS.IconSize.xxl, weight: .light))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(spacing: DS.Spacing.sm) {
                    Text(String(localized: "add_garment_hero_title"))
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(String(localized: "add_garment_hero_subtitle"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DS.Spacing.md)

                VStack(spacing: DS.Spacing.sm) {
                    Button {
                        DS.haptic(0.6)
                        showCamera = true
                    } label: {
                        Label(String(localized: "add_garment_take_photo"), systemImage: "camera.fill")
                    }
                    .dsPrimaryButton()
                    .disabled(isLookingUpBarcode)

                    Button {
                        DS.haptic(0.5)
                        showBarcodeScanner = true
                    } label: {
                        Label(String(localized: "add_garment_scan_barcode"), systemImage: "barcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .dsSecondaryButton()
                    .disabled(isLookingUpBarcode)

                    Button {
                        DS.haptic(0.5)
                        productLinkText = ""
                        showProductLinkSheet = true
                    } label: {
                        Label(String(localized: "add_garment_paste_link"), systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .dsSecondaryButton()
                    .disabled(isLookingUpBarcode)

                    Button {
                        DS.haptic(0.5)
                        showPhotoPicker = true
                    } label: {
                        Label(String(localized: "add_garment_choose_library"), systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .dsSecondaryButton()
                    .disabled(isLookingUpBarcode)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DS.Spacing.xl)

                Text(String(localized: "add_garment_crop_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Spacing.lg)

                Spacer()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, DS.Spacing.md)
            .opacity(isLookingUpBarcode ? 0.45 : 1)

            if isLookingUpBarcode {
                VStack(spacing: DS.Spacing.sm) {
                    ProgressView()
                    Text(String(localized: isFetchingProductPage ? "webpage_looking_up" : "barcode_looking_up"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(DS.Spacing.lg)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            }
        }
    }

    private var productLinkSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "add_garment_paste_link_placeholder"), text: $productLinkText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                } footer: {
                    Text(String(localized: "add_garment_paste_link_hint"))
                }

                Section {
                    // System paste control: no "allow paste" prompt. A pasted link is fetched right away.
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in
                            guard let pasted = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                                  !pasted.isEmpty else { return }
                            productLinkText = pasted
                            if ProductPageMetadataService.productPageURL(from: pasted) != nil {
                                showProductLinkSheet = false
                                lookupProductLink(pasted)
                            }
                        }
                    }
                    .buttonBorderShape(.capsule)
                    .labelStyle(.titleAndIcon)
                }
            }
            .navigationTitle(String(localized: "add_garment_paste_link"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel")) {
                        showProductLinkSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "add_garment_fetch_link")) {
                        let link = productLinkText
                        showProductLinkSheet = false
                        lookupProductLink(link)
                    }
                    .disabled(productLinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Details

    private var draftThermalProfile: GarmentThermalProfile {
        GarmentThermalProfile(
            warmth: warmth, itemType: itemType, materials: scannedMaterials,
            fit: fitTag,
            estimatedFields: userEditedFields.contains(ItemTypeDefaults.FieldKey.warmth) ? [] : ["warmth"],
            warmthOverride: thermalWarmthOverride,
            breathabilityOverride: thermalBreathabilityOverride
        )
    }

    private var detailsFormView: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.md) {
                if needsPhotoBeforeSave {
                    barcodeNeedsPhotoBanner
                }
                heroCard
                detectedCard
                if showAllDetails || focusedSection == .essentials {
                    essentialsCard
                }
                if showAllDetails || focusedSection == .colors {
                    colorSection
                }
                if showAllDetails || focusedSection == .attributes {
                    attributesSection
                }
                if (showAllDetails || focusedSection == .fit), shouldShowFit || shouldShowSize {
                    fitSizeSection
                }
                if showAllDetails || focusedSection == .brand {
                    brandSection
                }
                if showAllDetails || focusedSection == .details {
                    advancedSection
                }
                if showAllDetails {
                    // Estimated from the item; most people never need to touch it.
                    ThermalProfileEditor(
                        profile: draftThermalProfile,
                        warmthOverride: $thermalWarmthOverride,
                        breathabilityOverride: $thermalBreathabilityOverride
                    )
                    seasonSection
                } else {
                    moreDetailsButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.sm)
            .padding(.bottom, DS.Spacing.xxl)
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            stickySaveBar
        }
    }

    private var stickySaveBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.35)
            Button {
                feedback.impactOccurred(intensity: 1.0)
                if needsPhotoBeforeSave {
                    showCamera = true
                } else {
                    saveGarment()
                }
            } label: {
                Text(String(localized: needsPhotoBeforeSave
                    ? "barcode_found_needs_photo_action"
                    : "garment_add_title"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .dsPrimaryButton()
            .disabled(isAnalyzing || category == nil)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.sm)
            .padding(.bottom, DS.Spacing.md)
        }
        .background(.ultraThinMaterial)
    }

    private var barcodeNeedsPhotoBanner: some View {
        Button {
            showCamera = true
        } label: {
            Label(String(localized: "barcode_found_needs_photo"), systemImage: "camera.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .padding(DS.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - What was filled for you

    /// The heart of the frictionless flow: one line per thing the app knows
    /// about the item, ✨ on what it filled by itself. All good → save. A
    /// wrong line opens just its editor below.
    private var detectedCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                Text(String(localized: "add_garment_detected_title"))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if isRefining {
                    Label(String(localized: "add_garment_ai_refining"), systemImage: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .symbolEffect(.pulse)
                }
            }

            VStack(spacing: 0) {
                detectedRow(
                    icon: category?.icon ?? "square.grid.2x2",
                    label: String(localized: "garment_item_type"),
                    value: itemType?.title ?? category?.title,
                    key: "type", section: .essentials, needsAttention: category == nil
                )
                detectedRow(
                    icon: "paintpalette", label: String(localized: "garment_colors"),
                    value: colorTags.isEmpty ? nil : colorTags.prefix(3).map(\.title).joined(separator: ", "),
                    key: "colors", section: .colors
                )
                if let patternTag, patternTag != .solid {
                    detectedRow(icon: "square.grid.3x3", label: String(localized: "garment_pattern"),
                                value: patternTag.title, key: "pattern", section: .details)
                }
                if category == .top {
                    sleeveRow
                }
                if shouldShowFit, let fitTag {
                    detectedRow(icon: "ruler", label: String(localized: "fit_label"),
                                value: fitTag.title, key: "fit", section: .fit)
                }
                if shouldShowSize {
                    detectedRow(icon: "ruler.fill", label: String(localized: "size_label"),
                                value: sizeOption?.title, key: "size", section: .fit)
                }
                if !scannedMaterials.isEmpty {
                    detectedRow(icon: "leaf", label: String(localized: "garment_materials"),
                                value: scannedMaterials.prefix(2).map(\.title).joined(separator: ", "),
                                key: "material", section: .details)
                }
                if !brand.isEmpty {
                    detectedRow(icon: "tag", label: String(localized: "garment_brand"),
                                value: brand, key: "brand", section: .brand)
                }
                detectedRow(
                    icon: "briefcase", label: String(localized: "garment_formality"),
                    value: "\(formality)/5", key: "formality", section: .attributes,
                    isAutoOverride: !userEditedFields.contains(ItemTypeDefaults.FieldKey.formality)
                )
            }

            Text(category == nil
                ? String(localized: "add_garment_chips_hint_missing_category")
                : String(localized: "add_garment_detected_hint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
    }

    private func detectedRow(
        icon: String,
        label: String,
        value: String?,
        key: String,
        section: FocusSection,
        needsAttention: Bool = false,
        isAutoOverride: Bool? = nil
    ) -> some View {
        let isFocused = focusedSection == section
        let isAuto = isAutoOverride ?? isAutoFilled(key)
        return Button {
            toggleFocus(section)
        } label: {
            detectedRowLabel(icon: icon, label: label, value: value, isAuto: isAuto,
                             needsAttention: needsAttention, trailingIcon: isFocused ? "chevron.up" : "chevron.down")
        }
        .buttonStyle(.plain)
    }

    /// Sleeves change the warmth math, so they're one tap away (no editor card).
    private var sleeveRow: some View {
        Menu {
            ForEach(SleeveLength.allCases) { sleeve in
                Button {
                    sleeveLength = sleeve
                    DS.haptic(0.3)
                } label: {
                    if sleeveLength == sleeve {
                        Label(sleeve.title, systemImage: "checkmark")
                    } else {
                        Text(sleeve.title)
                    }
                }
            }
        } label: {
            detectedRowLabel(icon: "tshirt", label: String(localized: "garment_sleeve"),
                             value: sleeveLength?.title ?? derivedSleeve?.title,
                             isAuto: sleeveLength == nil ? derivedSleeve != nil : isAutoFilled("sleeve"),
                             needsAttention: false, trailingIcon: "chevron.up.chevron.down")
        }
        .buttonStyle(.plain)
    }

    /// What the type implies (t-shirt → short) when nobody said otherwise.
    private var derivedSleeve: SleeveLength? {
        switch itemType {
        case .tshirt?, .polo?, .tank?, .vest?: return .short
        case .sweater?, .hoodie?, .cardigan?: return .long
        default: return nil
        }
    }

    private func detectedRowLabel(
        icon: String, label: String, value: String?, isAuto: Bool, needsAttention: Bool, trailingIcon: String
    ) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: DS.Spacing.sm)
            if isAuto, value != nil {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(String(localized: "add_garment_detected_auto"))
            }
            Text(value ?? String(localized: "add_garment_value_missing"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(needsAttention || value == nil ? Color.accentColor : .primary)
                .lineLimit(1)
            Image(systemName: trailingIcon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    // MARK: Filled-for-you tracking

    private func currentValue(for key: String) -> String {
        switch key {
        case "type": return [category?.rawValue, itemType?.rawValue].compactMap { $0 }.joined(separator: "/")
        case "colors": return colorTags.map(\.rawValue).joined(separator: ",")
        case "pattern": return patternTag?.rawValue ?? ""
        case "fit": return fitTag?.rawValue ?? ""
        case "sleeve": return sleeveLength?.rawValue ?? ""
        case "material": return scannedMaterials.map(\.rawValue).joined(separator: ",")
        case "brand": return brand
        case "size": return sizeOption?.rawValue ?? ""
        default: return ""
        }
    }

    /// Record that the app (not the user) just set these fields.
    private func markAutoFilled(_ keys: String...) {
        for key in keys {
            let value = currentValue(for: key)
            if value.isEmpty { autoValues[key] = nil } else { autoValues[key] = value }
        }
    }

    private func isAutoFilled(_ key: String) -> Bool {
        guard let value = autoValues[key] else { return false }
        return value == currentValue(for: key)
    }

    private func toggleFocus(_ section: FocusSection) {
        DS.haptic(0.35)
        withAnimation(DS.Animation.standard) {
            focusedSection = (focusedSection == section) ? nil : section
            if focusedSection == .details { showAdvancedOptions = true }
        }
    }

    private var moreDetailsButton: some View {
        Button {
            DS.haptic(0.35)
            withAnimation(DS.Animation.standard) {
                showAllDetails = true
                focusedSection = nil
            }
        } label: {
            Label(String(localized: "add_garment_more_details"), systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
        }
        .dsSecondaryButton()
    }

    // MARK: - Batch review

    private var batchReadyCount: Int {
        batchItems.filter { $0.status != .processing && $0.category != nil }.count
    }

    private var batchProcessingCount: Int {
        batchItems.filter { $0.status == .processing }.count
    }

    private var batchReviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text(batchProcessingCount > 0
                    ? String(format: NSLocalizedString("batch_processing_status_format", comment: ""), batchProcessingCount)
                    : String(localized: "batch_review_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: DS.Spacing.sm)], spacing: DS.Spacing.sm) {
                    ForEach(batchItems) { item in
                        batchItemCard(item)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.sm)
            .padding(.bottom, DS.Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            batchSaveBar
        }
    }

    private var batchSaveBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.35)
            Button {
                feedback.impactOccurred(intensity: 1.0)
                saveBatch()
            } label: {
                if isSavingBatch {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(String(format: NSLocalizedString("batch_save_all_format", comment: ""), batchReadyCount))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .dsPrimaryButton()
            .disabled(batchReadyCount == 0 || isSavingBatch)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.sm)
            .padding(.bottom, DS.Spacing.md)
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func batchItemCard(_ item: BatchItem) -> some View {
        VStack(spacing: DS.Spacing.xs) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(Color(.secondarySystemBackground).opacity(0.45))

                Image(uiImage: item.display ?? item.original)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()

                if item.status == .processing {
                    Color.black.opacity(0.22)
                    ProgressView()
                        .tint(.white)
                }
            }
            .aspectRatio(DS.AspectRatio.garmentTile, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation(DS.Animation.standard) {
                        batchItems.removeAll { $0.id == item.id }
                        if batchItems.isEmpty {
                            flowState = .selectImage
                        }
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel(String(localized: "batch_item_remove"))
                .disabled(isSavingBatch)
            }

            // Category chip: AI result, or a menu to pick one when missing.
            Menu {
                ForEach(Category.allCases) { cat in
                    Button {
                        setBatchCategory(cat, for: item.id)
                    } label: {
                        Label(cat.title, systemImage: cat.icon)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: item.category?.icon ?? "questionmark.circle")
                        .font(.caption2)
                    Text(item.itemType?.title ?? item.category?.title ?? String(localized: "batch_needs_category"))
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, 5)
                .foregroundStyle(item.category == nil ? Color.accentColor : .primary)
                .background(
                    Capsule(style: .continuous)
                        .fill(item.category == nil
                            ? Color.accentColor.opacity(0.14)
                            : Color(.secondarySystemBackground).opacity(0.45))
                )
            }
            .disabled(item.status == .processing || isSavingBatch)
        }
        .padding(DS.Spacing.xs)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: false)
    }

    private func setBatchCategory(_ category: Category, for id: UUID) {
        guard let index = batchItems.firstIndex(where: { $0.id == id }) else { return }
        batchItems[index].category = category
        batchItems[index].categoryConfirmed = true
        if let type = batchItems[index].itemType, !category.itemTypes.contains(type) {
            batchItems[index].itemType = nil
        }
        if batchItems[index].status == .needsCategory {
            batchItems[index].status = .ready
        }
        DS.haptic(0.35)
    }

    private func startBatch(with images: [UIImage]) {
        batchItems = images.map { BatchItem(original: $0) }
        withAnimation(DS.Animation.standard) {
            flowState = .batchReview
        }
        // Serial analysis keeps memory bounded and the UI responsive; each
        // finished item flips from spinner to reviewable card.
        Task {
            for item in batchItems {
                guard flowState == .batchReview else { return }
                let suggestion = await AutoFillService.suggest(from: item.original)
                guard let index = batchItems.firstIndex(where: { $0.id == item.id }) else { continue }
                withAnimation(DS.Animation.standard) {
                    batchItems[index].display = suggestion.displayImage
                    batchItems[index].category = suggestion.category
                    batchItems[index].itemType = suggestion.itemType
                    batchItems[index].colorTags = suggestion.colorTags
                    batchItems[index].aiConfidence = suggestion.confidence
                    batchItems[index].usedAI = suggestion.category != nil || !suggestion.colorTags.isEmpty
                    batchItems[index].status = suggestion.category == nil ? .needsCategory : .ready
                }
            }
            await refineBatch()
        }
    }

    /// Second pass once every card is reviewable: on-device Foundation Models
    /// improves type and adds pattern / sleeve. Never overrides a user's pick.
    private func refineBatch() async {
        for item in batchItems {
            guard flowState == .batchReview, !isSavingBatch else { return }
            guard let refinement = await AutoFillService.refine(item.display ?? item.original, categoryHint: nil),
                  let index = batchItems.firstIndex(where: { $0.id == item.id }) else { continue }
            var current = batchItems[index]
            if !current.categoryConfirmed, let category = refinement.category {
                current.category = category
                current.itemType = refinement.itemType
                current.usedAI = true
                if current.status == .needsCategory { current.status = .ready }
            } else if current.itemType == nil, let type = refinement.itemType,
                      current.category?.itemTypes.contains(type) == true {
                current.itemType = type
            }
            if current.colorTags.isEmpty { current.colorTags = refinement.colorTags }
            current.pattern = refinement.pattern
            current.sleeveLength = refinement.sleeveLength
            withAnimation(DS.Animation.standard) {
                batchItems[index] = current
            }
        }
    }

    private func saveBatch() {
        let itemsToSave = batchItems.filter { $0.status != .processing && $0.category != nil }
        guard !itemsToSave.isEmpty, !isSavingBatch else { return }
        isSavingBatch = true

        var savedGarments: [Garment] = []
        let profile = CurrentUser.activeProfile(in: context, createIfNeeded: true)

        for item in itemsToSave {
            guard let category = item.category else { continue }
            let display = item.display ?? item.original

            var imagePath: String?
            var originalPath: String?
            var thumbnailPath: String?
            if let png = display.pngData() {
                imagePath = try? ImageStore.save(data: png, preferredExt: "png")
            } else if let jpeg = display.jpegData(compressionQuality: 0.9) {
                imagePath = try? ImageStore.save(data: jpeg, preferredExt: "jpg")
            }
            if let jpeg = item.original.jpegData(compressionQuality: 0.9) {
                originalPath = try? ImageStore.save(data: jpeg, preferredExt: "jpg")
            }
            if let imagePath {
                thumbnailPath = ImageStore.generateAndSaveThumbnail(
                    for: imagePath,
                    maxPixelSize: ImageStore.thumbnailMaxPixelSize
                )
            }
            guard imagePath != nil else { continue }

            let garment = Garment(
                category: category,
                itemType: item.itemType,
                colorTags: item.colorTags,
                patternTag: item.pattern,
                imagePath: imagePath,
                thumbnailPath: thumbnailPath,
                originalImagePath: originalPath,
                aiSuggestedCategory: item.usedAI ? item.category : nil,
                aiSuggestedItemType: item.usedAI ? item.itemType : nil,
                aiSuggestedColors: item.colorTags.isEmpty ? nil : item.colorTags,
                aiConfidence: item.aiConfidence > 0 ? item.aiConfidence : nil,
                aiProcessedAt: item.usedAI ? Date() : nil
            )
            if category == .top, let sleeve = item.sleeveLength {
                garment.sleeveLength = sleeve
            }
            if let profile {
                garment.ownerID = profile.id
                if !profile.garmentIDs.contains(garment.id) {
                    profile.garmentIDs.append(garment.id)
                }
            }
            // Batch items skip the form entirely — everything beyond the
            // category is enrichment-owned.
            garment.markEnriched([
                ItemTypeDefaults.FieldKey.warmth,
                ItemTypeDefaults.FieldKey.formality
            ])
            GarmentEnrichmentService.applyDefaults(to: garment)
            context.insert(garment)
            savedGarments.append(garment)
        }

        do {
            try context.save()
            for garment in savedGarments {
                if let path = garment.imagePath {
                    CloudKitImageSyncService.shared.enqueueUpload(garmentID: garment.id, imagePath: path)
                }
            }
            Task {
                for garment in savedGarments {
                    await GarmentEnrichmentService.enrichWithAI(garment, context: context)
                }
            }
            NotificationCenter.default.post(name: .garmentAdded, object: nil)
            isSavingBatch = false
            let unsaved = batchItems.filter { candidate in
                !itemsToSave.contains { $0.id == candidate.id }
            }
            withAnimation(DS.Animation.standard) {
                batchItems = unsaved
                if unsaved.isEmpty {
                    showSuccess = true
                    flowState = .selectImage
                }
            }
        } catch {
            isSavingBatch = false
            errorMessage = String(
                format: NSLocalizedString("add_garment_save_failed_format", comment: ""),
                error.localizedDescription
            )
        }
    }

    // MARK: - Cards

    private var heroCard: some View {
        VStack(spacing: DS.Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(Color(.secondarySystemBackground).opacity(0.45))

                if let image = selectedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipped()
                } else {
                    VStack(spacing: DS.Spacing.sm) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 36, weight: .light))
                        Text(String(localized: "barcode_found_needs_photo_action"))
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding(DS.Spacing.md)
                }

                if isAnalyzing {
                    Color.black.opacity(0.28)
                    analyzingOverlay
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
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .onTapGesture {
                guard selectedImage == nil else { return }
                showCamera = true
            }

            HStack(spacing: DS.Spacing.sm) {
                if selectedImage != nil {
                    Button {
                        reopenCropper()
                    } label: {
                        Label(String(localized: "add_garment_edit_photo"), systemImage: "crop")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    showCamera = true
                } label: {
                    Label(
                        String(localized: selectedImage == nil ? "add_garment_take_photo" : "add_garment_retake"),
                        systemImage: "camera"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button {
                    showPhotoPicker = true
                } label: {
                    Label(
                        String(localized: selectedImage == nil ? "add_garment_choose_library" : "add_garment_change_photo"),
                        systemImage: "photo"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.secondary)

            if let cutoutSuggestion {
                cutoutChoices(cutoutSuggestion)
            }

            if selectedImage != nil {
                extraPhotosRow
            }

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
                    get: { userTitleOverride ?? autoGeneratedTitle },
                    set: { userTitleOverride = $0 }
                ))
                .textFieldStyle(.plain)
                .dsFieldStyle()
                .multilineTextAlignment(.center)
                .onSubmit { isEditingTitle = false }

                Button(String(localized: "add_garment_use_auto_title")) {
                    userTitleOverride = nil
                    isEditingTitle = false
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text(displayTitle)
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
                        .disabled(isSuggestingName || category == nil)
                        .accessibilityLabel(String(localized: "garment_ai_name_suggest"))
                    }
                }
            }
        }
        .padding(.top, DS.Spacing.xxs)
    }

    private func suggestNameWithAI() {
        guard #available(iOS 26.0, *) else { return }
        guard !isSuggestingName, let category else { return }
        let request = GarmentNameRequest(
            category: category.rawValue,
            itemType: itemType?.rawValue,
            colors: colorTags.prefix(2).map(\.rawValue),
            material: nil,
            pattern: patternTag?.rawValue,
            fit: fitTag?.rawValue,
            brand: brand.isEmpty ? nil : brand.trimmingCharacters(in: .whitespacesAndNewlines),
            languageCode: Locale.current.language.languageCode?.identifier ?? "en"
        )
        isSuggestingName = true
        Task {
            let name = await LookExplanationService.shared.suggestGarmentName(for: request)
            isSuggestingName = false
            if let name {
                userTitleOverride = name
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
                        .foregroundStyle(category == cat ? Color.accentColor : .primary)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                .fill(category == cat ? Color.accentColor.opacity(0.14) : Color(.secondarySystemBackground).opacity(0.35))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                .strokeBorder(category == cat ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let cat = category {
                Text(String(localized: "garment_item_type"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, DS.Spacing.xxs)
                ItemTypeSelector(category: cat, selectedType: Binding(
                    get: { itemType },
                    set: {
                        itemType = $0
                        applyTypeDefaultsToState()
                    }
                ))
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
    }

    private var fitSizeSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "fit_size_title"), icon: "ruler")
            if shouldShowFit {
                SingleTagPicker(
                    title: String(localized: "fit_label"),
                    allTags: FitTag.allCases,
                    selectedTag: $fitTag,
                    titleForTag: { $0.title }
                )
            }
            if shouldShowSize {
                SingleTagPicker(
                    title: String(localized: "size_label"),
                    allTags: sizeOptions,
                    selectedTag: $sizeOption,
                    titleForTag: { $0.title }
                )
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
    }

    private var colorSection: some View {
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
                    colorTags.isEmpty
                        ? String(localized: "garment_colors_recommended")
                        : String(format: NSLocalizedString("add_garment_colors_selected_format", comment: ""), colorTags.count)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ColorTagSelector(selectedColors: $colorTags)

            Text(String(localized: "tag_bilingual_hint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
    }

    private var brandSection: some View {
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

            TextField(String(localized: "garment_brand_placeholder"), text: $brand)
                .textFieldStyle(.plain)
                .dsFieldStyle()

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
                            brand = suggestion.name
                        } label: {
                            Text(suggestion.name)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    if shouldShowAddBrand {
                        Text(String(format: NSLocalizedString("brand_add_suggestion", comment: ""), brand))
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

    private var seasonSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "garment_season"), icon: "leaf")
            SeasonSelector(selectedSeason: Binding(
                get: { seasonSuitability },
                set: {
                    seasonSuitability = $0
                    userEditedFields.insert(ItemTypeDefaults.FieldKey.season)
                }
            ))
            if seasonSuitability != nil {
                DisclosureGroup(String(localized: "garment_temperature_range")) {
                    TemperatureRangeSlider(
                        minTemp: $minTempC,
                        maxTemp: $maxTempC,
                        defaultRange: seasonSuitability?.defaultTempRange ?? (10, 25)
                    )
                }
                .font(.subheadline)
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
    }

    private var attributesSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            DSSectionHeader(String(localized: "garment_attributes"), icon: "slider.horizontal.3")
            attributeRow(
                icon: "briefcase",
                title: String(localized: "garment_formality"),
                value: formality,
                tint: .accentColor
            ) {
                Stepper(String(localized: "garment_formality"), value: Binding(
                    get: { formality },
                    set: {
                        formality = $0
                        userEditedFields.insert(ItemTypeDefaults.FieldKey.formality)
                    }
                ), in: 1...5)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Image(systemName: icon)
                .foregroundStyle(.secondary)
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

    private var advancedSection: some View {
        DisclosureGroup(String(localized: "garment_more_options"), isExpanded: $showAdvancedOptions) {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                materialPicker

                SingleTagPicker(
                    title: String(localized: "garment_pattern"),
                    allTags: PatternTag.allCases,
                    selectedTag: $patternTag,
                    titleForTag: { $0.title }
                )
            }
            .padding(.top, DS.Spacing.sm)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
        .onAppear {
            if !scannedMaterials.isEmpty {
                showAdvancedOptions = true
            }
        }
    }

    private var materialPicker: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(String(localized: "garment_materials"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.Text.secondary)

            FlowLayout(spacing: 8) {
                ForEach(MaterialTag.allCases) { tag in
                    let selected = scannedMaterials.contains(tag)
                    Button {
                        if let index = scannedMaterials.firstIndex(of: tag) {
                            scannedMaterials.remove(at: index)
                        } else {
                            scannedMaterials.append(tag)
                        }
                        userEditedFields.insert(ItemTypeDefaults.FieldKey.materialTags)
                    } label: {
                        Text(tag.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(selected ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground).opacity(0.45))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Cutout picker (several items, or top / bottom / shoes of a selfie) and
    /// a retake hint when the photo itself is the problem.
    @ViewBuilder
    private func cutoutChoices(_ suggestion: AutoFillSuggestion) -> some View {
        if suggestion.candidates.count > 1 {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(String(localized: "cutout_choose_title"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.sm) {
                        ForEach(Array(suggestion.candidates.enumerated()), id: \.element.id) { index, candidate in
                            let isSelected = index == suggestion.selectedCandidateIndex
                            Button {
                                selectCutout(candidate)
                            } label: {
                                VStack(spacing: 4) {
                                    Image(uiImage: candidate.image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 56, height: 64)
                                        .padding(4)
                                        .background(
                                            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                                .fill(Color(.secondarySystemBackground).opacity(0.6))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                                        )
                                    Text(candidate.title)
                                        .font(.caption2.weight(isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? .primary : .secondary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isAnalyzing)
                            .accessibilityLabel(candidate.title)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let issue = suggestion.qualityIssues.first {
            HStack(spacing: DS.Spacing.sm) {
                Label(issue.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(String(localized: "add_garment_retake")) {
                    showCamera = true
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
            }
        }
    }

    /// Main photo + up to two more (3 in total).
    private var extraPhotosRow: some View {
        HStack(spacing: DS.Spacing.sm) {
            ForEach(Array(extraImages.enumerated()), id: \.offset) { index, image in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            withAnimation(DS.Animation.standard) { _ = extraImages.remove(at: index) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                        .accessibilityLabel(String(localized: "batch_item_remove"))
                    }
            }
            if extraImages.count < Self.maxExtraImages {
                Button {
                    DS.haptic(0.3)
                    showExtraPhotoPicker = true
                } label: {
                    Label(String(localized: "add_garment_more_photos"), systemImage: "plus.rectangle.on.rectangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func addExtraImages(_ images: [UIImage]) {
        let room = Self.maxExtraImages - extraImages.count
        guard room > 0 else { return }
        withAnimation(DS.Animation.standard) {
            extraImages.append(contentsOf: images.prefix(room))
        }
    }

    /// Additional photos go next to the main image as plain JPEGs.
    private func persistExtraImages() -> [String]? {
        let paths = extraImages.prefix(Self.maxExtraImages).compactMap { image -> String? in
            guard let jpeg = image.jpegData(compressionQuality: 0.88) else { return nil }
            return try? ImageStore.save(data: jpeg, preferredExt: "jpg")
        }
        return paths.isEmpty ? nil : paths
    }

    private var analyzingOverlay: some View {
        VStack(spacing: DS.Spacing.sm) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(String(localized: "add_garment_analyzing"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(DS.Spacing.lg)
        .liquidGlassPill()
    }

    // MARK: - Actions

    private func selectCategory(_ cat: Category) {
        category = cat
        if let current = itemType, !cat.itemTypes.contains(current) {
            itemType = nil
        }
        if cat != .top && cat != .bottom {
            fitTag = nil
        }
        if cat != .top && cat != .bottom && cat != .shoes {
            sizeOption = nil
        } else if let current = sizeOption, !SizeOption.options(for: cat).contains(current) {
            sizeOption = nil
        }
        applyTypeDefaultsToState()
    }

    /// Frictionless path: no crop gate. The picked photo goes straight to
    /// on-device analysis (which also cuts out the background); manual crop
    /// remains available from the hero card for fine-tuning.
    private func processPickedImage(_ image: UIImage) {
        confirmCroppedImage(image, original: image)
    }

    private func lookupProductLink(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProductPageMetadataService.productPageURL(from: trimmed) != nil else {
            errorMessage = String(localized: "add_garment_paste_link_invalid")
            return
        }
        lookupBarcode(trimmed)
    }

    private func lookupBarcode(_ code: String) {
        let generation = UUID()
        barcodeLookupGeneration = generation
        isLookingUpBarcode = true
        isFetchingProductPage = false
        errorMessage = nil
        // Drop previous scan's photo/fields immediately so they can't leak into the next product.
        clearLookupImageState()
        resetLookupFormFields()

        Task {
            do {
                let product = try await fetchScannedProduct(code)

                // Apply title/brand/category immediately — don't wait on image download.
                await MainActor.run {
                    guard barcodeLookupGeneration == generation else { return }
                    applyBarcodeProduct(product, image: nil)
                    isLookingUpBarcode = false
                    isFetchingProductPage = false
                }

                // Shops list several photos; the item on its own becomes the main
                // photo (cut out), two more angles are kept as they are.
                let images = await ProductImagePicker.rankedImages(
                    from: product.imageURLs, limit: Self.maxExtraImages + 1
                )
                guard let image = images.first else { return }
                await MainActor.run {
                    guard barcodeLookupGeneration == generation else { return }
                    extraImages = Array(images.dropFirst())
                }

                await MainActor.run {
                    guard barcodeLookupGeneration == generation else { return }
                    applyProductImage(image)
                    isAnalyzing = true
                }

                let suggestion = await AutoFillService.suggest(from: image, preferredCategory: category)
                await MainActor.run {
                    guard barcodeLookupGeneration == generation else { return }
                    if suggestion.candidates.count > 1 { cutoutSuggestion = suggestion }
                    // Only fill gaps — barcode / page metadata wins for brand/title/category.
                    if colorTags.isEmpty, !suggestion.colorTags.isEmpty {
                        colorTags = suggestion.colorTags
                    }
                    if category == nil, let suggestedCategory = suggestion.category {
                        category = suggestedCategory
                    }
                    if itemType == nil, let suggestedType = suggestion.itemType,
                       let cat = category ?? suggestion.category,
                       cat.itemTypes.contains(suggestedType) {
                        itemType = suggestedType
                    }
                    if suggestion.usedCutout {
                        selectedImage = suggestion.displayImage
                        persistDisplayImage(suggestion.displayImage, original: image)
                    }
                    applyTypeDefaultsToState()
                    markAutoFilled("type", "colors")
                    isAnalyzing = false
                    let aiRun = UUID()
                    aiGeneration = aiRun
                    startRefinement(for: suggestion, generation: aiRun)
                }
            } catch {
                await MainActor.run {
                    guard barcodeLookupGeneration == generation else { return }
                    isLookingUpBarcode = false
                    isFetchingProductPage = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Clears wardrobe photo state from a previous scan / pick.
    private func clearLookupImageState() {
        selectedImage = nil
        originalPickedImage = nil
        pendingCropImage = nil
        savedImagePath = nil
        savedThumbnailPath = nil
        savedOriginalImagePath = nil
        extraImages = []
        barcodeNeedsPhoto = false
        isAnalyzing = false
    }

    /// Clears product fields so a second barcode doesn't keep the first product's metadata.
    private func resetLookupFormFields() {
        brand = ""
        userTitleOverride = nil
        itemType = nil
        colorTags = []
        sizeOption = nil
        fitTag = nil
        patternTag = nil
        scannedMaterials = []
        labelScanMessage = nil
        didApplyAISuggestions = false
        aiSuggestedCategory = nil
        aiSuggestedItemType = nil
        aiSuggestedColors = []
        aiSuggestedPattern = nil
        aiSuggestedFit = nil
        sleeveLength = nil
        cutoutSuggestion = nil
        isRefining = false
        aiGeneration = UUID()
        autoValues = [:]
        aiConfidence = 0
        // Keep planner pre-selection only until the new product applies its own category.
        category = nil
    }

    /// Lined barcodes go to the Barcode Lookup API. Registered `ProductURLResolver`s
    /// (e.g. Digimarc / Ralph Lauren DPIDs) run next. Remaining product-page QR links
    /// scrape Open Graph / JSON-LD. Non-apparel products are rejected before form fill.
    private func fetchScannedProduct(_ code: String) async throws -> BarcodeProduct {
        let product: BarcodeProduct
        if let pageURL = ProductPageMetadataService.productPageURL(from: code) {
            if let resolver = ProductURLResolverRegistry.resolver(for: pageURL) {
                await MainActor.run { isFetchingProductPage = true }
                product = try await resolver.fetch(from: pageURL)
            } else if let explicitCode = BarcodeLookupService.explicitProductCode(fromURL: pageURL),
                      let lookedUp = try? await BarcodeLookupService.lookup(barcode: explicitCode) {
                product = lookedUp
            } else {
                await MainActor.run { isFetchingProductPage = true }
                product = try await ProductPageMetadataService.fetch(url: pageURL)
            }
        } else {
            product = try await BarcodeLookupService.lookup(barcode: code)
        }

        try ProductFieldMapper.requireApparel(product)
        return product
    }

    private func applyBarcodeProduct(_ product: BarcodeProduct, image: UIImage?) {
        // Replace previous scan fields — don't merge leftovers from an earlier barcode.
        brand = product.brand ?? ""
        userTitleOverride = (product.title?.isEmpty == false) ? product.title : nil
        category = product.category
        if let type = product.itemType {
            if let cat = category, cat.itemTypes.contains(type) {
                itemType = type
            } else if category == nil {
                itemType = type
            } else {
                itemType = nil
            }
        } else {
            itemType = nil
        }
        colorTags = product.colors
        sizeOption = product.size
        patternTag = product.pattern
        fitTag = product.fit
        sleeveLength = product.sleeveLength
        scannedMaterials = product.materials
        if !product.materials.isEmpty {
            userEditedFields.insert(ItemTypeDefaults.FieldKey.materialTags)
            showAdvancedOptions = true
        }

        didApplyAISuggestions = true
        applyTypeDefaultsToState()
        markAutoFilled("type", "colors", "pattern", "fit", "sleeve", "material", "brand")

        if let image {
            applyProductImage(image)
        } else {
            clearLookupImageState()
            barcodeNeedsPhoto = true
            withAnimation(DS.Animation.standard) {
                flowState = .enterDetails
            }
            DS.haptic(0.4)
        }
    }

    private func applyProductImage(_ image: UIImage) {
        barcodeNeedsPhoto = false
        selectedImage = image
        originalPickedImage = image
        persistDisplayImage(image, original: image)
        withAnimation(DS.Animation.standard) {
            flowState = .enterDetails
        }
        DS.haptic(0.5)
    }

    private func reopenCropper() {
        let source = originalPickedImage ?? selectedImage
        guard let source else { return }
        pendingCropImage = source
        showCropper = true
    }

    private func confirmCroppedImage(_ cropped: UIImage, original: UIImage) {
        // Preserve fields already filled from barcode / product-page lookup;
        // AI only fills gaps (see applySuggestion).
        let keepLookupSuggestions = didApplyAISuggestions || barcodeNeedsPhoto
        selectedImage = cropped
        originalPickedImage = original
        barcodeNeedsPhoto = false
        isAnalyzing = true
        if !keepLookupSuggestions {
            didApplyAISuggestions = false
            aiConfidence = 0
            aiSuggestedCategory = nil
            aiSuggestedItemType = nil
            aiSuggestedColors = []
        }
        cutoutSuggestion = nil
        let generation = UUID()
        aiGeneration = generation

        persistDisplayImage(cropped, original: original)
        withAnimation(DS.Animation.standard) {
            flowState = .enterDetails
        }

        Task {
            let suggestion = await AutoFillService.suggest(from: cropped, preferredCategory: category)
            await MainActor.run {
                guard aiGeneration == generation else { return }
                applySuggestion(suggestion, original: original)
                if keepLookupSuggestions {
                    didApplyAISuggestions = true
                }
                isAnalyzing = false
                startRefinement(for: suggestion, generation: generation)
            }
        }
    }

    /// The user picked another cutout (another item, or top / bottom / shoes of
    /// a selfie). Guesses that came from the previous cutout are cleared first.
    private func selectCutout(_ candidate: CutoutCandidate) {
        guard let base = cutoutSuggestion, !isAnalyzing,
              base.candidates.indices.contains(base.selectedCandidateIndex),
              base.candidates[base.selectedCandidateIndex].id != candidate.id else { return }
        let generation = UUID()
        aiGeneration = generation
        isAnalyzing = true
        isRefining = false
        if category == aiSuggestedCategory { category = nil }
        if itemType == aiSuggestedItemType { itemType = nil }
        if colorTags == aiSuggestedColors { colorTags = [] }
        if patternTag == aiSuggestedPattern { patternTag = nil }
        if fitTag == aiSuggestedFit { fitTag = nil }
        sleeveLength = nil
        DS.haptic(0.3)
        let original = originalPickedImage ?? candidate.image

        Task {
            let suggestion = await AutoFillService.describe(candidate, in: base)
            await MainActor.run {
                guard aiGeneration == generation else { return }
                applySuggestion(suggestion, original: original)
                isAnalyzing = false
                startRefinement(for: suggestion, generation: generation)
            }
        }
    }

    /// Slower on-device look (Foundation Models with the image, iOS 27).
    /// Fills only what the user hasn't set; replaces the instant guesses.
    private func startRefinement(for suggestion: AutoFillSuggestion, generation: UUID) {
        guard suggestion.usedCutout || suggestion.category != nil else { return }
        let hint = suggestion.candidates.indices.contains(suggestion.selectedCandidateIndex)
            ? suggestion.candidates[suggestion.selectedCandidateIndex].categoryHint : nil
        isRefining = true
        Task {
            let refinement = await AutoFillService.refine(suggestion.displayImage, categoryHint: hint)
            await MainActor.run {
                guard aiGeneration == generation else { return }
                isRefining = false
                if let refinement { applyRefinement(refinement) }
            }
        }
    }

    private func applyRefinement(_ refinement: AutoFillRefinement) {
        var applied = false
        if let suggested = refinement.category, category == nil || category == aiSuggestedCategory {
            if category != suggested {
                category = suggested
                if let type = itemType, !suggested.itemTypes.contains(type) { itemType = nil }
                applied = true
                markAutoFilled("type")
            }
            aiSuggestedCategory = suggested
        }
        if let suggested = refinement.itemType, itemType == nil || itemType == aiSuggestedItemType,
           category?.itemTypes.contains(suggested) == true {
            if itemType != suggested {
                itemType = suggested
                applied = true
                markAutoFilled("type")
            }
            aiSuggestedItemType = suggested
        }
        if !refinement.colorTags.isEmpty, colorTags.isEmpty || colorTags == aiSuggestedColors {
            if colorTags != refinement.colorTags {
                colorTags = refinement.colorTags
                applied = true
                markAutoFilled("colors")
            }
            aiSuggestedColors = refinement.colorTags
        }
        if let pattern = refinement.pattern, patternTag == nil {
            patternTag = pattern
            aiSuggestedPattern = pattern
            applied = true
            markAutoFilled("pattern")
        }
        if let fit = refinement.fit, fitTag == nil, shouldShowFit {
            fitTag = fit
            aiSuggestedFit = fit
            applied = true
            markAutoFilled("fit")
        }
        if sleeveLength == nil, let sleeve = refinement.sleeveLength {
            sleeveLength = sleeve
            markAutoFilled("sleeve")
        }
        guard applied else { return }
        didApplyAISuggestions = true
        applyTypeDefaultsToState()
        if category != nil, focusedSection == .essentials {
            withAnimation(DS.Animation.standard) { focusedSection = nil }
        }
        DS.haptic(0.3)
    }

    private func persistDisplayImage(_ display: UIImage, original: UIImage) {
        if let jpeg = original.jpegData(compressionQuality: 0.9) {
            savedOriginalImagePath = try? ImageStore.save(data: jpeg, preferredExt: "jpg")
        }
        if let png = display.pngData() {
            savedImagePath = try? ImageStore.save(data: png, preferredExt: "png")
        } else if let jpeg = display.jpegData(compressionQuality: 0.9) {
            savedImagePath = try? ImageStore.save(data: jpeg, preferredExt: "jpg")
        }
        if let path = savedImagePath {
            savedThumbnailPath = ImageStore.generateAndSaveThumbnail(
                for: path,
                maxPixelSize: ImageStore.thumbnailMaxPixelSize
            )
        }
    }

    private func applySuggestion(_ suggestion: AutoFillSuggestion, original: UIImage) {
        cutoutSuggestion = suggestion.candidates.count > 1 || !suggestion.qualityIssues.isEmpty ? suggestion : nil
        selectedImage = suggestion.displayImage
        persistDisplayImage(suggestion.displayImage, original: original)

        aiSuggestedCategory = suggestion.category
        aiSuggestedItemType = suggestion.itemType
        aiSuggestedColors = suggestion.colorTags
        aiConfidence = suggestion.confidence

        var applied = false
        if category == nil, let suggestedCategory = suggestion.category {
            category = suggestedCategory
            applied = true
        }
        if itemType == nil, let suggestedType = suggestion.itemType {
            if let cat = category ?? suggestion.category, cat.itemTypes.contains(suggestedType) {
                itemType = suggestedType
                applied = true
            }
        }
        if applied { markAutoFilled("type") }
        if colorTags.isEmpty, !suggestion.colorTags.isEmpty {
            colorTags = suggestion.colorTags
            applied = true
            markAutoFilled("colors")
        }
        didApplyAISuggestions = applied || suggestion.usedCutout
        applyTypeDefaultsToState()
        if category == nil {
            // AI couldn't classify — open the category card so the one
            // required choice is right in front of the user.
            withAnimation(DS.Animation.standard) {
                focusedSection = .essentials
            }
        }
        if applied {
            DS.haptic(0.4)
        }
    }

    private func handleLabelScan(_ image: UIImage) {
        // The care label is worth keeping with the item (materials, washing).
        if selectedImage != nil, extraImages.count < Self.maxExtraImages {
            extraImages.append(image)
        }
        isScanningLabel = true
        labelScanMessage = nil
        Task {
            let result = await LabelScanService.scan(image: image)
            isScanningLabel = false

            var found: [String] = []
            if let scannedBrand = result.brand, brand.isEmpty {
                brand = scannedBrand
                markAutoFilled("brand")
                found.append(scannedBrand)
            }
            // The label beats a guessed usual size, never a size the user picked.
            if let size = result.size, sizeOption == nil || isAutoFilled("size"), shouldShowSize,
               let cat = category, SizeOption.options(for: cat).contains(size) {
                sizeOption = size
                autoValues["size"] = nil
                found.append(size.title)
            }
            if !result.materials.isEmpty, scannedMaterials.isEmpty {
                scannedMaterials = result.materials
                markAutoFilled("material")
                found.append(result.materials.map(\.title).joined(separator: ", "))
            }

            if found.isEmpty {
                labelScanMessage = String(localized: "label_scan_nothing")
            } else {
                labelScanMessage = String(
                    format: NSLocalizedString("label_scan_found_format", comment: ""),
                    found.joined(separator: " · ")
                )
                DS.haptic(0.5)
            }
        }
    }

    /// Reflect per-type defaults in the visible controls so the chips show
    /// exactly what will be saved. Never touches fields the user edited.
    private func applyTypeDefaultsToState() {
        prefillUsualSize()
        guard let type = itemType, let defaults = ItemTypeDefaults.defaults(for: type) else { return }
        if !userEditedFields.contains(ItemTypeDefaults.FieldKey.warmth) {
            warmth = defaults.warmth
        }
        if !userEditedFields.contains(ItemTypeDefaults.FieldKey.formality) {
            formality = defaults.formality
        }
        if !userEditedFields.contains(ItemTypeDefaults.FieldKey.season) {
            seasonSuitability = defaults.season
        }
    }

    /// The user's usual size for this category ("My sizes", else what their
    /// items say), marked ✨ so they confirm it like any other guess.
    private func prefillUsualSize() {
        guard sizeOption == nil, shouldShowSize, let category else { return }
        let profile = CurrentUser.activeProfile(in: context, createIfNeeded: false)
        let garments = (try? context.fetch(FetchDescriptor<Garment>())) ?? []
        guard let size = MySizesView.usualSize(for: category, profile: profile, garments: garments),
              SizeOption.options(for: category).contains(size) else { return }
        sizeOption = size
        markAutoFilled("size")
    }

    private func saveGarment() {
        guard let selectedCategory = category else { return }
        guard savedImagePath != nil || selectedImage != nil else {
            errorMessage = String(localized: "edit_image_save_failed")
            return
        }
        // Ensure paths exist even if AI path raced
        if savedImagePath == nil, let selectedImage {
            persistDisplayImage(selectedImage, original: originalPickedImage ?? selectedImage)
        }
        guard savedImagePath != nil else {
            errorMessage = String(localized: "edit_image_save_failed")
            return
        }

        let fitToSave = shouldShowFit ? fitTag : nil
        let sizeToSave = shouldShowSize ? sizeOption : nil

        let garment = Garment(
            category: selectedCategory,
            itemType: itemType,
            brand: brand.isEmpty ? nil : brand.trimmingCharacters(in: .whitespacesAndNewlines),
            colorTags: colorTags,
            userTitleOverride: userTitleOverride,
            patternTag: patternTag,
            fitTag: fitToSave,
            sizeOption: sizeToSave,
            seasonSuitability: seasonSuitability,
            minTempC: minTempC,
            maxTempC: maxTempC,
            warmth: warmth,
            formality: formality,
            imagePath: savedImagePath,
            thumbnailPath: savedThumbnailPath,
            originalImagePath: savedOriginalImagePath,
            aiSuggestedCategory: aiSuggestedCategory,
            aiSuggestedItemType: aiSuggestedItemType,
            aiSuggestedColors: aiSuggestedColors.isEmpty ? nil : aiSuggestedColors,
            aiConfidence: aiConfidence > 0 ? aiConfidence : nil,
            aiProcessedAt: didApplyAISuggestions ? Date() : nil
        )

        if selectedCategory == .top, let sleeveLength {
            garment.sleeveLength = sleeveLength
        }
        garment.additionalImagePaths = persistExtraImages()

        if !scannedMaterials.isEmpty {
            // From care label / product QR — treat as verified so AI enrichment won't overwrite.
            garment.materialTags = scannedMaterials
            garment.markUserEdited(ItemTypeDefaults.FieldKey.materialTags)
        }

        if let profile = CurrentUser.activeProfile(in: context, createIfNeeded: true) {
            garment.ownerID = profile.id
            if !profile.garmentIDs.contains(garment.id) {
                profile.garmentIDs.append(garment.id)
            }
        }

        // Provenance: visible fields the user never touched are owned by
        // enrichment (their values came from type defaults), so later AI
        // refinement may improve them.
        var enrichedVisibleFields: [String] = []
        if !userEditedFields.contains(ItemTypeDefaults.FieldKey.warmth) {
            enrichedVisibleFields.append(ItemTypeDefaults.FieldKey.warmth)
        }
        if !userEditedFields.contains(ItemTypeDefaults.FieldKey.formality) {
            enrichedVisibleFields.append(ItemTypeDefaults.FieldKey.formality)
        }
        if !userEditedFields.contains(ItemTypeDefaults.FieldKey.season), garment.seasonSuitability != nil {
            enrichedVisibleFields.append(ItemTypeDefaults.FieldKey.season)
        }
        garment.markEnriched(enrichedVisibleFields)

        garment.thermalWarmthOverride = thermalWarmthOverride
        garment.thermalBreathabilityOverride = thermalBreathabilityOverride

        // Instant offline enrichment for fields the form doesn't expose
        // (layer role, weather/style tags) plus anything still generic.
        GarmentEnrichmentService.applyDefaults(to: garment, userEditedFields: userEditedFields)

        context.insert(garment)

        do {
            try context.save()
            if let path = garment.imagePath {
                CloudKitImageSyncService.shared.enqueueUpload(garmentID: garment.id, imagePath: path)
            }
            if let trimmed = garment.brand, !trimmed.isEmpty {
                BrandStore.upsert(name: trimmed, context: context)
            }
            // On-device AI refinement in the background; respects provenance.
            Task {
                await GarmentEnrichmentService.enrichWithAI(garment, context: context)
            }
            onSave?(garment)
            showSuccess = true
            NotificationCenter.default.post(name: .garmentAdded, object: nil)
        } catch {
            errorMessage = String(
                format: NSLocalizedString("add_garment_save_failed_format", comment: ""),
                error.localizedDescription
            )
        }
    }

    private func resetAndDismiss() {
        category = nil
        itemType = nil
        brand = ""
        colorTags = []
        userTitleOverride = nil
        patternTag = nil
        fitTag = nil
        sizeOption = nil
        seasonSuitability = nil
        minTempC = nil
        maxTempC = nil
        warmth = 3
        thermalWarmthOverride = nil
        thermalBreathabilityOverride = nil
        formality = 3
        selectedImage = nil
        originalPickedImage = nil
        pendingCropImage = nil
        savedImagePath = nil
        savedThumbnailPath = nil
        savedOriginalImagePath = nil
        isAnalyzing = false
        didApplyAISuggestions = false
        aiConfidence = 0
        aiSuggestedCategory = nil
        aiSuggestedItemType = nil
        aiSuggestedColors = []
        aiSuggestedPattern = nil
        aiSuggestedFit = nil
        sleeveLength = nil
        cutoutSuggestion = nil
        isRefining = false
        aiGeneration = UUID()
        autoValues = [:]
        extraImages = []
        userEditedFields = []
        focusedSection = nil
        showAllDetails = false
        batchItems = []
        isSavingBatch = false
        isLookingUpBarcode = false
        isFetchingProductPage = false
        barcodeNeedsPhoto = false
        barcodeLookupGeneration = UUID()
        labelScanMessage = nil
        isScanningLabel = false
        scannedMaterials = []
        flowState = .selectImage
        if onSave != nil {
            dismiss()
        }
    }
}

#Preview {
    AddGarmentView()
}
