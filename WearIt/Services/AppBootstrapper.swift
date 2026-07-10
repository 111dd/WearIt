import Foundation
import SwiftData
import os

@MainActor
final class AppBootstrapper: ObservableObject {
    enum State {
        case idle
        case loading
        case ready(ModelContainer)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var statusMessage: String = String(localized: "loading_preparing")

    private let log = Logger(subsystem: "com.dordavid.WearIt", category: "Bootstrap")
    private var started = false

    func startIfNeeded() {
        guard !started else { return }
        started = true
        state = .loading
        Task {
            await loadContainer()
        }
    }

    private func loadContainer() async {
        statusMessage = String(localized: "loading_preparing")

        let schema = Schema([
            Garment.self,
            Outfit.self,
            RecoState.self,
            RecommendationEvent.self,
            DismissedOutfit.self,
            UserProfile.self,
            TasteProfile.self,
            DailyLook.self,
            OutfitFeedback.self,
            DayPlan.self,
            NotificationPreferences.self,
            Brand.self,
            WearEvent.self
        ])

        let storeURL: URL = {
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return base?.appending(path: "WearIt.store") ?? URL(fileURLWithPath: "/tmp/WearIt.store")
        }()

        let cfg = ModelConfiguration(
            url: storeURL,
            cloudKitDatabase: .private("iCloud.com.dordavid.WearIt")
        )

        do {
            let container = try ModelContainer(for: schema, configurations: cfg)
            NotificationService.shared.configure(container: container)
            #if DEBUG
            print("MODEL_CONTAINER_READY")
            #endif
            state = .ready(container)
        } catch {
            let message = "Failed to initialize persistent store: \(error.localizedDescription)"
            log.fault("\(message, privacy: .public)")
            state = .failed(message)
        }
    }
}
