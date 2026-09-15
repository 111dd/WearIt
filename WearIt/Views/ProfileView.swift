import SwiftUI
import SwiftData
import UIKit

//
//  ProfileView.swift
//  WearIt
//
//  Identity-first profile page: editable avatar/name/bio, social-style stats
//  row, style identity chips (from the persisted TasteProfile), and a grid of
//  recent looks. App configuration lives in SettingsView (toolbar gear).
//

struct ProfileView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var auth: AuthManager

    @Query<UserProfile> private var users: [UserProfile]
    @Query(sort: \Garment.createdAt, order: .reverse) private var garments: [Garment]
    @Query private var dayPlans: [DayPlan]
    @Query private var dailyLooks: [DailyLook]
    @Query private var tasteProfiles: [TasteProfile]

    @State private var displayName: String = ""
    @State private var bio: String = ""
    @State private var avatarEmoji: String = "🧑🏻"
    @State private var avatarImagePath: String?
    @State private var avatarImage: UIImage?
    @State private var didLoadProfile = false
    @State private var showAvatarDialog = false
    @State private var showAvatarPicker = false
    @State private var profileSaveDebouncer = Debouncer(interval: 1.5)

    init() {
        _users = Query(FetchDescriptor<UserProfile>())

        var plans = FetchDescriptor<DayPlan>(
            sortBy: [SortDescriptor(\DayPlan.date, order: .reverse)]
        )
        plans.fetchLimit = 90
        _dayPlans = Query(plans)

        var looks = FetchDescriptor<DailyLook>(
            sortBy: [SortDescriptor(\DailyLook.date, order: .reverse)]
        )
        looks.fetchLimit = 30
        _dailyLooks = Query(looks)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.lg) {
                heroCard
                statsRow
                styleIdentitySection
                myLooksSection
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.sm)
            .padding(.bottom, DS.Spacing.lg)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(String(localized: "nav_profile"))
        .minimalCollapsingNavBar()
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
        .onChange(of: displayName) { _, _ in scheduleProfileSave() }
        .onChange(of: bio) { _, _ in scheduleProfileSave() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                saveProfile()
            }
        }
        .onDisappear { saveProfile() }
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
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(spacing: DS.Spacing.sm) {
            Button {
                DS.haptic(0.35)
                showAvatarDialog = true
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    avatarView
                        .frame(width: 96, height: 96)
                        .liquidGlassCircle()

                    Image(systemName: "camera.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Color.accentColor, in: Circle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "profile_avatar_change"))

            TextField(String(localized: "profile_display_name_placeholder"), text: $displayName)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .accessibilityLabel(String(localized: "profile_display_name"))

            TextField(String(localized: "profile_bio_placeholder"), text: $bio, axis: .vertical)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(1...3)
                .accessibilityLabel(String(localized: "profile_bio_placeholder"))

            HStack(spacing: DS.Spacing.xs) {
                if let memberSince {
                    Label(memberSince, systemImage: "calendar")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Label(
                    auth.isSignedIn
                        ? String(localized: "profile_signed_in")
                        : String(localized: "profile_signed_out"),
                    systemImage: auth.isSignedIn ? "checkmark.icloud" : "icloud.slash"
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .dsCard()
    }

    @ViewBuilder
    private var avatarView: some View {
        if let avatarImage {
            Image(uiImage: avatarImage)
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 96)
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

    private var memberSince: String? {
        guard let profile = activeProfile else { return nil }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        let dateText = formatter.string(from: profile.createdAt)
        return String(format: NSLocalizedString("profile_member_since_format", comment: ""), dateText)
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
            .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
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

    /// Worn-confirmed plans in the recent window (matches the calendar's 90-day scope).
    private var wornLooksCount: Int {
        dayPlans.filter { $0.wasWornConfirmed }.count
    }

    /// Consecutive days with a worn-confirmed look, ending today or yesterday.
    private var wearStreak: Int {
        let calendar = Calendar.current
        let wornDays = Set(
            dayPlans.filter { $0.wasWornConfirmed }.map { calendar.startOfDay(for: $0.date) }
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
        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                DSSectionHeader(String(localized: "profile_style_identity"), icon: "sparkles")

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
            .padding(DS.Spacing.sm)
            .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
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

    // MARK: - My Looks

    private var recentLookPhotos: [(id: String, path: String)] {
        var photos: [(id: String, path: String)] = []
        for look in dailyLooks {
            for path in look.photoPaths {
                photos.append((id: path, path: path))
                if photos.count >= 9 { return photos }
            }
        }
        return photos
    }

    private var myLooksSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "profile_my_looks"), icon: "photo.stack")

            let photos = recentLookPhotos
            if photos.isEmpty {
                Text(String(localized: "profile_looks_empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DS.Spacing.md)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.xxs), count: 3),
                    spacing: DS.Spacing.xxs
                ) {
                    ForEach(photos, id: \.id) { photo in
                        DSAsyncStoredImage(path: photo.path, height: 110, displayWidth: 120)
                            .contextMenu {
                                if let url = ImageStore.fileURL(path: photo.path) {
                                    ShareLink(item: url) {
                                        Label(String(localized: "action_share"), systemImage: "square.and.arrow.up")
                                    }
                                }
                            }
                    }
                }
            }
        }
        .padding(DS.Spacing.sm)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
    }

    // MARK: - Data

    private var activeProfile: UserProfile? {
        CurrentUser.activeProfile(from: users, userIdentifier: auth.userIdentifier)
    }

    private func loadOrCreateUser() {
        let me = fetchOrCreateProfile(userIdentifier: auth.userIdentifier)
        didLoadProfile = false
        avatarEmoji = me.avatarEmoji ?? "🧑🏻"
        avatarImagePath = me.avatarImagePath
        displayName = me.displayName
        bio = me.bio ?? ""
        didLoadProfile = true
    }

    private func scheduleProfileSave() {
        guard didLoadProfile else { return }
        profileSaveDebouncer.schedule {
            saveProfile()
        }
    }

    private func saveProfile() {
        guard didLoadProfile else { return }
        let me = fetchOrCreateProfile(userIdentifier: auth.userIdentifier)
        me.displayName = displayName.isEmpty ? (auth.displayName ?? String(localized: "profile_default_name")) : displayName
        let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        me.bio = trimmedBio.isEmpty ? nil : trimmedBio
        try? context.save()
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
        let maxPixel = 96 * UIScreen.main.scale
        let loaded: UIImage? = await Task.detached(priority: .utility) {
            ImageStore.loadThumbnail(path: path, maxPixelSize: maxPixel)
        }.value
        guard !Task.isCancelled else { return }
        avatarImage = loaded
    }

    private func fetchOrCreateProfile(userIdentifier uid: String?) -> UserProfile {
        let fd = FetchDescriptor<UserProfile>(
            sortBy: [SortDescriptor(\.createdAt)]
        )

        if let results = try? context.fetch(fd),
           let existing = results.first(where: { $0.userIdentifier == uid }) {
            return existing
        }

        let new = UserProfile()
        new.userIdentifier = uid
        new.displayName = auth.displayName ?? String(localized: "profile_default_name")
        new.email = auth.email
        context.insert(new)
        try? context.save()
        return new
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
                .lineLimit(1)
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
