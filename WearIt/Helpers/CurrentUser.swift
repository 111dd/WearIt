//
//  CurrentUser.swift
//  WearIt
//
//  Created by Dor David on 21/10/2025.
//

import SwiftData

enum CurrentUser {
    static func fetchOrCreate(in context: ModelContext, userID: String) -> UserProfile {
        // Avoid #Predicate macro: fetch and filter in Swift
        if let existing = try? context.fetch(FetchDescriptor<UserProfile>())
            .first(where: { $0.userIdentifier == userID }) {
            return existing
        }

        // Create new user and attach the Sign in with Apple identifier
        let u = UserProfile()
        u.userIdentifier = userID
        context.insert(u)
        try? context.save()
        return u
    }
}
