import SwiftUI

/// Purchase context from the retailer, with personal fit kept separate from price evidence.
struct ShopProductDetailsView: View {
    let pick: PurchaseScorer.Pick
    let isSaved: Bool
    let onOpen: () -> Void
    let onToggleSave: () -> Void
    let onDismiss: () -> Void
    let onBought: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var product: ShopProduct { pick.product }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    ShopProductGallery(product: product)
                    summary
                    personalFit
                    sourceDetails
                    availability
                    shopNote
                    secondaryActions
                }
                .padding(DS.Spacing.md)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(String(localized: "shop_details_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action_close")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { openInShop }
        }
        .withLocalAppBackdropPainted()
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(sourceLine).font(.subheadline).foregroundStyle(.secondary)
            Text(product.title).font(.title3.weight(.semibold)).textSelection(.enabled)
            price
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceLine: String {
        guard let brand = sourceText(product.item.brand),
              brand.caseInsensitiveCompare(product.storeName) != .orderedSame else { return product.storeName }
        return "\(product.storeName) · \(brand)"
    }

    private var price: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                Text(product.priceText ?? String(localized: "shop_details_price_unknown"))
                    .font(.title2.weight(.semibold))
                if let original = product.originalPriceText {
                    Text(original).strikethrough().font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let percent = product.discountPercent {
                Text(ShopPicksEngine.reasonText(.onSale(percent)))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                if let current = product.price, let original = product.originalPrice {
                    let saved = (original - current).formatted(.currency(code: product.item.currency ?? "ILS"))
                    Text(String(format: String(localized: "shop_details_savings_format"), saved))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var personalFit: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ShopMatchBadge(match: pick.match)
            if let wears = ShopPicksEngine.wearsText(pick) {
                Label(wears, systemImage: "repeat")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Color.accentColor)
            }
            ForEach(personalReasons, id: \.self) { reason in
                Text(ShopPicksEngine.reasonText(reason))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface()
    }

    private var personalReasons: [PurchaseScorer.Reason] {
        pick.reasons.filter {
            switch $0 {
            case .checkSize, .onSale: return false
            default: return true
            }
        }
    }

    private var sourceDetails: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(String(localized: "shop_details_about")).font(.headline)
            detailRow("shop_details_type", value: product.itemType.flatMap { $0 == .other ? nil : $0.title } ?? product.category.title)
            if let color = sourceText(product.item.color) {
                detailRow("shop_details_color", value: color)
            }
            if let material = sourceText(product.item.material) {
                detailRow("shop_details_material", value: material)
            }
            if let fit = ProductFieldMapper.mapFit([product.item.title, product.item.description].compactMap { $0 }.joined(separator: " ")) {
                detailRow("shop_details_fit", value: fit.title)
            }
            if let description = sourceText(product.item.description) {
                Divider()
                Text(String(localized: "shop_details_description"))
                    .font(.subheadline.weight(.semibold))
                Text(description).font(.subheadline).textSelection(.enabled)
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface()
    }

    private var availability: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            let stockSizes = sourceSizes(product.item.inStockSizes)
            let listedSizes = sourceSizes(product.item.sizes)
            if product.item.available == false {
                Text(String(localized: "shop_details_stock_unavailable")).font(.subheadline.weight(.semibold))
            } else if !stockSizes.isEmpty, product.item.sizeAvailabilityKnown != false {
                detailRow("shop_details_sizes_in_stock", value: stockSizes.joined(separator: " · "))
            } else if product.hasKnownSizeAvailability {
                Text(String(localized: "shop_details_sizes_empty")).font(.subheadline)
            } else {
                Text(String(localized: "shop_details_sizes_unknown")).font(.subheadline)
            }
            if !listedSizes.isEmpty, listedSizes != stockSizes {
                detailRow("shop_details_sizes_listed", value: listedSizes.joined(separator: " · "))
            }
            Text(String(localized: "shop_reason_check_size"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface()
    }

    private var shopNote: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            if let date = product.fetchedAt {
                Text(String(format: String(localized: "shop_details_checked_format"), date.formatted(date: .abbreviated, time: .omitted)))
            }
            Text(String(localized: "shop_details_shop_check"))
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var openInShop: some View {
        Button(action: onOpen) {
            Label(String(localized: "shop_action_open"), systemImage: "arrow.up.right.square")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.xs)
        .background(.regularMaterial)
    }

    private var secondaryActions: some View {
        VStack(spacing: DS.Spacing.xs) {
            Button(action: onToggleSave) {
                Label(String(localized: isSaved ? "shop_action_unsave" : "shop_action_save"), systemImage: isSaved ? "heart.fill" : "heart")
                    .foregroundStyle(isSaved ? Color.pink : Color.accentColor)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            Button {
                dismiss()
                onBought()
            } label: {
                Label(String(localized: "shop_action_bought"), systemImage: "bag.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            Button {
                dismiss()
                onDismiss()
            } label: {
                Label(String(localized: "shop_action_dismiss"), systemImage: "hand.thumbsdown")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .buttonStyle(.borderless)
        .font(.subheadline)
    }

    private func detailRow(_ key: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(key).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline).textSelection(.enabled)
        }
    }

    private func sourceSizes(_ raw: [String]?) -> [String] {
        var seen = Set<String>()
        return (raw ?? []).compactMap { sourceText($0) }.filter { seen.insert($0.lowercased()).inserted }
    }

    private func sourceText(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

private struct ShopProductGallery: View {
    let product: ShopProduct
    @State private var selection = 0
    @State private var fullScreenPhoto: ShopPhotoSelection?

    private var urls: [URL] {
        var seen = Set<String>()
        return ([product.imageURL?.absoluteString].compactMap { $0 } + (product.item.images ?? [])).compactMap { raw in
            guard var parts = URLComponents(string: raw),
                  ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
                  let host = parts.host, !host.isEmpty,
                  parts.user == nil, parts.password == nil else { return nil }
            parts.fragment = nil
            guard let url = parts.url, seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    var body: some View {
        let photos = urls
        VStack(spacing: DS.Spacing.xs) {
            if photos.isEmpty {
                ShopProductImage(product: product, preferProductOnly: false)
                    .frame(height: 340)
            } else {
                TabView(selection: $selection) {
                    ForEach(photos.indices, id: \.self) { index in
                        ShopCatalogPhoto(url: photos[index], isActive: fullScreenPhoto == nil && abs(index - selection) <= 1,
                            maxSide: 1200, placeholder: product.category.icon,
                            onOpen: { selection = index; fullScreenPhoto = ShopPhotoSelection(index: index) })
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 360)
                Text(String(format: String(localized: "shop_details_photos_format"), selection + 1, photos.count))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .fullScreenCover(item: $fullScreenPhoto) { _ in
            ShopProductPhotoViewer(urls: photos, title: product.title, placeholder: product.category.icon, selection: $selection)
        }
    }
}

private struct ShopPhotoSelection: Identifiable {
    let index: Int
    var id: Int { index }
}

private struct ShopProductPhotoViewer: View {
    let urls: [URL]
    let title: String
    let placeholder: String
    @Binding var selection: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Spacing.xs) {
                TabView(selection: $selection) {
                    ForEach(urls.indices, id: \.self) { index in
                        ShopCatalogPhoto(url: urls[index], isActive: abs(index - selection) <= 1, maxSide: 1600, placeholder: placeholder)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                Text(String(format: String(localized: "shop_details_photos_format"), selection + 1, urls.count))
                    .font(.caption).monospacedDigit().padding(.bottom, DS.Spacing.md)
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action_close")) { dismiss() }
                }
            }
        }
    }
}

/// Decoding and networking remain in the shared worker; off-screen pages release their image.
private struct ShopCatalogPhoto: View {
    let url: URL
    let isActive: Bool
    let maxSide: Int
    let placeholder: String
    var onOpen: (() -> Void)? = nil
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var retry = 0

    private var taskID: String { "\(url.absoluteString)|\(isActive)|\(maxSide)|\(retry)" }

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                let photo = Image(uiImage: image).resizable().scaledToFit().padding(DS.Spacing.xxs)
                if let onOpen {
                    Button(action: onOpen) { photo }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "shop_details_view_photo"))
                } else {
                    photo
                }
            } else if isLoading, isActive {
                ProgressView().accessibilityLabel(String(localized: "shop_loading"))
            } else {
                VStack(spacing: DS.Spacing.xs) {
                    Image(systemName: placeholder).font(.title2).foregroundStyle(.secondary)
                    if isActive {
                        Button { retry += 1 } label: {
                            Label(String(localized: "shop_photo_retry"), systemImage: "arrow.clockwise")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .task(id: taskID) {
            image = nil
            guard isActive else { isLoading = false; return }
            isLoading = true
            defer { if !Task.isCancelled { isLoading = false } }
            if retry > 0 { try? await Task.sleep(for: .seconds(2)) }
            guard !Task.isCancelled else { return }
            let stream = await ShopProductPhotoService.shared.images(for: url, maxSide: maxSide)
            for await photo in stream {
                guard !Task.isCancelled else { return }
                image = photo
            }
        }
    }
}
