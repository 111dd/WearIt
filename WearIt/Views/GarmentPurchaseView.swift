import SwiftUI
import SwiftData
import PhotosUI
import ImageIO

/// Optional receipt stays with the garment in the user's private synced store.
struct GarmentPurchaseView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let garment: Garment
    @State private var store: String
    @State private var date: Date
    @State private var hasDate: Bool
    @State private var receipt: Data?
    @State private var preview: UIImage?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var cameraImage: UIImage?
    @State private var showCamera = false
    @State private var isPreparing = false
    @State private var failed = false
    @State private var receiptVersion = 0

    init(garment: Garment) {
        self.garment = garment
        _store = State(initialValue: garment.purchaseStore ?? "")
        _date = State(initialValue: garment.purchasedAt ?? Date())
        _hasDate = State(initialValue: garment.purchasedAt != nil)
        _receipt = State(initialValue: garment.purchaseReceiptData)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "purchase_store"), text: $store)
                    Toggle(String(localized: "purchase_date_known"), isOn: $hasDate)
                    if hasDate {
                        DatePicker(String(localized: "purchase_date"), selection: $date, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    }
                    if let raw = garment.shopProductURL, let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? "") {
                        Link(String(localized: "purchase_product_page"), destination: url)
                    }
                } footer: {
                    Text(String(localized: garment.purchaseSourceRaw == "appConfirmation" ? "purchase_date_recorded_detail" : "purchase_details_optional"))
                }
                Section {
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 320)
                    }
                    if isPreparing { ProgressView(String(localized: "purchase_receipt_preparing")) }
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label(String(localized: "purchase_receipt_add"), systemImage: "photo")
                    }
                    .disabled(isPreparing)
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { showCamera = true } label: {
                            Label(String(localized: "purchase_receipt_camera"), systemImage: "camera")
                        }
                        .disabled(isPreparing)
                    }
                    if receipt != nil {
                        Button(String(localized: "purchase_receipt_remove"), role: .destructive) {
                            receipt = nil; preview = nil; selectedPhoto = nil; cameraImage = nil
                        }
                        .disabled(isPreparing)
                    }
                } header: {
                    Text(String(localized: "purchase_receipt"))
                } footer: {
                    Text(String(localized: "purchase_receipt_detail"))
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(String(localized: "purchase_details"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action_save")) { save() }.disabled(isPreparing)
                }
            }
            .alert(String(localized: "error_title"), isPresented: $failed) {
                Button(String(localized: "action_ok"), role: .cancel) {}
            } message: { Text(String(localized: "purchase_save_failed")) }
            .sheet(isPresented: $showCamera) {
                CameraPickerWrapper { image in
                    cameraImage = image; selectedPhoto = nil; receiptVersion += 1
                }
            }
            .onChange(of: selectedPhoto) { _, item in
                if item != nil { cameraImage = nil; receiptVersion += 1 }
            }
            .task(id: receiptVersion) { await prepareReceipt() }
        }
        .withLocalAppBackdropPainted()
    }

    @MainActor
    private func prepareReceipt() async {
        isPreparing = true
        defer { if !Task.isCancelled { isPreparing = false } }
        do {
            let source: Data?
            if let selectedPhoto { source = try await selectedPhoto.loadTransferable(type: Data.self) }
            else { source = receipt }
            if selectedPhoto != nil && source == nil { throw URLError(.cannotDecodeContentData) }
            let camera = cameraImage
            guard source != nil || camera != nil else { return }
            let worker = Task.detached(priority: .utility) { () throws -> (Data, UIImage) in
                try Task.checkCancellation()
                let data: Data
                if let camera, let encoded = camera.jpegData(compressionQuality: 0.88) { data = encoded }
                else if let source { data = source }
                else { throw URLError(.cannotDecodeContentData) }
                guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2000,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
                let image = UIImage(cgImage: cg)
                guard let compressed = image.jpegData(compressionQuality: 0.85) else { throw URLError(.cannotDecodeContentData) }
                try Task.checkCancellation()
                return (compressed, image)
            }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            // Opening an existing receipt only decodes the preview; don't recompress it on every save.
            if selectedPhoto != nil || camera != nil { receipt = result.0 }
            preview = result.1
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }

    private func save() {
        guard !garment.isDeleted, garment.modelContext != nil else { failed = true; return }
        let old = (garment.purchaseStore, garment.purchasedAt, garment.purchaseReceiptData, garment.purchaseSourceRaw)
        let newStore = store.trimmingCharacters(in: .whitespacesAndNewlines)
        garment.purchaseStore = newStore.isEmpty ? nil : newStore
        garment.purchasedAt = hasDate ? date : nil
        garment.purchaseReceiptData = receipt
        if old.0 != garment.purchaseStore || old.1 != garment.purchasedAt { garment.purchaseSourceRaw = "manual" }
        do { try context.save(); dismiss() }
        catch {
            garment.purchaseStore = old.0; garment.purchasedAt = old.1
            garment.purchaseReceiptData = old.2; garment.purchaseSourceRaw = old.3
            failed = true
        }
    }
}
