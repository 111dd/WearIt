import SwiftUI
import SwiftData
import CoreLocation
import os

// MARK: - App Load State

enum AppLoadState: Equatable {
    case loading
    case ready
}

// MARK: - Bootstrap coordination

/// Prevents duplicate critical/deferred startup work if SwiftUI recreates BootstrapView.
@MainActor
enum BootstrapCoordinator {
    private static var criticalTask: Task<Void, Never>?
    private static var deferredTask: Task<Void, Never>?
    private static let signposter = OSSignposter(
        subsystem: WearItPerformance.subsystem,
        category: WearItPerformance.SignpostCategory.bootstrap
    )

    /// Runs critical bootstrap once. Concurrent callers await the same task.
    static func runCriticalOnce(_ work: @escaping @MainActor () async -> Void) async {
        if let criticalTask {
            await criticalTask.value
            return
        }
        let task = Task { @MainActor in
            let state = signposter.beginInterval("critical-bootstrap")
            defer { signposter.endInterval("critical-bootstrap", state) }
            await work()
        }
        criticalTask = task
        await task.value
    }

    static func startDeferredIfNeeded(_ work: @escaping @MainActor () async -> Void) {
        guard deferredTask == nil else { return }
        deferredTask = Task { @MainActor in
            let state = signposter.beginInterval("deferred-bootstrap")
            defer { signposter.endInterval("deferred-bootstrap", state) }
            await work()
        }
    }
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
            // Do not start planner queries, recommendations, or image tasks
            // underneath the loading overlay while migrations are still running.
            // Readiness only moves forward, preserving the app hierarchy afterward.
            if loadState == .ready {
                AppGateView()
            }
            
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
        await BootstrapCoordinator.runCriticalOnce {
            // Auth is needed before AppGateView routing to avoid a sign-in flash.
            loadingMessage = String(localized: "loading_ready")
            let signposter = WearItPerformance.bootstrapSignposter
            do {
                let interval = signposter.beginInterval("credential-check", id: signposter.makeSignpostID())
                defer { signposter.endInterval("credential-check", interval) }
                await auth.refreshCredentialStateIfNeeded()
            }

            // Critical migrations: garment field normalization + brand merge.
            loadingMessage = String(localized: "loading_preparing")
            do {
                let interval = signposter.beginInterval("critical-migrations", id: signposter.makeSignpostID())
                defer { signposter.endInterval("critical-migrations", interval) }
                await DataMigrationService.shared.runCriticalMigrationsAndWait(context: context)
            }

            // First-launch seed must complete before UI to avoid an empty wardrobe flash.
            if !didSeed {
                let interval = signposter.beginInterval("initial-seed", id: signposter.makeSignpostID())
                defer { signposter.endInterval("initial-seed", interval) }
                loadingMessage = String(localized: "loading_setting_up")
                SeedData.load(context: context)
                didSeed = true
            }
        }

        withAnimation(.easeOut(duration: 0.35)) {
            loadState = .ready
        }
        // Marks readiness, not the first rendered frame or animation completion.
        WearItPerformance.bootstrapSignposter.emitEvent("bootstrap-ready")

        // Capture values needed by deferred work (avoid capturing View across tasks).
        let modelContext = context
        let weatherCenter = weather
        let cloudKitMonitor = cloudKit

        BootstrapCoordinator.startDeferredIfNeeded {
            await cloudKitMonitor.refreshAccountStatus()

            await DataMigrationService.shared.runDeferredBackfills(context: modelContext)

            async let locationWeather: Void = Self.refreshWeatherFromLocation(weather: weatherCenter)
            async let forecast: Void = weatherCenter.refreshForecast(source: "BootstrapView.deferred")
            _ = await (locationWeather, forecast)

            await NotificationService.shared.scheduleDailyNotifications(context: modelContext)

            // How much each item is loved is learned, not asked.
            LoveScoreLearner.run(context: modelContext)

            // Visual fingerprints for "looks like" matching; cached, a small batch per launch.
            let withImages = FetchDescriptor<Garment>(predicate: #Predicate { $0.imagePath != nil })
            let items = ((try? modelContext.fetch(withImages)) ?? []).compactMap { garment in
                garment.imagePath.map { GarmentVisualSimilarity.Item(garmentID: garment.id, imagePath: $0) }
            }
            await GarmentVisualSimilarity.shared.warmUp(items)
        }
    }

    // MARK: - Weather

    private static func refreshWeatherFromLocation(weather: WeatherCenter) async {
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
            // Weather failure must not affect launch or deferred bootstrap completion.
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
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        .symbolEffect(.pulse.byLayer, options: .repeating, isActive: isAnimating && !reduceMotion)
                }
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                    value: isAnimating
                )
                
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
                                .scaleEffect(isAnimating && !reduceMotion && (iconCycleCounter.count % 3 == i) ? 1.3 : 1.0)
                                .animation(
                                    reduceMotion
                                        ? nil
                                        : .easeInOut(duration: 0.4)
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
