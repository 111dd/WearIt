import Foundation
import CloudKit
import CoreData
import os
import UIKit

@MainActor
final class CloudKitSyncMonitor: ObservableObject {
    static let shared = CloudKitSyncMonitor()

    enum Status: Equatable {
        case notAvailable
        case syncing
        case synced
        case error(String)
    }

    @Published private(set) var status: Status = .notAvailable
    @Published private(set) var availabilityMessage: String = ""

    private let logger = Logger(subsystem: "WearIt", category: "CloudKit")

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleCloudKitEvent(notification)
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAccountStatus()
            }
        }

        Task { await refreshAccountStatus() }
    }

    func refreshAccountStatus() async {
        do {
            let accountStatus = try await CKContainer.default().accountStatus()
            switch accountStatus {
            case .available:
                updateIfChanged(&availabilityMessage, "")
                if case .notAvailable = status {
                    updateIfChanged(&status, .synced)
                }
            case .noAccount:
                updateIfChanged(&availabilityMessage, "No iCloud account is signed in.")
                updateIfChanged(&status, .notAvailable)
            case .restricted:
                updateIfChanged(&availabilityMessage, "iCloud access is restricted.")
                updateIfChanged(&status, .notAvailable)
            case .couldNotDetermine:
                updateIfChanged(&availabilityMessage, "iCloud status could not be determined.")
                updateIfChanged(&status, .notAvailable)
            case .temporarilyUnavailable:
                updateIfChanged(&availabilityMessage, "iCloud is temporarily unavailable.")
                updateIfChanged(&status, .notAvailable)
            @unknown default:
                updateIfChanged(&availabilityMessage, "iCloud status is unknown.")
                updateIfChanged(&status, .notAvailable)
            }
        } catch {
            updateIfChanged(&availabilityMessage, "iCloud status error.")
            updateIfChanged(&status, .error(error.localizedDescription))
            debugLog("CloudKit account status error: \(error.localizedDescription)")
        }
    }

    private func handleCloudKitEvent(_ notification: Notification) {
        guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }

        if event.endDate == nil {
            updateIfChanged(&status, .syncing)
            debugLog("CloudKit sync started: \(String(describing: event.type))")
            return
        }

        if let error = event.error {
            updateIfChanged(&status, .error(error.localizedDescription))
            debugLog("CloudKit sync error: \(error.localizedDescription)")
        } else {
            updateIfChanged(&status, .synced)
            debugLog("CloudKit sync ended: \(String(describing: event.type))")
        }
    }

    private func updateIfChanged<T: Equatable>(_ target: inout T, _ newValue: T) {
        if target != newValue {
            target = newValue
        }
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        logger.debug("\(message, privacy: .private)")
        #endif
    }
}
