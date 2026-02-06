import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var weather: WeatherCenter
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var cloudKit: CloudKitSyncMonitor
    @Environment(\.scenePhase) private var scenePhase

    @State private var selected: AppTab = .planner
    @State private var showSignInSheet = false
    @AppStorage("didSkipSignIn") private var didSkipSignIn = false
    enum AppTab: Hashable { case planner, calendar, wardrobe, add, stats, profile }

    var body: some View {
        ZStack {
            TabView(selection: $selected) {
                Tab(LocalizedStringKey("tab_outfits"), systemImage: "sparkles", value: AppTab.planner) {
                    OutfitPlannerView()
                }

                Tab(LocalizedStringKey("tab_calendar"), systemImage: "calendar", value: AppTab.calendar) {
                    NavigationStack {
                        CalendarLookView()
                            .navigationTitle(String(localized: "nav_calendar"))
                    }
                }

                Tab(LocalizedStringKey("tab_wardrobe"), systemImage: "square.grid.2x2", value: AppTab.wardrobe) {
                    WardrobeView()
                }

                Tab(LocalizedStringKey("tab_add"), systemImage: "plus.circle", value: AppTab.add) {
                    NavigationStack {
                        AddGarmentView()
                            .navigationTitle(String(localized: "nav_add_item"))
                    }
                }

                Tab(LocalizedStringKey("tab_stats"), systemImage: "chart.bar", value: AppTab.stats) {
                    NavigationStack {
                        StatsView()
                            .navigationTitle(String(localized: "nav_stats"))
                    }
                }

                Tab(LocalizedStringKey("tab_profile"), systemImage: "person", value: AppTab.profile) {
                    NavigationStack {
                        ProfileView()
                            .navigationTitle(String(localized: "nav_profile"))
                    }
                }
            }
            .tint(.accentColor)
            .toolbarBackground(.ultraThinMaterial, for: .tabBar)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)

            if shouldShowSignInCTA {
                signInBanner
            }
        }
        .onAppear {
            UIView.appearance(whenContainedInInstancesOf: [UITabBarController.self]).backgroundColor = .clear
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                WidgetCommandService.consumeIfNeeded(context: context)
            }
        }
        .onOpenURL { url in
            if url.host == "planner" {
                selected = .planner
            } else if url.host == "confirm-worn" {
                selected = .planner
                NotificationCenter.default.post(name: .confirmWornFromWidget, object: nil)
            }
        }
        .sheet(isPresented: $showSignInSheet) {
            SignInView()
        }
    }

    private var shouldShowSignInCTA: Bool {
        didSkipSignIn && !auth.isSignedIn
    }

    private var signInBanner: some View {
        VStack {
            HStack(spacing: DS.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "backup_cta_title"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(backupCTASubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showSignInSheet = true
                } label: {
                    Text(String(localized: "backup_cta_action"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(DS.Border.subtle, lineWidth: 0.6)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .background(.ultraThinMaterial)
            .overlay(
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
                    .blendMode(.plusLighter)
            )

            Spacer()
        }
        .ignoresSafeArea(edges: .top)
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
