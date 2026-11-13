import SwiftUI
import SwiftData
import UIKit

//
//  ProfileView.swift
//  WearIt
//
//  Identity and look photos first; sizes, shopping and learned insights live in
//  the owner's personal area. Profiles and posts remain private until publishing
//  exists. App configuration lives in SettingsView (toolbar gear).
//

struct ProfileView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var auth: AuthManager

    @Query<UserProfile> private var users: [UserProfile]
    @Query(sort: \Garment.createdAt, order: .reverse) private var garments: [Garment]
    @Query private var dayPlans: [DayPlan]
    @Query(sort: \LookPost.lookDate, order: .reverse) private var lookPosts: [LookPost]
    @Query private var tasteProfiles: [TasteProfile]
    @Query private var recoStates: [RecoState]
    @Query private var wearEvents: [WearEvent]

    @State private var avatarEmoji: String = "🧑🏻"
    @State private var avatarImagePath: String?
    @State private var avatarImage: UIImage?
    @State private var showEditProfile = false
    @State private var showAvatarDialog = false
    @State private var showAvatarPicker = false
    @State private var showStyleSwipe = false
    @State private var showLookCapture = false
    @State private var shoppingPreferencesProfile: UserProfile?
    @State private var selectedSection: ProfileSection = .looks
    @Namespace private var lookTransition

    private let avatarDiameter: CGFloat = 80

    private enum ProfileSection: String, CaseIterable, Identifiable {
        case looks, personal

        var id: String { rawValue }

        var title: String {
            switch self {
            case .looks: return String(localized: "profile_my_looks")
            case .personal: return String(localized: "profile_personal_area")
            }
        }

        var icon: String {
            switch self {
            case .looks: return "photo.stack"
            case .personal: return "lock"
            }
        }
    }

    init() {
        _users = Query(FetchDescriptor<UserProfile>())

        var plans = FetchDescriptor<DayPlan>(
            sortBy: [SortDescriptor(\DayPlan.date, order: .reverse)]
        )
        plans.fetchLimit = 90
        _dayPlans = Query(plans)

        var wears = FetchDescriptor<WearEvent>(
            sortBy: [SortDescriptor(\WearEvent.date, order: .reverse)]
        )
        wears.fetchLimit = 300
        _wearEvents = Query(wears)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.lg) {
                heroCard
                sectionPicker
                switch selectedSection {
                case .looks:
                    looksSection
                case .personal:
                    personalArea
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.sm)
            .padding(.bottom, DS.Spacing.lg)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(String(localized: "nav_profile"))
        .compactNavBar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                        .withLocalAppBackdrop()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(String(localized: "settings_title"))
            }
        }
        .onAppear { loadOrCreateUser() }
        .onChange(of: auth.userIdentifier) { _, _ in loadOrCreateUser() }
        .sheet(isPresented: $showEditProfile) {
            EditProfileView(profile: fetchOrCreateProfile(userIdentifier: auth.userIdentifier))
        }
        .sheet(isPresented: $showAvatarPicker) {
            PhotoLibraryPickerWrapper { image in
                applyAvatarImage(image)
            }
        }
        .confirmationDialog(
            String(localized: "profile_avatar_change"),
            isPresented: $showAvatarDialog,
            titleVisibility: .visible
        ) {
            Button(String(localized: "garment_choose_library")) {
                showAvatarPicker = true
            }
            if avatarImagePath != nil {
                Button(String(localized: "profile_avatar_remove_photo"), role: .destructive) {
                    removeAvatarImage()
                }
            }
            Button(String(localized: "action_cancel"), role: .cancel) {}
        }
        .task(id: avatarImagePath) {
            await loadAvatarPreview()
        }
        .fullScreenCover(isPresented: $showStyleSwipe) {
            StyleSwipeView(deckSize: StyleSwipeSchedule.nextDeckSize)
                .environmentObject(auth)
        }
        .sheet(isPresented: $showLookCapture) {
            LookCaptureView(lookDate: Date())
        }
        .sheet(item: $shoppingPreferencesProfile) { profile in
            ShoppingPreferencesView(profile: profile)
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    avatarButton
                    identityText
                }
            } else {
                HStack(spacing: DS.Spacing.md) {
                    avatarButton
                    identityText
                }
            }

            if let bio = activeProfile?.bio, !bio.isEmpty {
                Text(bio)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                showEditProfile = true
            } label: {
                Label(String(localized: "edit_profile_title"), systemImage: "pencil")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .dsSecondaryButton()
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface()
    }

    private var avatarButton: some View {
        Button {
            DS.haptic(0.35)
            showAvatarDialog = true
        } label: {
            ZStack(alignment: .bottomTrailing) {
                avatarView
                    .frame(width: avatarDiameter, height: avatarDiameter)
                    .background(DS.Surface.canvas, in: Circle())

                Image(systemName: "camera.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(DS.Accent.onFill)
                    .padding(6)
                    .background(Color.accentColor, in: Circle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "profile_avatar_change"))
    }

    private var identityText: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(heroName)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if let username = activeProfile?.username, !username.isEmpty {
                Text("@\(username)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .environment(\.layoutDirection, .leftToRight)
            }

            if let styleSummary {
                Label(styleSummary, systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(String(format: String(localized: "profile_style_summary_format"), styleSummary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var styleSummary: String? {
        guard let taste = activeTasteProfile, taste.sourceGarmentCount > 0 else { return nil }
        let titles = taste.topStyleRawValues.compactMap { StyleTag(rawValue: $0)?.title }.prefix(2)
        return titles.isEmpty ? nil : titles.joined(separator: " · ")
    }

    @ViewBuilder
    private var avatarView: some View {
        if let avatarImage {
            Image(uiImage: avatarImage)
                .resizable()
                .scaledToFill()
                .frame(width: avatarDiameter, height: avatarDiameter)
                .clipShape(Circle())
        } else if avatarEmoji.isEmpty {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
        } else {
            Text(avatarEmoji)
                .font(.system(size: 44))
        }
    }

    private var heroName: String {
        let name = activeProfile?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? String(localized: "profile_default_name") : name
    }

    private var memberSince: String? {
        guard let profile = activeProfile else { return nil }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        let dateText = formatter.string(from: profile.createdAt)
        return String(format: NSLocalizedString("profile_member_since_format", comment: ""), dateText)
    }

    // MARK: - Profile sections

    @ViewBuilder
    private var sectionPicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: DS.Spacing.xs) {
                ForEach(ProfileSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        HStack(spacing: DS.Spacing.sm) {
                            Label(section.title, systemImage: section.icon)
                            Spacer(minLength: 0)
                            if selectedSection == section {
                                Image(systemName: "checkmark")
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(minHeight: 44)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.xs)
                        .contentSurface(emphasized: selectedSection == section)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
                }
            }
        } else {
            Picker(String(localized: "profile_sections"), selection: $selectedSection) {
                ForEach(ProfileSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
        }
    }

    private var looksSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Label(String(localized: "profile_looks_private_notice"), systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LookPostGridSection(
                posts: LookPostStore.gridOrder(lookPosts),
                namespace: lookTransition,
                onAdd: { showLookCapture = true }
            )
        }
    }

    private var personalArea: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Label(String(localized: "profile_personal_private_title"), systemImage: "lock.fill")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(String(localized: "profile_personal_private_detail"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: DS.Spacing.sm) {
                mySizesRow
                shoppingPreferencesRow
                savedProductsRow
            }

            styleIdentitySection
            formulasSection
            styleSwipeRow

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                DSSectionHeader(String(localized: "stats_title"), icon: "chart.bar")
                statsRow
            }

            accountSummary
        }
    }

    private var savedProductsRow: some View {
        NavigationLink {
            ShopPicksView(initialSavedOnly: true)
                .withLocalAppBackdrop()
        } label: {
            ProfileActionLabel(
                title: String(localized: "profile_saved_products"),
                detail: String(localized: "profile_saved_products_detail"),
                icon: "heart"
            )
        }
        .buttonStyle(.plain)
        .contentSurface()
    }

    private var accountSummary: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if let memberSince {
                Label(memberSince, systemImage: "calendar")
            }
            Label(
                auth.isSignedIn
                    ? String(localized: "profile_signed_in")
                    : String(localized: "profile_signed_out"),
                systemImage: auth.isSignedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle"
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        NavigationLink {
            StatsView()
                .withLocalAppBackdrop()
        } label: {
            HStack(spacing: 0) {
                profileStat(value: "\(garments.count)", title: String(localized: "profile_stat_items"))
                statDivider
                profileStat(value: "\(wornLooksCount)", title: String(localized: "profile_stat_looks"))
                statDivider
                profileStat(value: "\(wearStreak)", title: String(localized: "profile_stat_streak"))
            }
            .padding(.vertical, DS.Spacing.sm)
            .contentSurface()
        }
        .buttonStyle(.plain)
        .accessibilityHint(String(localized: "stats_title"))
    }

    private func profileStat(value: String, title: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 28)
    }

    /// Day and evening looks in the bounded recent-plan window.
    private var wornLooksCount: Int {
        dayPlans.reduce(0) { count, plan in
            count + (plan.resolvedDayLookWearStatus == .worn ? 1 : 0)
                + (plan.eveningLookWearStatus == .worn ? 1 : 0)
        }
    }

    /// Consecutive days with a worn-confirmed look, ending today or yesterday.
    private var wearStreak: Int {
        let calendar = Calendar.current
        let wornDays = Set(
            dayPlans.filter {
                $0.resolvedDayLookWearStatus == .worn || $0.eveningLookWearStatus == .worn
            }.map { calendar.startOfDay(for: $0.date) }
        )
        guard !wornDays.isEmpty else { return 0 }

        var day = calendar.startOfDay(for: Date())
        if !wornDays.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }

        var streak = 0
        while wornDays.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    // MARK: - Style Identity

    @ViewBuilder
    private var styleIdentitySection: some View {
        let chips = styleIdentityChips
        let insights = styleInsights
        if !chips.isEmpty || !insights.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                DSSectionHeader(String(localized: "profile_style_identity"), icon: "sparkles")

                ForEach(insights, id: \.self) { insight in
                    Label(StyleInsights.text(insight), systemImage: StyleInsights.icon(insight))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }

                if !chips.isEmpty {
                    LiquidGlassGroup(spacing: DS.Spacing.xs) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 110), spacing: DS.Spacing.xs)],
                            alignment: .leading,
                            spacing: DS.Spacing.xs
                        ) {
                            ForEach(chips) { chip in
                                StyleIdentityChip(chip: chip)
                            }
                        }
                    }
                }
            }
            .padding(DS.Spacing.sm)
            .contentSurface()
        }
    }

    private var activeRecoState: RecoState? {
        let profileID = activeProfile?.id
        return recoStates.first(where: { $0.profileID == profileID })
            ?? recoStates.first(where: { $0.profileID == nil && $0.id == "global" })
    }

    private var styleInsights: [StyleInsights.Insight] {
        guard let state = activeRecoState else { return [] }
        return StyleInsights.insights(from: state)
    }

    // MARK: - Formulas

    @ViewBuilder
    private var formulasSection: some View {
        let formulas = LookFormulas.compute(
            wearEvents: wearEvents,
            garmentsByID: Dictionary(garments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        )
        if !formulas.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                DSSectionHeader(String(localized: "profile_formulas_title"), icon: "square.stack.3d.up")
                ForEach(formulas) { formula in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(formula.parts.joined(separator: " + "))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(String(format: NSLocalizedString("profile_formula_worn_format", comment: ""), formula.timesWorn))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(DS.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentSurface()
        }
    }

    // MARK: - Style Swipe

    private var styleSwipeRow: some View {
        let progress = AIRecommender.shared.learningProgress(profileID: activeProfile?.id, modelContext: context)
        let percent = Int((progress * 100).rounded())
        return Button {
            DS.haptic(0.35)
            showStyleSwipe = true
        } label: {
            ProfileActionLabel(
                title: String(localized: "style_swipe_title"),
                detail: String(format: NSLocalizedString("style_swipe_progress_format", comment: ""), percent),
                icon: "rectangle.stack.fill"
            )
        }
        .buttonStyle(.plain)
        .contentSurface()
    }

    // MARK: - My Sizes

    @ViewBuilder
    private var mySizesRow: some View {
        if let profile = activeProfile {
            NavigationLink {
                MySizesView(profile: profile)
                    .withLocalAppBackdrop()
            } label: {
                ProfileActionLabel(
                    title: String(localized: "my_sizes_title"),
                    detail: MySizesView.summary(for: profile) ?? String(localized: "my_sizes_row_empty"),
                    icon: "ruler.fill"
                )
            }
            .buttonStyle(.plain)
            .contentSurface()
        }
    }

    @ViewBuilder
    private var shoppingPreferencesRow: some View {
        if let profile = activeProfile {
            Button {
                shoppingPreferencesProfile = profile
            } label: {
                ProfileActionLabel(
                    title: String(localized: "shop_preferences_title"),
                    detail: String(localized: "shop_preferences_row_detail"),
                    icon: "bag"
                )
            }
            .buttonStyle(.plain)
            .contentSurface()
        }
    }

    private var activeTasteProfile: TasteProfile? {
        let profileID = activeProfile?.id
        return tasteProfiles.first(where: { $0.profileID == profileID })
            ?? tasteProfiles.first(where: { $0.profileID == nil })
    }

    private var styleIdentityChips: [StyleIdentityChipModel] {
        guard let taste = activeTasteProfile, taste.sourceGarmentCount > 0 else { return [] }
        var chips: [StyleIdentityChipModel] = []

        for raw in taste.topStyleRawValues.prefix(2) {
            if let tag = StyleTag(rawValue: raw) {
                chips.append(StyleIdentityChipModel(id: "style-\(raw)", text: tag.title, icon: "sparkle", dotColor: nil))
            }
        }

        for raw in taste.topColorRawValues.prefix(3) {
            if let tag = ColorTag(rawValue: raw) {
                chips.append(StyleIdentityChipModel(id: "color-\(raw)", text: tag.title, icon: nil, dotColor: tag.color))
            }
        }

        let brandNames = brandNamesByKey
        for key in taste.topBrandKeys.prefix(2) {
            if let name = brandNames[key] {
                chips.append(StyleIdentityChipModel(id: "brand-\(key)", text: name, icon: "tag", dotColor: nil))
            }
        }

        return chips
    }

    private var brandNamesByKey: [String: String] {
        var map: [String: String] = [:]
        for garment in garments {
            guard let brand = garment.brand?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !brand.isEmpty else { continue }
            let key = BrandStore.normalizeBrandKey(brand)
            if map[key] == nil { map[key] = brand }
        }
        return map
    }

    // MARK: - Data

    private var activeProfile: UserProfile? {
        CurrentUser.activeProfile(from: users, userIdentifier: auth.userIdentifier)
    }

    private func loadOrCreateUser() {
        let me = fetchOrCreateProfile(userIdentifier: auth.userIdentifier)
        avatarEmoji = me.avatarEmoji ?? "🧑🏻"
        avatarImagePath = me.avatarImagePath
    }

    private func applyAvatarImage(_ image: UIImage) {
        guard let path = try? ImageStore.save(image: image.avatarSized(max: 512)) else { return }
        let me = fetchOrCreateProfile(userIdentifier: auth.userIdentifier)
        if let old = me.avatarImagePath {
            ImageStore.delete(path: old)
        }
        me.avatarImagePath = path
        avatarImagePath = path
        try? context.save()
        DS.haptic(0.5)
    }

    private func removeAvatarImage() {
        let me = fetchOrCreateProfile(userIdentifier: auth.userIdentifier)
        if let old = me.avatarImagePath {
            ImageStore.delete(path: old)
        }
        me.avatarImagePath = nil
        avatarImagePath = nil
        avatarImage = nil
        try? context.save()
    }

    private func loadAvatarPreview() async {
        guard let path = avatarImagePath else {
            avatarImage = nil
            return
        }
        let maxPixel = avatarDiameter * UIScreen.main.scale
        let loaded: UIImage? = await Task.detached(priority: .utility) {
            ImageStore.loadThumbnail(path: path, maxPixelSize: maxPixel)
        }.value
        guard !Task.isCancelled else { return }
        avatarImage = loaded
    }

    private func fetchOrCreateProfile(userIdentifier uid: String?) -> UserProfile {
        if let profile = CurrentUser.activeProfile(in: context, userIdentifier: uid) {
            return profile
        }
        return UserProfile.current(in: context)
    }
}

// MARK: - Personal area navigation

private struct ProfileActionLabel: View {
    let title: String
    let detail: String
    let icon: String

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .padding(DS.Spacing.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Style Identity Chip

private struct StyleIdentityChipModel: Identifiable {
    let id: String
    let text: String
    let icon: String?
    let dotColor: Color?
}

private struct StyleIdentityChip: View {
    let chip: StyleIdentityChipModel

    var body: some View {
        HStack(spacing: DS.Spacing.xxs) {
            if let dotColor = chip.dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            } else if let icon = chip.icon {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(chip.text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassPill()
    }
}

// MARK: - Avatar resize helper

private extension UIImage {
    func avatarSized(max: CGFloat) -> UIImage {
        let maxSide = Swift.max(size.width, size.height)
        guard maxSide > max else { return self }
        let scale = max / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
