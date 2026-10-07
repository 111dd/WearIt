import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var weather: WeatherCenter
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var cloudKit: CloudKitSyncMonitor
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selected: AppTab = .planner
    @State private var appIntentRouter = WearItAppIntentRouter.shared
    @State private var showSignInSheet = false
    @AppStorage("didSkipSignIn") private var didSkipSignIn = false
    @AppStorage(AppBackdropKeys.preset) private var backdropPresetRaw: String = AppBackdropPreset.softSky.rawValue
    @AppStorage(AppBackdropKeys.customImageIsDark) private var backdropImageIsDark = false
    enum AppTab: Hashable { case planner, calendar, wardrobe, add }

    private var backdropScheme: ColorScheme {
        let preset = AppBackdropPreset(rawValue: backdropPresetRaw) ?? .softSky
        if preset == .photo { return backdropImageIsDark ? .dark : .light }
        return preset.prefersDarkScheme ? .dark : .light
    }

    var body: some View {
        // Backdrop via `.background` (not ZStack) so wallpaper never expands layout width.
        TabView(selection: $selected) {
            Tab(LocalizedStringKey("tab_outfits"), systemImage: "sparkles", value: AppTab.planner) {
                OutfitPlannerView()
            }

            Tab(LocalizedStringKey("tab_calendar"), systemImage: "calendar", value: AppTab.calendar) {
                NavigationStack {
                    CalendarLookView()
                        .withLocalAppBackdrop()
                }
            }

            Tab(LocalizedStringKey("tab_wardrobe"), systemImage: "square.grid.2x2", value: AppTab.wardrobe) {
                WardrobeView()
            }

            Tab(LocalizedStringKey("tab_add"), systemImage: "plus.circle", value: AppTab.add) {
                AddGarmentView()
            }
        }
        .tint(.accentColor)
        .withLocalAppBackdrop()
        .background {
            LiquidGlassBackdrop()
                .ignoresSafeArea()
        }
        .animation(reduceMotion ? nil : DS.Animation.transition, value: selected)
        // An inset, not an overlay: as an overlay the banner sat under the
        // Dynamic Island and covered the toolbar buttons of every tab.
        .safeAreaInset(edge: .top, spacing: 0) {
            if shouldShowSignInCTA {
                signInBanner
            }
        }
        .onAppear {
            DS.prepareHaptics()
            handleIncomingSystemAction()
        }
        .task {
            if AppBackdropPreset(rawValue: backdropPresetRaw) == .photo,
               UserDefaults.standard.object(forKey: AppBackdropKeys.customImageIsDark) == nil,
               let image = AppBackdropStore.loadCustomImage() {
                let isDark = (AppBackdropStore.averageLuminance(of: image) ?? 1.0)
                    < AppBackdropStore.darkLuminanceThreshold
                backdropImageIsDark = isDark
            }
            // One-time wardrobe upgrade: per-type defaults + on-device AI
            // enrichment for legacy garments stuck on generic 3/nil values.
            // Delayed so launch-critical work (weather, planner) goes first.
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await GarmentEnrichmentService.runRetroactivePassIfNeeded(context: context)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                handleIncomingSystemAction()
            }
        }
        .onChange(of: appIntentRouter.pendingDestination) { _, _ in
            handleIncomingSystemAction()
        }
        .onChange(of: appIntentRouter.pendingAction) { _, newAction in
            if newAction != nil {
                selected = .planner
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPlannerDay)) { _ in
            selected = .planner
        }
        .onOpenURL { url in
            if url.host == "planner" {
                selected = .planner
            } else if url.host == "add" {
                selected = .add
            } else if url.host == "confirm-worn" {
                selected = .planner
                NotificationCenter.default.post(name: .confirmWornFromWidget, object: nil)
            }
        }
        .sheet(isPresented: $showSignInSheet) {
            SignInView()
                .preferredColorScheme(backdropScheme)
        }
        .preferredColorScheme(backdropScheme)
    }

    @MainActor
    private func handleIncomingSystemAction() {
        WidgetCommandService.consumeIfNeeded(context: context)

        switch appIntentRouter.consume() {
        case .todayOutfit:
            selected = .planner
        case .addGarment:
            selected = .add
        case nil:
            break
        }

        if appIntentRouter.pendingAction != nil {
            selected = .planner
        }
    }

    private var shouldShowSignInCTA: Bool {
        didSkipSignIn && !auth.isSignedIn
    }

    private var signInBanner: some View {
        HStack(spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "backup_cta_title"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(backupCTASubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: DS.Spacing.xs)

            Button {
                showSignInSheet = true
            } label: {
                Text(String(localized: "backup_cta_action"))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, 6)
                    .liquidGlassPill(interactive: true, tint: Color.accentColor.opacity(0.12))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .liquidGlassSurface(cornerRadius: 0, tint: Color.accentColor.opacity(0.035))
    }

    private var backupCTASubtitle: String {
        switch cloudKit.status {
        case .notAvailable:
            return String(localized: "backup_cta_icloud_off")
        default:
            return String(localized: "backup_cta_subtitle")
        }
    }
}
