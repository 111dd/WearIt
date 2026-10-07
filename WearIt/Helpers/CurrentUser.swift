//
//  CurrentUser.swift
//  WearIt
//
//  Auth-aware profile resolution for Sign in with Apple + skip/offline mode.
//

import SwiftData
import Foundation

@MainActor
enum CurrentUser {
    /// Prefer the signed-in Apple profile; otherwise the main profile (one person per iCloud account).
    /// Creates a profile when needed so DayPlan ownership never fails.
    @discardableResult
    static func activeProfile(
        in context: ModelContext,
        userIdentifier: String?,
        createIfNeeded: Bool = true
    ) -> UserProfile? {
        let profiles = (try? context.fetch(FetchDescriptor<UserProfile>())) ?? []
        if let resolved = resolve(from: profiles, userIdentifier: userIdentifier) {
            return resolved
        }

        guard createIfNeeded else { return nil }
        return createProfile(userIdentifier: userIdentifier, in: context)
    }

    /// Convenience using the shared auth session.
    @discardableResult
    static func activeProfile(
        in context: ModelContext,
        createIfNeeded: Bool = true
    ) -> UserProfile? {
        activeProfile(
            in: context,
            userIdentifier: AuthManager.shared.userIdentifier,
            createIfNeeded: createIfNeeded
        )
    }

    /// Resolve from an already-fetched profile list (SwiftUI `@Query`).
    /// Does not create profiles.
    static func activeProfile(
        from profiles: [UserProfile],
        userIdentifier: String?
    ) -> UserProfile? {
        resolve(from: profiles, userIdentifier: userIdentifier)
    }

    /// Signing in claims the current profile instead of starting an empty one,
    /// so sizes, answers and everything learned so far stay with the user.
    @discardableResult
    static func adopt(userIdentifier: String, in context: ModelContext) -> UserProfile {
        let profile = activeProfile(in: context, userIdentifier: userIdentifier)
            ?? createProfile(userIdentifier: userIdentifier, in: context)
        if profile.userIdentifier != userIdentifier {
            profile.userIdentifier = userIdentifier
        }
        return profile
    }

    private static func resolve(
        from profiles: [UserProfile],
        userIdentifier: String?
    ) -> UserProfile? {
        if let userIdentifier,
           let match = profiles.first(where: { $0.userIdentifier == userIdentifier }) {
            return match
        }
        // One person per iCloud account: without an exact match the main profile is "me",
        // so signing in after skipping, or signing out, never switches to an empty profile.
        return profiles.min(by: isPreferred)
    }

    /// Same order on every device: a profile that was signed in to (the one in use since then)
    /// comes first, then the oldest, ties broken by id.
    private static func isPreferred(_ a: UserProfile, _ b: UserProfile) -> Bool {
        let aSignedIn = a.userIdentifier != nil
        let bSignedIn = b.userIdentifier != nil
        if aSignedIn != bSignedIn { return aSignedIn }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    private static func createProfile(userIdentifier: String?, in context: ModelContext) -> UserProfile {
        let profile = UserProfile()
        profile.userIdentifier = userIdentifier
        profile.displayName = String(localized: "profile_default_name")
        context.insert(profile)
        try? context.save()
        return profile
    }
}

// MARK: - Duplicate profiles

extension CurrentUser {
    /// Folds duplicate profiles into the main one (see `isPreferred`). Duplicates come from two devices that
    /// each created a profile before iCloud synced, or from older builds that started a new
    /// profile on sign-in. Every device picks the same keeper, so the merge converges.
    static func mergeDuplicateProfiles(in context: ModelContext) {
        guard let profiles = try? context.fetch(FetchDescriptor<UserProfile>()),
              profiles.count > 1 else { return }
        let sorted = profiles.sorted(by: isPreferred)
        let keeper = sorted[0]
        for duplicate in sorted.dropFirst() {
            absorb(duplicate, into: keeper)
            moveOwnedRecords(from: duplicate.id, to: keeper.id, in: context)
            context.delete(duplicate)
        }
        try? context.save()
    }

    /// Fills the keeper's unanswered fields from the duplicate; answers already on the keeper win.
    private static func absorb(_ other: UserProfile, into keeper: UserProfile) {
        if keeper.userIdentifier == nil { keeper.userIdentifier = other.userIdentifier }
        let defaultNames: Set<String> = ["", "Me", String(localized: "profile_default_name")]
        if defaultNames.contains(keeper.displayName), !defaultNames.contains(other.displayName) {
            keeper.displayName = other.displayName
        }
        if keeper.avatarImagePath == nil { keeper.avatarImagePath = other.avatarImagePath }
        if keeper.avatarEmoji == nil { keeper.avatarEmoji = other.avatarEmoji }
        if keeper.email == nil { keeper.email = other.email }
        if keeper.phone == nil { keeper.phone = other.phone }
        if keeper.bio == nil { keeper.bio = other.bio }
        if keeper.workDressCodeRaw == nil { keeper.workDressCodeRaw = other.workDressCodeRaw }
        if keeper.topSizeRaw == nil { keeper.topSizeRaw = other.topSizeRaw }
        if keeper.bottomSizeRaw == nil { keeper.bottomSizeRaw = other.bottomSizeRaw }
        if keeper.shoeSizeRaw == nil { keeper.shoeSizeRaw = other.shoeSizeRaw }
        if keeper.heightCm == nil { keeper.heightCm = other.heightCm }
        if keeper.chestCm == nil { keeper.chestCm = other.chestCm }
        if keeper.waistCm == nil { keeper.waistCm = other.waistCm }
        if keeper.hipsCm == nil { keeper.hipsCm = other.hipsCm }
        if keeper.inseamCm == nil { keeper.inseamCm = other.inseamCm }
        // 3 is the untouched slider value.
        if keeper.preferredFormality == 3 { keeper.preferredFormality = other.preferredFormality }
        if keeper.warmthSensitivity == 3 { keeper.warmthSensitivity = other.warmthSensitivity }
        if keeper.rainTolerance == 3 { keeper.rainTolerance = other.rainTolerance }
        keeper.garmentIDs = mergedIDs(keeper.garmentIDs, other.garmentIDs)
        keeper.outfitIDs = mergedIDs(keeper.outfitIDs, other.outfitIDs)
        keeper.dayPlanIDs = mergedIDs(keeper.dayPlanIDs, other.dayPlanIDs)
        keeper.dailyLookIDs = mergedIDs(keeper.dailyLookIDs, other.dailyLookIDs)
    }

    private static func mergedIDs(_ a: [UUID], _ b: [UUID]) -> [UUID] {
        var seen = Set(a)
        return a + b.filter { seen.insert($0).inserted }
    }

    private static func moveOwnedRecords(from oldID: UUID, to newID: UUID, in context: ModelContext) {
        let old: UUID? = oldID
        for item in (try? context.fetch(FetchDescriptor<Garment>(predicate: #Predicate { $0.ownerID == old }))) ?? [] {
            item.ownerID = newID
        }
        for item in (try? context.fetch(FetchDescriptor<Outfit>(predicate: #Predicate { $0.ownerID == old }))) ?? [] {
            item.ownerID = newID
        }
        for item in (try? context.fetch(FetchDescriptor<DayPlan>(predicate: #Predicate { $0.ownerID == old }))) ?? [] {
            item.ownerID = newID
        }
        for item in (try? context.fetch(FetchDescriptor<DailyLook>(predicate: #Predicate { $0.ownerID == old }))) ?? [] {
            item.ownerID = newID
        }
        for event in (try? context.fetch(FetchDescriptor<RecommendationEvent>(predicate: #Predicate { $0.profileID == old }))) ?? [] {
            event.profileID = newID
        }

        // Learned weights: keep whichever state has learned more.
        let states = (try? context.fetch(FetchDescriptor<RecoState>())) ?? []
        if let moving = states.first(where: { $0.profileID == oldID }) {
            if let kept = states.first(where: { $0.profileID == newID }) {
                if learnedSignals(moving) > learnedSignals(kept) {
                    context.delete(kept)
                    rekey(moving, to: newID)
                } else {
                    context.delete(moving)
                }
            } else {
                rekey(moving, to: newID)
            }
        }

        // Taste is rebuilt from the wardrobe; keep one snapshot.
        let tastes = (try? context.fetch(FetchDescriptor<TasteProfile>())) ?? []
        if let moving = tastes.first(where: { $0.profileID == oldID }) {
            if tastes.contains(where: { $0.profileID == newID }) {
                context.delete(moving)
            } else {
                moving.profileID = newID
                moving.id = "profile-\(newID.uuidString)"
            }
        }
    }

    private static func learnedSignals(_ state: RecoState) -> Int {
        state.interactionCount + (state.lookInteractions ?? 0)
    }

    private static func rekey(_ state: RecoState, to profileID: UUID) {
        state.profileID = profileID
        state.id = "profile-\(profileID.uuidString)"
    }
}

extension UserProfile {
    /// Auth-aware current profile. Prefer `CurrentUser.activeProfile` at call sites.
    @MainActor
    static func current(in context: ModelContext) -> UserProfile {
        if let profile = CurrentUser.activeProfile(in: context, createIfNeeded: true) {
            return profile
        }
        let profile = UserProfile()
        profile.userIdentifier = AuthManager.shared.userIdentifier
        context.insert(profile)
        return profile
    }
}
