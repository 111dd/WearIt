import Foundation
import SwiftData

/// Save the garment first. Downloads never delay the purchase action or touch a deleted item.
@MainActor
final class ShopPurchaseImporter {
    static let shared = ShopPurchaseImporter()
    private var photoTasks: [UUID: Task<Void, Never>] = [:]

    struct Result {
        let garment: Garment
        let inserted: Bool
        var previousFacts: Facts? = nil
        var recordedFacts: Facts? = nil
    }

    struct Facts: Equatable {
        let productID: String?
        let productURL: String?
        let store: String?
        let date: Date?
        let source: String?
        init(_ garment: Garment) {
            productID = garment.shopProductID; productURL = garment.shopProductURL
            store = garment.purchaseStore; date = garment.purchasedAt; source = garment.purchaseSourceRaw
        }
        func restore(_ garment: Garment, onlyMatching expected: Facts? = nil) {
            if expected == nil || garment.shopProductID == expected?.productID { garment.shopProductID = productID }
            if expected == nil || garment.shopProductURL == expected?.productURL { garment.shopProductURL = productURL }
            if expected == nil || garment.purchaseStore == expected?.store { garment.purchaseStore = store }
            if expected == nil || garment.purchasedAt == expected?.date { garment.purchasedAt = date }
            if expected == nil || garment.purchaseSourceRaw == expected?.source { garment.purchaseSourceRaw = source }
        }
    }

    func add(_ product: ShopProduct, profile: UserProfile?, context: ModelContext) throws -> Result {
        let productID = product.id
        let matches = try context.fetch(FetchDescriptor<Garment>(predicate: #Predicate { $0.shopProductID == productID }))
        let exact = matches.first(where: { $0.ownerID == nil || $0.ownerID == profile?.id })
        let wardrobe = try context.fetch(FetchDescriptor<Garment>()).filter { $0.ownerID == nil || $0.ownerID == profile?.id }
        let legacy = wardrobe.first { item in
            // Different explicit product IDs can be different variants: never merge them.
            guard item.shopProductID == nil, item.category == product.category else { return false }
            let sources = [item.shopProductURL].compactMap { $0 } + item.photoMetadata.values.compactMap(\.sourceURL)
            return sources.contains { URL(string: $0).map(Self.sourceKey) == Self.sourceKey(product.url) }
        }
        if let existing = exact ?? legacy {
            let previous = Facts(existing)
            existing.shopProductID = existing.shopProductID ?? product.id
            existing.shopProductURL = existing.shopProductURL ?? product.url.absoluteString
            existing.purchaseStore = existing.purchaseStore ?? product.storeName
            if existing.purchasedAt == nil {
                existing.purchasedAt = Date()
                existing.purchaseSourceRaw = "appConfirmation"
            }
            do { if previous != Facts(existing) { try context.save() } }
            catch { previous.restore(existing); throw error }
            return Result(garment: existing, inserted: false, previousFacts: previous, recordedFacts: Facts(existing))
        }
        let garment = PurchaseScorer.transientGarment(for: product)
        garment.shopProductID = product.id
        garment.shopProductURL = product.url.absoluteString
        garment.purchaseStore = product.storeName
        garment.purchasedAt = Date()
        garment.purchaseSourceRaw = "appConfirmation"
        garment.ownerID = profile?.id
        garment.createdAt = Date()
        garment.userTitleOverride = product.title
        if let size = MySizesView.usualSize(for: product.category, profile: profile, garments: wardrobe),
           product.inStockSizes.contains(size), product.category != .accessory {
            garment.sizeOption = size
            garment.aiEnrichedFieldsRaw = (garment.aiEnrichedFieldsRaw ?? []) + ["sizeOption"]
        }
        let previousIDs = profile?.garmentIDs ?? []
        context.insert(garment)
        profile?.garmentIDs.append(garment.id)
        do { try context.save() }
        catch {
            profile?.garmentIDs = previousIDs
            context.delete(garment)
            throw error
        }
        loadPhoto(for: garment.id, product: product, context: context)
        return Result(garment: garment, inserted: true)
    }

    func undo(_ result: Result, profile: UserProfile?, context: ModelContext) throws {
        let garment = result.garment
        guard !garment.isDeleted, garment.modelContext != nil else { return }
        if !result.inserted {
            let current = Facts(garment)
            result.previousFacts?.restore(garment, onlyMatching: result.recordedFacts)
            do { try context.save() }
            catch { current.restore(garment); throw error }
            return
        }
        let id = garment.id
        let paths = garment.allPhotoFilePaths
        let previousIDs = profile?.garmentIDs ?? []
        context.delete(garment)
        profile?.garmentIDs.removeAll { $0 == id }
        do { try context.save() }
        catch {
            context.insert(garment)
            profile?.garmentIDs = previousIDs
            throw error
        }
        photoTasks.removeValue(forKey: id)?.cancel()
        Task { await GarmentImagePersistence.shared.remove(paths: Array(paths)) }
    }

    /// Recover purchase facts for existing linked garments only. Never guess from a brand/name,
    /// and never insert historical purchases merely because they were once marked bought.
    func restoreKnownPurchases(garments: [Garment], profileID: UUID?, feedback: ShopFeedbackStore,
        products: [ShopProduct], context: ModelContext) {
        let bought = feedback.state.actions.compactMap { id, actions -> (String, Date, ShopCatalogItem)? in
            guard let date = actions[.bought], let item = feedback.keptItem(id) else { return nil }
            return (id, date, item)
        }
        guard !bought.isEmpty else { return }
        let byID = Dictionary(bought.map { ($0.0, $0) }, uniquingKeysWith: { first, _ in first })
        let byURL = Dictionary(bought.compactMap { purchase in URL(string: purchase.2.url).map { (Self.sourceKey($0), purchase) } }, uniquingKeysWith: { first, _ in first })
        let stores = Dictionary(products.map { ($0.item.store, $0.storeName) }, uniquingKeysWith: { first, _ in first })
        var changed: [(Garment, Facts)] = []
        for garment in garments where garment.ownerID == nil || garment.ownerID == profileID {
            let purchase: (String, Date, ShopCatalogItem)?
            if let id = garment.shopProductID { purchase = byID[id] }
            else {
                let links = [garment.shopProductURL].compactMap { $0 } + garment.photoMetadata.values.compactMap(\.sourceURL)
                let matches = links.compactMap { URL(string: $0).flatMap { byURL[Self.sourceKey($0)] } }
                purchase = Set(matches.map { $0.0 }).count == 1 ? matches.first : nil
            }
            guard let purchase else { continue }
            let previous = Facts(garment)
            garment.shopProductID = garment.shopProductID ?? purchase.0
            garment.shopProductURL = garment.shopProductURL ?? purchase.2.url
            if garment.purchaseSourceRaw != "manual" {
                garment.purchaseStore = garment.purchaseStore ?? stores[purchase.2.store] ?? purchase.2.store
                if garment.purchasedAt == nil {
                    garment.purchasedAt = purchase.1; garment.purchaseSourceRaw = "appConfirmation"
                }
            }
            if previous != Facts(garment) { changed.append((garment, previous)) }
        }
        guard !changed.isEmpty else { return }
        do { try context.save() }
        catch { for (garment, previous) in changed { previous.restore(garment) } }
    }

    private static func sourceKey(_ url: URL) -> String {
        // Preserve variant-bearing query parameters. Only ignore a trailing slash/fragment.
        let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        return (url.host?.lowercased() ?? "") + path + (url.query.map { "?" + $0 } ?? "")
    }

    private func loadPhoto(for id: UUID, product: ShopProduct, context: ModelContext) {
        photoTasks[id]?.cancel()
        photoTasks[id] = Task { @MainActor in
            defer { photoTasks[id] = nil }
            let processing = Task { await ShopPurchasePhotoWorker.shared.prepare(product) }
            let files = await withTaskCancellationHandler { await processing.value } onCancel: { processing.cancel() }
            guard let files else { return }
            let descriptor = FetchDescriptor<Garment>(predicate: #Predicate { $0.id == id })
            guard !Task.isCancelled, let item = try? context.fetch(descriptor).first,
                  !item.isDeleted, item.imagePath == nil else {
                await GarmentImagePersistence.shared.remove(paths: files.paths)
                return
            }
            let oldMetadata = item.photoMetadataRaw
            item.imagePath = files.image
            item.originalImagePath = files.original
            item.thumbnailPath = files.thumbnail
            item.setPhotoInfo(GarmentPhotoMetadata(originalPath: files.original, thumbnailPath: files.thumbnail,
                sourceURL: product.url.absoluteString), for: files.image)
            do { try context.save() }
            catch {
                item.imagePath = nil; item.originalImagePath = nil; item.thumbnailPath = nil
                item.photoMetadataRaw = oldMetadata
                await GarmentImagePersistence.shared.remove(paths: files.paths)
                return
            }
            // The purchase notice offers Undo for ten seconds; avoid an orphan cloud upload.
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, !item.isDeleted, item.modelContext != nil, item.imagePath == files.image else { return }
            CloudKitImageSyncService.shared.enqueueUpload(garmentID: id, imagePath: files.image)
        }
    }
}

private actor ShopPurchasePhotoWorker {
    static let shared = ShopPurchasePhotoWorker()

    func prepare(_ product: ShopProduct) async -> GarmentImagePersistence.Files? {
        guard let image = await ShopProductPhotoService.wardrobePhoto(for: product), !Task.isCancelled else { return nil }
        let display = GarmentCutoutService.analyze(image, preferredCategory: product.category)?.selected.image ?? image
        guard !Task.isCancelled else { return nil }
        return try? await GarmentImagePersistence.shared.persist(display: display, original: image)
    }
}
