import SwiftUI
import SwiftData
import CoreLocation

// MARK: - App Load State

enum AppLoadState: Equatable {
    case loading
    case ready
}

// MARK: - Bootstrap View

struct BootstrapView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var weather: WeatherCenter
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var cloudKit: CloudKitSyncMonitor

    @AppStorage("didSeed") private var didSeed = false
    @State private var loadState: AppLoadState = .loading
    @State private var loadingMessage: String = String(localized: "loading_ready")

    var body: some View {
        ZStack {
            // Main app content (always in hierarchy for state preservation)
            AppGateView()
                .opacity(loadState == .ready ? 1 : 0)
            
            // Loading overlay
            if loadState == .loading {
                AppLoadingView(message: loadingMessage)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: loadState)
        .task {
            await performBootstrap()
        }
    }

    // MARK: - Bootstrap Tasks

    private func performBootstrap() async {
        // Small delay to ensure loading screen appears smoothly
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        
        // Step 0: Refresh auth + iCloud status (do not block on sync events)
        loadingMessage = String(localized: "loading_ready")
        await auth.refreshCredentialStateIfNeeded()
        await cloudKit.refreshAccountStatus()

        // Step 1: Data migrations
        loadingMessage = String(localized: "loading_preparing")
        await DataMigrationService.shared.runMigrationsAndWait(context: context)
        
        // Step 2: Seed data
        if !didSeed {
            loadingMessage = String(localized: "loading_setting_up")
            SeedData.load(context: context)
            didSeed = true
        }
        
        // Step 3: Weather (non-blocking, with timeout)
        loadingMessage = String(localized: "loading_weather")
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                await refreshWeatherFromLocation()
            }
            group.addTask { [weather] in
                await weather.refreshForecast(source: "BootstrapView.performBootstrap")
            }
            group.addTask {
                // Timeout after 3 seconds
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            
            // Wait for first task to complete (or timeout)
            await group.next()
            group.cancelAll()
        }
        
        // Minimum loading time for polish (ensures animation is visible)
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s

        // Schedule notifications (after forecasts are updated)
        await NotificationService.shared.scheduleDailyNotifications(context: context)
        
        // Transition to ready state
        await MainActor.run {
            withAnimation(.easeOut(duration: 0.35)) {
                loadState = .ready
            }
        }
    }

    // MARK: - Weather

    private func refreshWeatherFromLocation() async {
        do {
            let coord = try await LocationManager.shared.requestLocation()
            let snap = try await WeatherService.forecastNextHours(
                lat: coord.latitude,
                lon: coord.longitude,
                hours: 3
            )
            await MainActor.run {
                weather.update(tempC: snap.temperatureC, isRaining: snap.isRaining)
            }
        } catch {
            print("Weather refresh failed:", error.localizedDescription)
        }
    }
}

// MARK: - App Loading View

private final class IconCycleCounter: ObservableObject {
    @Published var count = 0
    var timer: Timer?
}

struct AppLoadingView: View {
    let message: String
    
    @State private var isAnimating = false
    @StateObject private var iconCycleCounter = IconCycleCounter()
    private static let maxIconCycles = 5

    private let icons = ["tshirt.fill", "cloud.sun.fill", "sparkles"]
    
    var body: some View {
        ZStack {
            // Subtle gradient background
            LinearGradient(
                colors: [
                    Color(.systemBackground),
                    Color(.systemBackground).opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 32) {
                Spacer()
                
                // Animated icon
                ZStack {
                    // Pulsing background circle
                    Circle()
                        .fill(Color.accentColor.opacity(0.1))
                        .frame(width: 100, height: 100)
                        .scaleEffect(isAnimating ? 1.2 : 1.0)
                        .opacity(isAnimating ? 0.5 : 1.0)
                    
                    // Icon
                    Image(systemName: icons[iconCycleCounter.count % icons.count])
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.pulse.byLayer, options: .repeating, value: isAnimating)
                }
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isAnimating)
                
                // Loading text
                VStack(spacing: 8) {
                    Text(message)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    // Subtle dots animation
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(Color.secondary.opacity(0.4))
                                .frame(width: 6, height: 6)
                                .scaleEffect(isAnimating && (iconCycleCounter.count % 3 == i) ? 1.3 : 1.0)
                                .animation(
                                    .easeInOut(duration: 0.4)
                                    .repeatForever()
                                    .delay(Double(i) * 0.15),
                                    value: isAnimating
                                )
                        }
                    }
                }
                
                Spacer()
                Spacer()
            }
        }
        .onAppear {
            isAnimating = true
            iconCycleCounter.count = 0
            iconCycleCounter.timer?.invalidate()
            iconCycleCounter.timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [iconCycleCounter] _ in
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        iconCycleCounter.count += 1
                    }
                    if iconCycleCounter.count >= Self.maxIconCycles {
                        iconCycleCounter.timer?.invalidate()
                        iconCycleCounter.timer = nil
                    }
                }
            }
        }
        .onDisappear {
            isAnimating = false
            iconCycleCounter.timer?.invalidate()
            iconCycleCounter.timer = nil
        }
    }
}

// MARK: - Preview

#Preview("Loading") {
    AppLoadingView(message: "Preparing your wardrobe")
}

#Preview("Bootstrap") {
    BootstrapView()
        .environmentObject(WeatherCenter.shared)
}
