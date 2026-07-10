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
    /// Prefer the signed-in Apple profile; otherwise a local (nil identifier) profile.
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

    static func fetchOrCreate(in context: ModelContext, userID: String) -> UserProfile {
        if let existing = try? context.fetch(FetchDescriptor<UserProfile>())
            .first(where: { $0.userIdentifier == userID }) {
            return existing
        }

        return createProfile(userIdentifier: userID, in: context)
    }

    private static func resolve(
        from profiles: [UserProfile],
        userIdentifier: String?
    ) -> UserProfile? {
        if let userIdentifier {
            if let match = profiles.first(where: { $0.userIdentifier == userIdentifier }) {
                return match
            }
            // Signed in but no matching profile yet — do not attach to another account.
            return nil
        }

        if let local = profiles.first(where: { $0.userIdentifier == nil }) {
            return local
        }
        return profiles.first
    }

    private static func createProfile(userIdentifier: String?, in context: ModelContext) -> UserProfile {
        let profile = UserProfile()
        profile.userIdentifier = userIdentifier
        context.insert(profile)
        try? context.save()
        return profile
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
