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

    /// Avoid hammering `CKContainer.accountStatus` on every foreground / bootstrap tick.
    private var lastAccountRefreshAt: Date = .distantPast
    private let accountRefreshMinInterval: TimeInterval = 300

    /// Coalesce rapid CloudKit event flips (syncing ↔ synced) into one UI publish.
    private var pendingStatus: Status?
    private var statusDebounceTask: Task<Void, Never>?
    private let statusDebounceNanoseconds: UInt64 = 1_500_000_000

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

        Task { await refreshAccountStatus(force: true) }
    }

    func refreshAccountStatus(force: Bool = false) async {
        let now = Date()
        if !force, now.timeIntervalSince(lastAccountRefreshAt) < accountRefreshMinInterval {
            return
        }
        lastAccountRefreshAt = now

        do {
            let accountStatus = try await CKContainer.default().accountStatus()
            switch accountStatus {
            case .available:
                updateIfChanged(&availabilityMessage, "")
                if case .notAvailable = status {
                    publishStatus(.synced, immediate: true)
                }
            case .noAccount:
                updateIfChanged(&availabilityMessage, "No iCloud account is signed in.")
                publishStatus(.notAvailable, immediate: true)
            case .restricted:
                updateIfChanged(&availabilityMessage, "iCloud access is restricted.")
                publishStatus(.notAvailable, immediate: true)
            case .couldNotDetermine:
                updateIfChanged(&availabilityMessage, "iCloud status could not be determined.")
                publishStatus(.notAvailable, immediate: true)
            case .temporarilyUnavailable:
                updateIfChanged(&availabilityMessage, "iCloud is temporarily unavailable.")
                publishStatus(.notAvailable, immediate: true)
            @unknown default:
                updateIfChanged(&availabilityMessage, "iCloud status is unknown.")
                publishStatus(.notAvailable, immediate: true)
            }
        } catch {
            updateIfChanged(&availabilityMessage, "iCloud status error.")
            publishStatus(.error(error.localizedDescription), immediate: true)
            debugLog("CloudKit account status error: \(error.localizedDescription)")
        }
    }

    private func handleCloudKitEvent(_ notification: Notification) {
        guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }

        if event.endDate == nil {
            publishStatus(.syncing, immediate: false)
            debugLog("CloudKit sync started: \(String(describing: event.type))")
            return
        }

        if let error = event.error {
            publishStatus(.error(error.localizedDescription), immediate: true)
            debugLog("CloudKit sync error: \(error.localizedDescription)")
        } else {
            publishStatus(.synced, immediate: false)
            debugLog("CloudKit sync ended: \(String(describing: event.type))")
        }
    }

    private func publishStatus(_ newValue: Status, immediate: Bool) {
        if immediate {
            statusDebounceTask?.cancel()
            statusDebounceTask = nil
            pendingStatus = nil
            updateIfChanged(&status, newValue)
            return
        }

        pendingStatus = newValue
        statusDebounceTask?.cancel()
        statusDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: statusDebounceNanoseconds)
            guard !Task.isCancelled, let pending = pendingStatus else { return }
            pendingStatus = nil
            updateIfChanged(&status, pending)
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
