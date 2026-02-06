import SwiftUI
import SwiftData
import os

@main
struct WearItApp: App {
    // MARK: - Storage
    let container: ModelContainer
    private let log = Logger(subsystem: "com.dordavid.WearIt", category: "App")

    init() {
        // מתקין מראה ניווט/טאב שקוף עם blur (liquid glass) לכל האפליקציה
        AppAppearance.install()

        // סכמת המודלים של האפליקציה (לוקאלי)
        let schema = Schema([
            Garment.self,
            Outfit.self,
            RecoState.self,
            DismissedOutfit.self,
            UserProfile.self,
            DailyLook.self,
            OutfitFeedback.self,
            DayPlan.self,
            NotificationPreferences.self,
            Brand.self,
            WearEvent.self
        ])

        // אחסון מקומי מוגדר במפורש (Application Support/WearIt.store) + מיגרציה אוטומטית
        let storeURL: URL = {
            let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true)
            return base?.appending(path: "WearIt.store") ?? URL(fileURLWithPath: "/tmp/WearIt.store")
        }()
        let cfg = ModelConfiguration(
            url: storeURL,
            cloudKitDatabase: .private("iCloud.com.dordavid.WearIt")
        )

        do {
            container = try ModelContainer(for: schema, configurations: cfg)
            NotificationService.shared.configure(container: container)
            #if DEBUG
            print("MODEL_CONTAINER_READY,cloudKit=private")
            #endif
        } catch {
            log.fault("Critical: Failed to load ModelContainer at \(storeURL.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
            fatalError("Failed to initialize persistent store: \(error.localizedDescription)")
        }
    }

    // MARK: - Scene
    var body: some Scene {
        WindowGroup {
            ZStack {
                // Solid background to prevent black flash during launch
                Color(.systemBackground)
                    .ignoresSafeArea()
                
                // Liquid glass backdrop (animated + noise + material layer)
                LiquidGlassBackdrop()
                    .ignoresSafeArea()

                // Main app content with loading state
                BootstrapView()
                    .environmentObject(WeatherCenter.shared)
                    .environmentObject(AuthManager.shared)
                    .environmentObject(CloudKitSyncMonitor.shared)
                    .tint(.accentColor)
            }
            .ignoresSafeArea()
        }
        .modelContainer(container)
    }
}
