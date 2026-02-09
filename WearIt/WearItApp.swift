import SwiftUI
import SwiftData
import os

@main
struct WearItApp: App {
    // MARK: - Bootstrap
    @StateObject private var bootstrapper = AppBootstrapper()

    init() {
        // מתקין מראה ניווט/טאב שקוף עם blur (liquid glass) לכל האפליקציה
        AppAppearance.install()
    }

    // MARK: - Scene
    var body: some Scene {
        WindowGroup {
            Group {
                switch bootstrapper.state {
                case .ready(let container):
                    ZStack {
                        // Solid background to prevent black flash during launch
                        Color(.systemBackground)
                            .ignoresSafeArea()
                        
                        // Liquid glass backdrop (animated + noise + material layer)
                        LiquidGlassBackdrop()
                            .ignoresSafeArea()

                        // Main app content with loading state
                        BootstrapView()
                            .tint(.accentColor)
                    }
                    .ignoresSafeArea()
                    .modelContainer(container)

                case .failed(let message):
                    LoadingGateView(message: message)

                case .idle, .loading:
                    LoadingGateView(message: bootstrapper.statusMessage)
                }
            }
            .environmentObject(WeatherCenter.shared)
            .environmentObject(AuthManager.shared)
            .environmentObject(CloudKitSyncMonitor.shared)
            .task {
                bootstrapper.startIfNeeded()
            }
        }
    }
}
