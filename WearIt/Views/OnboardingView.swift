import SwiftUI
import SwiftData
import AuthenticationServices
import CoreLocation
import EventKit
import UserNotifications

/// Whether the first-run intro is done. A plain enum so launch services can read it off the main actor.
enum OnboardingState {
    static let completedKey = "didCompleteOnboarding"

    /// Launch work that prompts for permissions waits until the intro is done.
    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }
}

/// First run: what WearIt does, three quick answers, permissions asked with a reason,
/// and an optional Sign in with Apple at the end. Existing users never see it
/// (`didCompleteOnboarding` is already set by sign-in or "continue offline").
struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var cloudKit: CloudKitSyncMonitor
    @Query private var profiles: [UserProfile]
    @AppStorage(OnboardingState.completedKey) private var didCompleteOnboarding = false
    @AppStorage("didSkipSignIn") private var didSkipSignIn = false

    /// Set when replayed from Settings: finishing closes the intro instead of passing the gate.
    private let onFinish: (() -> Void)?

    init(onFinish: (() -> Void)? = nil) {
        self.onFinish = onFinish
    }

    private enum Step: Int, CaseIterable {
        case welcome, aboutYou, permissions, account
    }

    private enum PermissionState {
        case notAsked, granted, declined
    }

    private enum Warmth: Int, CaseIterable, Identifiable {
        // `UserProfile.warmthSensitivity`: higher prefers warmer clothes.
        case runsCold = 4
        case average = 3
        case runsWarm = 2

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .runsCold: return String(localized: "onboarding_warmth_cold")
            case .average: return String(localized: "onboarding_warmth_average")
            case .runsWarm: return String(localized: "onboarding_warmth_warm")
            }
        }

        var icon: String {
            switch self {
            case .runsCold: return "snowflake"
            case .average: return "circle.lefthalf.filled"
            case .runsWarm: return "sun.max.fill"
            }
        }
    }

    @State private var step: Step = .welcome
    @State private var name = ""
    @State private var workDressCode: WorkDressCode?
    @State private var warmth: Warmth = .average
    @State private var didPrefill = false
    @State private var locationState: PermissionState = .notAsked
    @State private var calendarState: PermissionState = .notAsked
    @State private var notificationState: PermissionState = .notAsked

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            progressDots
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    if let onFinish {
                        Button(action: onFinish) {
                            Image(systemName: "xmark")
                                .font(.body.weight(.semibold))
                                .frame(width: 36, height: 36)
                                .liquidGlassPill(interactive: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "action_close"))
                        .padding(.leading, DS.Spacing.md)
                    }
                }
                .padding(.top, DS.Spacing.sm)

            ScrollView {
                Group {
                    switch step {
                    case .welcome: welcomePage
                    case .aboutYou: aboutYouPage
                    case .permissions: permissionsPage
                    case .account: accountPage
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.md)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity
                ))
                .id(step)
            }
            .scrollBounceBehavior(.basedOnSize)

            if step != .account {
                footer
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.bottom, DS.Spacing.md)
            }
        }
        .withLocalAppBackdropPainted()
        .animation(DS.Animation.standard, value: step)
        .onAppear(perform: prefillFromProfile)
    }

    // MARK: - Pages

    private var welcomePage: some View {
        VStack(spacing: DS.Spacing.lg) {
            Image(systemName: "tshirt.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, DS.Spacing.xl)

            VStack(spacing: DS.Spacing.sm) {
                Text("WearIt")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text(String(localized: "onboarding_welcome_title"))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                featureRow(icon: "cloud.sun.fill", title: String(localized: "onboarding_feature_weather"))
                featureRow(icon: "calendar", title: String(localized: "onboarding_feature_calendar"))
                featureRow(icon: "sparkles", title: String(localized: "onboarding_feature_learning"))
                featureRow(icon: "lock.icloud.fill", title: String(localized: "onboarding_feature_privacy"))
            }
            .dsCard()
        }
    }

    private var aboutYouPage: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            pageTitle(String(localized: "onboarding_about_title"), subtitle: String(localized: "onboarding_about_subtitle"))

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text(String(localized: "onboarding_name_label"))
                    .font(.subheadline.weight(.semibold))
                TextField(String(localized: "profile_display_name_placeholder"), text: $name)
                    .textContentType(.givenName)
                    .submitLabel(.done)
                    .dsFieldStyle()
            }
            .dsCard()

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text(String(localized: "onboarding_work_label"))
                    .font(.subheadline.weight(.semibold))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DS.Spacing.sm) {
                    ForEach(WorkDressCode.allCases) { code in
                        choiceChip(title: code.title, icon: code.icon, isSelected: workDressCode == code) {
                            // Tapping the chosen one again clears it: the planner asks later.
                            workDressCode = workDressCode == code ? nil : code
                        }
                    }
                }
            }
            .dsCard()

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text(String(localized: "onboarding_warmth_label"))
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: DS.Spacing.sm) {
                    ForEach(Warmth.allCases) { option in
                        choiceChip(title: option.title, icon: option.icon, isSelected: warmth == option) {
                            warmth = option
                        }
                    }
                }
            }
            .dsCard()
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            pageTitle(String(localized: "onboarding_permissions_title"), subtitle: String(localized: "onboarding_permissions_subtitle"))

            VStack(spacing: DS.Spacing.md) {
                permissionRow(
                    icon: "location.fill",
                    title: String(localized: "onboarding_permission_location"),
                    reason: String(localized: "onboarding_permission_location_reason"),
                    state: locationState,
                    request: requestLocation
                )
                Divider()
                permissionRow(
                    icon: "calendar",
                    title: String(localized: "onboarding_permission_calendar"),
                    reason: String(localized: "onboarding_permission_calendar_reason"),
                    state: calendarState,
                    request: requestCalendar
                )
                Divider()
                permissionRow(
                    icon: "bell.fill",
                    title: String(localized: "onboarding_permission_notifications"),
                    reason: String(localized: "onboarding_permission_notifications_reason"),
                    state: notificationState,
                    request: requestNotifications
                )
            }
            .dsCard()

            Text(String(localized: "onboarding_permissions_later"))
                .font(.caption)
                .foregroundStyle(DS.Text.secondary)
        }
        .task { await readPermissionStates() }
    }

    private var accountPage: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            pageTitle(String(localized: "onboarding_account_title"), subtitle: String(localized: "onboarding_account_subtitle"))

            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                Image(systemName: cloudKit.status == .notAvailable ? "icloud.slash" : "checkmark.icloud.fill")
                    .font(.title3)
                    .foregroundStyle(cloudKit.status == .notAvailable ? Color.orange : Color.accentColor)
                Text(cloudKit.status == .notAvailable
                     ? String(localized: "onboarding_icloud_off")
                     : String(localized: "onboarding_icloud_on"))
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard()

            if auth.isSignedIn {
                Button {
                    finish(signedIn: true)
                } label: {
                    Text(String(localized: "action_done"))
                        .frame(maxWidth: .infinity)
                }
                .dsPrimaryButton()
            } else {
                signInButtons
            }
        }
    }

    private var signInButtons: some View {
        VStack(spacing: DS.Spacing.sm) {
            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    finish(signedIn: true)
                    auth.handleAuthorization(authorization, context: context)
                case .failure(let error):
                    print("Sign in with Apple failed:", error.localizedDescription)
                }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 52)
            .clipShape(Capsule())

            Button {
                finish(signedIn: false)
            } label: {
                Text(String(localized: "onboarding_skip_sign_in"))
                    .frame(maxWidth: .infinity)
            }
            .dsSecondaryButton()

            Text(String(localized: "onboarding_sign_in_later"))
                .font(.caption)
                .foregroundStyle(DS.Text.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Pieces

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: item == step ? 22 : 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.sm) {
            if step != .welcome {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                        .frame(width: 44, height: 28)
                }
                .dsSecondaryButton()
                .accessibilityLabel(String(localized: "onboarding_back"))
            }

            Button {
                advance()
            } label: {
                Text(step == .welcome ? String(localized: "onboarding_start") : String(localized: "onboarding_continue"))
                    .frame(maxWidth: .infinity)
            }
            .dsPrimaryButton()
        }
    }

    private func pageTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(title)
                .font(.title2.weight(.bold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(DS.Text.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func featureRow(icon: String, title: String) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            Text(title)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func choiceChip(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            DS.haptic(0.4)
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(isSelected ? DS.Accent.onFill : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func permissionRow(
        icon: String,
        title: String,
        reason: String,
        state: PermissionState,
        request: @escaping () async -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(DS.Text.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            switch state {
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.green)
                    .accessibilityLabel(String(localized: "onboarding_permission_granted"))
            case .declined:
                Text(String(localized: "onboarding_permission_declined"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.Text.secondary)
            case .notAsked:
                Button {
                    Task { await request() }
                } label: {
                    Text(String(localized: "onboarding_permission_allow"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, 6)
                        .liquidGlassPill(interactive: true, tint: Color.accentColor.opacity(0.12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Flow

    private func advance() {
        if step == .aboutYou { saveAnswers() }
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func finish(signedIn: Bool) {
        saveAnswers()
        if let onFinish {
            onFinish()
            return
        }
        didSkipSignIn = !signedIn
        didCompleteOnboarding = true
    }

    /// A returning user on a new device may already have a synced profile: start from its answers.
    private func prefillFromProfile() {
        guard !didPrefill else { return }
        didPrefill = true
        guard let profile = CurrentUser.activeProfile(from: profiles, userIdentifier: auth.userIdentifier) else { return }
        let defaultNames: Set<String> = ["", "Me", String(localized: "profile_default_name")]
        if !defaultNames.contains(profile.displayName) { name = profile.displayName }
        workDressCode = profile.workDressCode
        warmth = Warmth(rawValue: profile.warmthSensitivity) ?? .average
    }

    private func saveAnswers() {
        let profile = UserProfile.current(in: context)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { profile.displayName = trimmed }
        if let workDressCode, workDressCode != profile.workDressCode {
            let hadAnswer = profile.workDressCode != nil
            profile.workDressCode = workDressCode
            if hadAnswer {
                // Replayed from Settings with a new answer: re-plan work days, as Settings does.
                NotificationCenter.default.post(
                    name: .calendarUnderstandingChanged,
                    object: nil,
                    userInfo: ["replanWorkDays": true]
                )
            }
        }
        // Keep a finer value from Settings when the user didn't move off "about average".
        if warmth != .average || Warmth(rawValue: profile.warmthSensitivity) != nil {
            profile.warmthSensitivity = warmth.rawValue
        }
        try? context.save()
    }

    // MARK: - Permissions

    private func readPermissionStates() async {
        switch CLLocationManager().authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: locationState = .granted
        case .denied, .restricted: locationState = .declined
        default: break
        }

        let calendarStatus = EKEventStore.authorizationStatus(for: .event)
        if calendarStatus == .fullAccess, CalendarContextPreferences.deviceCalendarEnabled {
            calendarState = .granted
        } else if calendarStatus == .denied || calendarStatus == .restricted {
            calendarState = .declined
        }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notificationState = .granted
        case .denied: notificationState = .declined
        default: break
        }
    }

    private func requestLocation() async {
        do {
            _ = try await LocationManager.shared.requestLocation()
            locationState = .granted
            await WeatherCenter.shared.refreshForecast(force: true, source: "Onboarding")
        } catch {
            let status = CLLocationManager().authorizationStatus
            locationState = (status == .authorizedWhenInUse || status == .authorizedAlways) ? .granted : .declined
        }
    }

    private func requestCalendar() async {
        calendarState = await CalendarContextService.shared.connect() ? .granted : .declined
    }

    private func requestNotifications() async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        notificationState = granted ? .granted : .declined
        if granted {
            await NotificationService.shared.scheduleDailyNotifications(context: context)
        }
    }
}
