import SwiftUI
import UIKit

struct GarmentPhotoSearchView: View {
    let garment: Garment
    let onUse: (UIImage, URL, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var suggestions: [GarmentPhotoSuggestion] = []
    @State private var isSearching = true
    @State private var searchCatalog = true
    @State private var isImporting = false
    @State private var productLink = ""
    @State private var importID = 0
    @State private var message: String?
    @State private var selected: GarmentPhotoSuggestion?
    @State private var fullImage: UIImage?
    @State private var currentImage: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    if let selected {
                        review(selected)
                    } else {
                        searchContent
                    }
                }.padding(DS.Spacing.md)
            }
            .navigationTitle(String(localized: "photo_tool_find_photo"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel")) { dismiss() }
                }
            }
            .withLocalAppBackdropPainted()
        }
        .task(id: searchCatalog) {
            guard searchCatalog else { return }
            await findCatalogPhotos()
        }
        .task(id: importID) {
            guard importID > 0 else { return }
            await importLink()
        }
        .task(id: selected?.id) {
            fullImage = nil
            guard let selected else { return }
            do {
                let loaded = try await GarmentPhotoDiscovery.shared.fullImage(for: selected)
                guard !Task.isCancelled else { return }
                fullImage = loaded
            } catch {
                guard !Task.isCancelled else { return }
                message = String(localized: "photo_search_load_failed")
            }
        }
    }

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text(String(localized: "photo_search_explanation"))
                .font(.subheadline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text(String(localized: "photo_search_product_link")).font(.headline)
                TextField(String(localized: "photo_search_link_placeholder"), text: $productLink)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "photo_search_import_link")) {
                    searchCatalog = false
                    isSearching = false
                    importID += 1
                }
                    .disabled(productLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
                Button {
                    var components = URLComponents(string: "https://www.google.com/search")!
                    let words = [garment.brand, garment.itemType?.title ?? garment.category.title,
                                 garment.safeColorTags.first?.title].compactMap { $0 }.joined(separator: " ")
                    components.queryItems = [URLQueryItem(name: "tbm", value: "isch"), URLQueryItem(name: "q", value: words)]
                    if let url = components.url { openURL(url) }
                } label: {
                    Label(String(localized: "photo_search_web_action"), systemImage: "safari")
                }
                Text(String(localized: "photo_search_web_hint")).font(.caption).foregroundStyle(.secondary)
            }.padding(DS.Spacing.md).contentSurface()
            if isSearching || isImporting {
                ProgressView(String(localized: "photo_search_loading")).frame(maxWidth: .infinity)
            }
            if let message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
            if !suggestions.isEmpty {
                Text(String(localized: "photo_search_review_notice")).font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: DS.Spacing.sm)], spacing: DS.Spacing.sm) {
                    ForEach(suggestions) { suggestion in
                        Button { message = nil; selected = suggestion } label: {
                            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                                GarmentPhotoCanvas(image: suggestion.preview).aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile))
                                Text(suggestion.title).font(.caption.weight(.medium)).lineLimit(2)
                                Text(suggestion.sourceName).font(.caption2).foregroundStyle(.secondary)
                            }.padding(DS.Spacing.xs).contentSurface(cornerRadius: DS.Radius.tile)
                        }.buttonStyle(.plain).disabled(isSearching || isImporting)
                    }
                }
            }
        }
    }

    private func review(_ suggestion: GarmentPhotoSuggestion) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Button { selected = nil; message = nil } label: {
                Label(String(localized: "photo_search_back_results"), systemImage: "chevron.backward")
            }
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                VStack {
                    GarmentPhotoCanvas(image: currentImage).aspectRatio(1, contentMode: .fit)
                    Text(String(localized: "photo_search_current")).font(.caption)
                }
                VStack {
                    GarmentPhotoCanvas(image: fullImage ?? suggestion.preview).aspectRatio(1, contentMode: .fit)
                    Text(String(localized: "photo_search_suggested")).font(.caption)
                }
            }.padding(DS.Spacing.sm).contentSurface()
            Text(suggestion.title).font(.headline)
            Text(String(localized: "photo_search_review_notice")).font(.subheadline).foregroundStyle(.secondary)
            Link(suggestion.sourceName, destination: suggestion.sourceURL)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if fullImage == nil, message == nil { ProgressView() }
            Button(String(localized: "garment_photo_make_primary")) { use(suggestion, asPrimary: true) }
                .dsPrimaryButton().disabled(fullImage == nil)
            Button(String(localized: "photo_search_add_gallery")) { use(suggestion, asPrimary: false) }
                .frame(maxWidth: .infinity).disabled(fullImage == nil)
        }
    }

    private func use(_ suggestion: GarmentPhotoSuggestion, asPrimary: Bool) {
        guard let fullImage else { return }
        onUse(fullImage, suggestion.sourceURL, asPrimary)
        dismiss()
    }

    @MainActor private func loadCurrentPhoto() async -> UIImage? {
        let path = garment.imagePath, data = garment.imageData
        let image = await Task.detached(priority: .utility) {
            ImageStore.loadGarmentPreview(imagePath: path, legacyData: data, maxPixelSize: 600)
        }.value
        guard !Task.isCancelled else { return nil }
        currentImage = image
        return image
    }

    @MainActor private func findCatalogPhotos() async {
        let image = await loadCurrentPhoto()
        guard !Task.isCancelled else { return }
        await ShopCatalogService.shared.refreshIfNeeded()
        guard !Task.isCancelled else { return }
        let brand = garment.brand?.lowercased() ?? ""
        let type = garment.itemType
        let colors = Set(garment.safeColorTags)
        let products = ShopCatalogService.shared.products.filter {
            $0.category == garment.category && $0.imageURL != nil && $0.item.gender != "kids"
        }.sorted { left, right in
            func score(_ product: ShopProduct) -> Int {
                (type != nil && product.itemType == type ? 4 : 0)
                + (!brand.isEmpty && product.item.brand?.lowercased() == brand ? 8 : 0)
                + (!colors.isDisjoint(with: product.colors) ? 3 : 0)
            }
            let l = score(left), r = score(right)
            return l == r ? left.id < right.id : l > r
        }
        let found = await GarmentPhotoDiscovery.shared.similarPhotos(to: image, products: Array(products.prefix(12)))
        guard !Task.isCancelled else { return }
        suggestions = found
        isSearching = false
        if found.isEmpty { message = String(localized: "photo_search_empty") }
    }

    @MainActor private func importLink() async {
        guard let url = ProductPageMetadataService.productPageURL(from: productLink) else {
            message = String(localized: "photo_search_invalid_link"); return
        }
        isImporting = true
        message = nil
        defer { isImporting = false }
        do {
            // Manual import can cancel discovery before its comparison photo is ready.
            if currentImage == nil { _ = await loadCurrentPhoto() }
            try Task.checkCancellation()
            let found = try await GarmentPhotoDiscovery.shared.photos(from: url)
            guard !Task.isCancelled else { return }
            suggestions = found
            if found.isEmpty { message = String(localized: "photo_search_empty") }
        } catch {
            guard !Task.isCancelled else { return }
            message = String(localized: "photo_search_load_failed")
        }
    }
}
