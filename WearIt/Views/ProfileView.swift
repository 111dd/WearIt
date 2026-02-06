import SwiftUI
import SwiftData
import UIKit

struct ProfileView: View {
    @Environment(\.modelContext) private var context
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

    @FocusState private var focusedField: Field?
    @State private var currentDate: Date = Date()

    enum Field { case emoji, name, email, phone }

    init() { _users = Query(FetchDescriptor<UserProfile>()) }

    var body: some View {
        ZStack {
            LiquidGlassBackdrop()
            
            ScrollView {
                VStack(spacing: DS.Spacing.md) {
                    accountSection
                    stylePreferencesSection
                    notificationsSection
                    dataManagementSection
                    languageSection
                    cloudSection

                    #if DEBUG
                    debugSection
                    #endif
                    
                    // Save Button
                    Button {
                        DS.haptic(0.6)
                        saveProfile()
                        dismissKeyboard()
                    } label: {
                        Label(String(localized: "profile_save_changes"), systemImage: "checkmark.circle.fill")
                    }
                    .dsPrimaryButton()
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.sm)
                .padding(.bottom, 100)
            }
        }
        .navigationTitle(String(localized: "nav_profile"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "action_done")) { dismissKeyboard() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    dismissKeyboard()
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
    
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "profile_account"), icon: "person.circle.fill")
            
            HStack(spacing: DS.Spacing.sm) {
                // Avatar emoji
                TextField("🙂", text: $avatarEmoji)
                    .frame(width: 56, height: 56)
                    .font(.system(size: 32))
                    .multilineTextAlignment(.center)
                    .focused($focusedField, equals: .emoji)
                    .submitLabel(.done)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                
                // Name
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(String(localized: "profile_display_name"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "profile_display_name_placeholder"), text: $displayName)
                        .textInputAutocapitalization(.words)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.done)
                        .padding(DS.Spacing.xs)
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
                }
            }
            
            // Email
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(String(localized: "profile_email"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(String(localized: "profile_email_placeholder"), text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focusedField, equals: .email)
                    .submitLabel(.done)
                    .padding(DS.Spacing.xs)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
            }
            
            // Phone
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(String(localized: "profile_phone"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(String(localized: "profile_phone_placeholder"), text: $phone)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
                    .focused($focusedField, equals: .phone)
                    .padding(DS.Spacing.xs)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
            }
            
            // Apple account button
            Button {
                if let n = auth.displayName, !n.isEmpty { displayName = n }
                if let e = auth.email, !e.isEmpty { email = e }
                saveProfile()
            } label: {
                Label(String(localized: "profile_use_apple_info"), systemImage: "apple.logo")
                    .font(.subheadline.weight(.medium))
            }
            .dsSecondaryButton()

            Divider()

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(auth.isSignedIn
                     ? String(localized: "profile_signed_in")
                     : String(localized: "profile_signed_out"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let currentEmail = auth.email, !currentEmail.isEmpty {
                    Text(currentEmail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if auth.isSignedIn {
                Button(role: .destructive) {
                    showSignOutDialog = true
                } label: {
                    Label(String(localized: "profile_sign_out"), systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.subheadline.weight(.medium))
                }
                .dsSecondaryButton()
            } else {
                Button {
                    showSignInSheet = true
                } label: {
                    Label(String(localized: "profile_sign_in"), systemImage: "person.crop.circle.badge.plus")
                        .font(.subheadline.weight(.medium))
                }
                .dsSecondaryButton()
            }
        }
        .dsCard()
    }

    private var stylePreferencesSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "profile_style_preferences"), icon: "sparkles")
            
            PreferenceRow(
                label: String(localized: "profile_formality"),
                icon: "briefcase",
                value: $preferredFormality,
                range: 1...4,
                labels: [String(localized: "profile_casual"), String(localized: "profile_smart")]
            )
            
            PreferenceRow(
                label: String(localized: "profile_warmth_sensitivity"),
                icon: "thermometer.medium",
                value: $warmthSensitivity,
                range: 1...5,
                labels: [String(localized: "profile_run_cold"), String(localized: "profile_run_hot")]
            )
            
            PreferenceRow(
                label: String(localized: "profile_rain_tolerance"),
                icon: "umbrella",
                value: $rainTolerance,
                range: 1...5,
                labels: [String(localized: "profile_avoid_rain"), String(localized: "profile_dont_mind")]
            )
        }
        .dsCard()
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(String(localized: "notifications_section_title"))
                .font(.headline)

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
        .onChange(of: prefs.morningEnabled) { _, _ in scheduleNotifications() }
        .onChange(of: prefs.weatherEnabled) { _, _ in scheduleNotifications() }
        .onChange(of: prefs.confirmEnabled) { _, _ in scheduleNotifications() }
        .onChange(of: prefs.morningHour) { _, _ in scheduleNotifications() }
        .onChange(of: prefs.morningMinute) { _, _ in scheduleNotifications() }
        .onChange(of: prefs.confirmHour) { _, _ in scheduleNotifications() }
        .onChange(of: prefs.confirmMinute) { _, _ in scheduleNotifications() }
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

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "icloud.fill")
                    .font(.title2)
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
            
            Text(String(localized: "profile_icloud_signin_separate"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            
            if cloudKit.status == .notAvailable {
                let message = cloudKit.availabilityMessage.isEmpty
                    ? String(localized: "profile_cloud_guidance")
                    : cloudKit.availabilityMessage
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if case .error(let message) = cloudKit.status {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .dsCard(padding: DS.Spacing.sm)
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
        Binding(
            get: { prefs.morningEnabled },
            set: { prefs.morningEnabled = $0; try? context.save() }
        )
    }

    private var weatherEnabledBinding: Binding<Bool> {
        Binding(
            get: { prefs.weatherEnabled },
            set: { prefs.weatherEnabled = $0; try? context.save() }
        )
    }

    private var confirmEnabledBinding: Binding<Bool> {
        Binding(
            get: { prefs.confirmEnabled },
            set: { prefs.confirmEnabled = $0; try? context.save() }
        )
    }

    private var morningTimeBinding: Binding<Date> {
        Binding(
            get: { timeFrom(hour: prefs.morningHour, minute: prefs.morningMinute) },
            set: {
                let comps = Calendar.current.dateComponents([.hour, .minute], from: $0)
                prefs.morningHour = comps.hour ?? prefs.morningHour
                prefs.morningMinute = comps.minute ?? prefs.morningMinute
                try? context.save()
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
                try? context.save()
            }
        )
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

    private func dismissKeyboard() {
        UIApplication.shared.endEditing()
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
        VStack(spacing: DS.Spacing.xs) {
            HStack {
                Label(label, systemImage: icon)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                
                Spacer()
                
                Text("\(value)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
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
        }
        .padding(.vertical, DS.Spacing.xxs)
    }
}
