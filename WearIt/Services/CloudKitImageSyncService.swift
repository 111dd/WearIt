import Foundation
import CloudKit
import os

@MainActor
final class CloudKitImageSyncService {
    static let shared = CloudKitImageSyncService()

    private let database = CKContainer.default().privateCloudDatabase
    private let logger = Logger(subsystem: "WearIt", category: "CloudKitImages")

    private var inFlightUploads: Set<String> = []
    private var inFlightDownloads: Set<String> = []

    private init() {}

    func enqueueUpload(garmentID: UUID, imagePath: String?) {
        guard let imagePath else { return }
        let recordName = recordName(for: garmentID)
        guard !inFlightUploads.contains(recordName) else { return }
        inFlightUploads.insert(recordName)

        Task.detached(priority: .utility) { [database] in
            defer {
                Task { @MainActor in
                    CloudKitImageSyncService.shared.inFlightUploads.remove(recordName)
                }
            }

            guard let fileURL = ImageStore.absoluteURL(path: imagePath),
                  FileManager.default.fileExists(atPath: fileURL.path) else {
                return
            }

            let recordID = CKRecord.ID(recordName: recordName)
            let record = CKRecord(recordType: "GarmentImage", recordID: recordID)
            record["image"] = CKAsset(fileURL: fileURL)

            do {
                _ = try await database.save(record)
                #if DEBUG
                await MainActor.run {
                    CloudKitImageSyncService.shared.logger.debug("Uploaded image asset for \(recordName, privacy: .private)")
                }
                #endif
            } catch {
                #if DEBUG
                await MainActor.run {
                    CloudKitImageSyncService.shared.logger.debug("Image upload failed for \(recordName, privacy: .private): \(error.localizedDescription, privacy: .private)")
                }
                #endif
            }
        }
    }

    func ensureLocalMainImage(
        garmentID: UUID,
        imagePath: String?,
        thumbnailPath: String?,
        updateThumbnail: @escaping (String?) -> Void = { _ in }
    ) {
        guard let imagePath else { return }
        guard !ImageStore.fileExists(path: imagePath) else { return }

        let recordName = recordName(for: garmentID)
        guard !inFlightDownloads.contains(recordName) else { return }
        inFlightDownloads.insert(recordName)

        Task.detached(priority: .utility) { [database] in
            defer {
                Task { @MainActor in
                    CloudKitImageSyncService.shared.inFlightDownloads.remove(recordName)
                }
            }

            let recordID = CKRecord.ID(recordName: recordName)
            do {
                let record = try await database.record(for: recordID)
                guard let asset = record["image"] as? CKAsset,
                      let url = asset.fileURL else { return }

                let data = try Data(contentsOf: url)
                guard ImageStore.write(data: data, toRelativePath: imagePath) else { return }

                let thumbExists = thumbnailPath.map { ImageStore.fileExists(path: $0) } ?? false
                if !thumbExists {
                    let newThumb = ImageStore.generateAndSaveThumbnail(
                        for: imagePath,
                        maxPixelSize: ImageStore.thumbnailMaxPixelSize
                    )
                    await MainActor.run {
                        updateThumbnail(newThumb)
                    }
                }

                #if DEBUG
                await MainActor.run {
                    CloudKitImageSyncService.shared.logger.debug("Downloaded image asset for \(recordName, privacy: .private)")
                }
                #endif
            } catch {
                #if DEBUG
                await MainActor.run {
                    CloudKitImageSyncService.shared.logger.debug("Image download failed for \(recordName, privacy: .private): \(error.localizedDescription, privacy: .private)")
                }
                #endif
            }
        }
    }

    private func recordName(for garmentID: UUID) -> String {
        "garment-\(garmentID.uuidString)-main"
    }
}
