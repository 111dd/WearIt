import SwiftUI
import SwiftData
import UIKit

struct ProfileView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var cloudKit: CloudKitSyncMonitor

    @Query<UserProfile> private var users: [UserProfile]
    @Query<NotificationPreferences> private var notificationPrefs: [NotificationPreferences]

    @State private var avatarEmoji: String = "🧑🏻"
    @State private var displayName: String = ""
    @State private var email: String = ""
    @State private var phone: String = ""
    @State private var preferredFormality: Int = 3
    @State private var warmthSensitivity: Int = 3
    @State private var rainTolerance: Int = 3
    @State private var showSignInSheet = false
    @State private var showSignOutDialog = false
    @AppStorage("didSkipSignIn") private var didSkipSignIn = false

    @State private var currentDate: Date = Date()
    @State private var prefsSaveDebouncer = Debouncer(interval: 3.0)
    @State private var scheduleNotificationsDebouncer = Debouncer(interval: 5.0)

    init() { _users = Query(FetchDescriptor<UserProfile>()) }

    var body: some View {
        ZStack {
            LiquidGlassBackdrop()
                .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: DS.Spacing.lg) {
                    heroProfileCard
                    accountCard
                    algorithmSection
                    notificationsSection
                    dataManagementSection
                    languageSection

                    #if DEBUG
                    debugSection
                    #endif
                    
                    Button {
                        DS.haptic(0.6)
                        saveProfile()
                    } label: {
                        Label(String(localized: "profile_save_changes"), systemImage: "checkmark.circle.fill")
                    }
                    .dsPrimaryButton()
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.sm)
                .padding(.bottom, DS.Spacing.lg)
            }
        }
        .navigationTitle(String(localized: "nav_profile"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    saveProfile()
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .accessibilityLabel(String(localized: "action_save"))
            }
        }
        .onAppear {
            refreshCurrentDate()
            loadOrCreateUser()
        }
        .onChange(of: auth.userIdentifier) { _, _ in loadOrCreateUser() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshCurrentDate()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            refreshCurrentDate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .profileFlushPrefsSave)) { _ in
            try? context.save()
        }
        .onReceive(NotificationCenter.default.publisher(for: .profileScheduleNotifications)) { _ in
            scheduleNotifications()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                prefsSaveDebouncer.flush()
                try? context.save()
            }
        }
        .sheet(isPresented: $showSignInSheet) {
            SignInView()
        }
        .confirmationDialog(
            String(localized: "profile_signout_title"),
            isPresented: $showSignOutDialog,
            titleVisibility: .visible
        ) {
            Button(String(localized: "profile_signout_stay_offline")) {
                auth.signOut()
                didSkipSignIn = true
            }
            Button(String(localized: "profile_signout_go_to_signin")) {
                auth.signOut()
                didSkipSignIn = false
            }
            Button(String(localized: "action_cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "profile_signout_message"))
        }
    }

    // MARK: - Sections
    
    private var heroProfileCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .center, spacing: DS.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .strokeBorder(DS.Border.subtle, lineWidth: 0.8)
                        )
                    if avatarEmoji.isEmpty {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(avatarEmoji)
                            .font(.system(size: 36))
                    }
                }
                .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayNameText)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    if !emailText.isEmpty {
                        Text(emailText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Text(signedInStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(String(localized: "profile_profile_managed"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button(String(localized: "action_edit")) { }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(DS.Border.subtle, lineWidth: 0.6)
                    )
                    .disabled(true)
                    .opacity(0.5)
            }
        }
        .dsCard()
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "profile_account"), icon: "person.circle.fill")

            HStack(alignment: .center, spacing: DS.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "profile_signed_in_with_apple"))
                        .font(.subheadline.weight(.medium))
                    Text(auth.isSignedIn ? String(localized: "profile_signed_in") : String(localized: "profile_signed_out"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if auth.isSignedIn, let currentEmail = auth.email, !currentEmail.isEmpty {
                        Text(currentEmail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if auth.isSignedIn {
                    Button(role: .destructive) {
                        showSignOutDialog = true
                    } label: {
                        Label(String(localized: "profile_sign_out"), systemImage: "rectangle.portrait.and.arrow.right")
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
                } else {
                    Button {
                        showSignInSheet = true
                    } label: {
                        Label(String(localized: "profile_sign_in"), systemImage: "person.crop.circle.badge.plus")
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
            }

            Divider()

            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "icloud.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "profile_cloud_sync"))
                        .font(.subheadline.weight(.medium))
                    Text(cloudStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Text(cloudExplanationText)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                openAppSettings()
            } label: {
                HStack {
                    Text(String(localized: "profile_manage_icloud_settings"))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Text(String(localized: "profile_account_sync_caption"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .dsCard()
    }

    private var algorithmSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "profile_algorithm_title"), icon: "sparkles")

            Text(String(localized: "profile_algorithm_intro"))
                .font(.caption)
                .foregroundStyle(.secondary)

            PreferenceRow(
                label: String(localized: "profile_formality"),
                icon: "briefcase",
                value: $preferredFormality,
                range: 1...4,
                labels: [String(localized: "profile_casual"), String(localized: "profile_elegant")]
            )

            PreferenceRow(
                label: String(localized: "profile_warmth_sensitivity"),
                icon: "thermometer.medium",
                value: $warmthSensitivity,
                range: 1...5,
                labels: [String(localized: "profile_resistant"), String(localized: "profile_sensitive")]
            )

            PreferenceRow(
                label: String(localized: "profile_rain_tolerance"),
                icon: "umbrella",
                value: $rainTolerance,
                range: 1...5,
                labels: [String(localized: "profile_dont_care"), String(localized: "profile_prefer_dry")]
            )
        }
        .dsCard()
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "notifications_section_title"), icon: "bell.badge")

            Text(String(localized: "notifications_section_subtext"))
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Toggle(String(localized: "notifications_morning_title"), isOn: morningEnabledBinding)
                    .tint(.accentColor)

                DatePicker(
                    String(localized: "notifications_time_label"),
                    selection: morningTimeBinding,
                    displayedComponents: [.hourAndMinute]
                )
                .disabled(!prefs.morningEnabled)

                Text(String(localized: "notifications_morning_help"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Toggle(String(localized: "notifications_weather_title"), isOn: weatherEnabledBinding)
                    .tint(.accentColor)

                Text(String(localized: "notifications_weather_help"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Toggle(String(localized: "notifications_confirm_title"), isOn: confirmEnabledBinding)
                    .tint(.accentColor)

                DatePicker(
                    String(localized: "notifications_time_label"),
                    selection: confirmTimeBinding,
                    displayedComponents: [.hourAndMinute]
                )
                .disabled(!prefs.confirmEnabled)

                Text(String(localized: "notifications_confirm_help"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(String(localized: "notifications_learn_more"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .dsCard()
        .onChange(of: prefs.morningEnabled) { _, _ in scheduleNotificationsDebounced() }
        .onChange(of: prefs.weatherEnabled) { _, _ in scheduleNotificationsDebounced() }
        .onChange(of: prefs.confirmEnabled) { _, _ in scheduleNotificationsDebounced() }
        .onChange(of: prefs.morningHour) { _, _ in scheduleNotificationsDebounced() }
        .onChange(of: prefs.morningMinute) { _, _ in scheduleNotificationsDebounced() }
        .onChange(of: prefs.confirmHour) { _, _ in scheduleNotificationsDebounced() }
        .onChange(of: prefs.confirmMinute) { _, _ in scheduleNotificationsDebounced() }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            DSSectionHeader(String(localized: "language_section_title"), icon: "globe")

            HStack {
                Text(String(localized: "language_system_label"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(currentLanguageName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(String(localized: "language_system_note"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .dsCard()
    }

    private var dataManagementSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "profile_data_management"), icon: "tray.full")

            NavigationLink {
                BrandManagementView()
            } label: {
                Label(String(localized: "brand_management_title"), systemImage: "tag")
                    .font(.subheadline.weight(.medium))
            }
            .dsSecondaryButton()
        }
        .dsCard()
    }

    private var cloudStatusText: String {
        switch cloudKit.status {
        case .notAvailable:
            return String(localized: "profile_cloud_status_unavailable")
        case .syncing:
            return String(localized: "profile_cloud_status_syncing")
        case .synced:
            return String(localized: "profile_cloud_status_synced")
        case .error:
            return String(localized: "profile_cloud_status_error")
        }
    }

    private var currentLanguageName: String {
        let code = Locale.current.language.languageCode?.identifier ?? Locale.current.identifier
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private var displayNameText: String {
        if !displayName.isEmpty { return displayName }
        if let authName = auth.displayName, !authName.isEmpty { return authName }
        return String(localized: "profile_default_name")
    }

    private var emailText: String {
        if !email.isEmpty { return email }
        return auth.email ?? ""
    }

    private var signedInStatusText: String {
        auth.isSignedIn
            ? String(localized: "profile_signed_in_with_apple")
            : String(localized: "profile_signed_out")
    }

    private var cloudExplanationText: String {
        if cloudKit.status == .notAvailable {
            return cloudKit.availabilityMessage.isEmpty
                ? String(localized: "profile_cloud_guidance")
                : cloudKit.availabilityMessage
        }
        if case .error(let message) = cloudKit.status {
            return message
        }
        return String(localized: "profile_icloud_signin_separate")
    }

    #if DEBUG
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            DSSectionHeader("Debug", icon: "ladybug")
            Button("Re-run Diagnostics") {
                DebugOutfitDiagnostics.runDiagnostics(context: context, limit: 8)
            }
            .dsSecondaryButton()
            let lines = DebugOutfitDiagnostics.sampleLines(context: context, limit: 8)
            if lines.isEmpty {
                Text("OUTFIT_SAMPLE,empty=true")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .dsCard(padding: DS.Spacing.sm)
    }
    #endif

    // MARK: - Notifications

    private var prefs: NotificationPreferences {
        if let existing = notificationPrefs.first { return existing }
        let created = NotificationPreferences()
        context.insert(created)
        try? context.save()
        return created
    }

    private var morningEnabledBinding: Binding<Bool> {
        Binding(get: { prefs.morningEnabled }, set: { prefs.morningEnabled = $0; schedulePrefsSave() })
    }

    private var weatherEnabledBinding: Binding<Bool> {
        Binding(get: { prefs.weatherEnabled }, set: { prefs.weatherEnabled = $0; schedulePrefsSave() })
    }

    private var confirmEnabledBinding: Binding<Bool> {
        Binding(get: { prefs.confirmEnabled }, set: { prefs.confirmEnabled = $0; schedulePrefsSave() })
    }

    private var morningTimeBinding: Binding<Date> {
        Binding(
            get: { timeFrom(hour: prefs.morningHour, minute: prefs.morningMinute) },
            set: {
                let comps = Calendar.current.dateComponents([.hour, .minute], from: $0)
                prefs.morningHour = comps.hour ?? prefs.morningHour
                prefs.morningMinute = comps.minute ?? prefs.morningMinute
                schedulePrefsSave()
            }
        )
    }

    private var confirmTimeBinding: Binding<Date> {
        Binding(
            get: { timeFrom(hour: prefs.confirmHour, minute: prefs.confirmMinute) },
            set: {
                let comps = Calendar.current.dateComponents([.hour, .minute], from: $0)
                prefs.confirmHour = comps.hour ?? prefs.confirmHour
                prefs.confirmMinute = comps.minute ?? prefs.confirmMinute
                schedulePrefsSave()
            }
        )
    }

    private func schedulePrefsSave() {
        prefsSaveDebouncer.schedule {
            NotificationCenter.default.post(name: .profileFlushPrefsSave, object: nil)
        }
    }

    private func timeFrom(hour: Int, minute: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: currentDate)
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.date(from: comps) ?? currentDate
    }

    private func refreshCurrentDate() {
        currentDate = Date()
    }

    private func scheduleNotifications() {
        Task { await NotificationService.shared.scheduleDailyNotifications(context: context) }
    }

    private func scheduleNotificationsDebounced() {
        scheduleNotificationsDebouncer.schedule {
            NotificationCenter.default.post(name: .profileScheduleNotifications, object: nil)
        }
    }

    // MARK: - Data

    private func loadOrCreateUser() {
        guard let uid = auth.userIdentifier else {
            avatarEmoji = "🧑🏻"
            displayName = ""
            email = auth.email ?? ""
            phone = ""
            preferredFormality = 3
            warmthSensitivity = 3
            rainTolerance = 3
            return
        }
        
        let fd = FetchDescriptor<UserProfile>(
            predicate: #Predicate { $0.userIdentifier == uid },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        
        if let results = try? context.fetch(fd), let me = results.first {
            avatarEmoji = me.avatarEmoji ?? "🧑🏻"
            displayName = me.displayName
            email = me.email ?? (auth.email ?? "")
            phone = me.phone ?? ""
            preferredFormality = me.preferredFormality
            warmthSensitivity = me.warmthSensitivity
            rainTolerance = me.rainTolerance
        } else {
            let me = UserProfile()
            me.userIdentifier = uid
            me.displayName = auth.displayName ?? String(localized: "profile_default_name")
            me.email = auth.email
            context.insert(me)
            try? context.save()
            avatarEmoji = me.avatarEmoji ?? "🧑🏻"
            displayName = me.displayName
            email = me.email ?? ""
            phone = me.phone ?? ""
            preferredFormality = me.preferredFormality
            warmthSensitivity = me.warmthSensitivity
            rainTolerance = me.rainTolerance
        }
    }

    private func saveProfile() {
        guard let uid = auth.userIdentifier else { return }
        
        let fd = FetchDescriptor<UserProfile>(
            predicate: #Predicate { $0.userIdentifier == uid },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        
        let me: UserProfile
        if let results = try? context.fetch(fd), let existing = results.first {
            me = existing
        } else {
            let new = UserProfile()
            new.userIdentifier = uid
            context.insert(new)
            me = new
        }

        me.avatarEmoji = avatarEmoji.isEmpty ? "🧑🏻" : avatarEmoji
        me.displayName = displayName.isEmpty ? (auth.displayName ?? String(localized: "profile_default_name")) : displayName
        me.email = email.isEmpty ? (auth.email ?? "") : email
        me.phone = phone.isEmpty ? nil : phone
        me.preferredFormality = preferredFormality
        me.warmthSensitivity = warmthSensitivity
        me.rainTolerance = rainTolerance

        try? context.save()
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Preference Row

private struct PreferenceRow: View {
    let label: String
    let icon: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let labels: [String]
    
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                Label(label, systemImage: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                
                Spacer()

                Text(scaleLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Spacing.xs)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(DS.Border.subtle, lineWidth: 0.6)
                    )
            }
            
            HStack {
                Text(labels.first ?? "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                
                Slider(
                    value: Binding(
                        get: { Double(value) },
                        set: { value = Int($0) }
                    ),
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    step: 1
                )
                .tint(.accentColor)
                
                Text(labels.last ?? "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(String(localized: "profile_pref_affects"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, DS.Spacing.xxs)
    }

    private var scaleLabel: String {
        let minValue = range.lowerBound
        let maxValue = range.upperBound
        if maxValue <= minValue { return String(localized: "profile_level_medium") }
        let normalized = Double(value - minValue) / Double(maxValue - minValue)
        if normalized < 0.34 {
            return String(localized: "profile_level_low")
        } else if normalized < 0.67 {
            return String(localized: "profile_level_medium")
        }
        return String(localized: "profile_level_high")
    }
}
