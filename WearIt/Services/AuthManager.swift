import Foundation
import AuthenticationServices
import SwiftData
import Combine

@MainActor
final class AuthManager: NSObject, ObservableObject {
    static let shared = AuthManager()

    @Published private(set) var isSignedIn = false
    @Published private(set) var userIdentifier: String?
    @Published private(set) var displayName: String?
    @Published private(set) var email: String?

    // נשמור userIdentifier באופן מאובטח (פשוט) כדי לבדוק מצב התחברות
    private let keychainKey = "appleUserIdentifier"

    private override init() {
        super.init()
        let storedID = Keychain.read(key: keychainKey)
        updateIfChanged(&userIdentifier, storedID)
        updateIfChanged(&isSignedIn, storedID != nil)
    }

    // קריאה מתוך המסך: auth.handleAuthorization(authResult, context: context)
    func handleAuthorization(_ authResult: ASAuthorization, context: ModelContext) {
        guard let credential = authResult.credential as? ASAuthorizationAppleIDCredential else {
            return
        }

        // מזהה קבוע של אפל למפתח השרת שלך
        let userID = credential.user
        updateIfChanged(&userIdentifier, userID)
        Keychain.save(key: keychainKey, value: userID)

        // שם מלא ואימייל — יופיעו רק בפעם הראשונה (אחר כך לעתים קרובות חוזר nil)
        let fullName = credential.fullName?.formatted(.name(style: .medium))
        let email = credential.email

        // עדכון SwiftData: נמצא/ניצור UserProfile לפי userIdentifier
        let profile = upsertUserProfile(
            userIdentifier: userID,
            fullName: fullName,
            email: email,
            context: context
        )

        updateIfChanged(&displayName, profile.displayName)
        updateIfChanged(&self.email, profile.email)
        updateIfChanged(&isSignedIn, true)
    }

    func signOut() {
        // לא מוחקים את הנתונים, רק מנתקים את הסשן המקומי
        if let userID = self.userIdentifier {
            Keychain.delete(key: keychainKey)
            #if DEBUG
            print("Signed out user \(userID)")
            #endif
        }
        updateIfChanged(&userIdentifier, nil)
        updateIfChanged(&displayName, nil)
        updateIfChanged(&email, nil)
        updateIfChanged(&isSignedIn, false)
    }

    /// בדיקת סטטוס אשרור מול אפל (אם האפל קבע שמצב החשבון בוטל/בוטל קישור)
    func refreshCredentialStateIfNeeded() async {
        guard let userID = self.userIdentifier else { return }
        let provider = ASAuthorizationAppleIDProvider()
        do {
            let state = try await provider.credentialState(forUserID: userID)
            switch state {
            case .authorized:
                updateIfChanged(&isSignedIn, true)
            case .revoked, .notFound, .transferred:
                // ננקה לוקלי
                self.signOut()
            @unknown default:
                break
            }
        } catch {
            // אם נכשל — לא נשבור את ה־UI
            print("credentialState check failed:", error.localizedDescription)
        }
    }

    // MARK: - SwiftData integration

    private func upsertUserProfile(
        userIdentifier: String,
        fullName: String?,
        email: String?,
        context: ModelContext
    ) -> UserProfile {
        // נסה לאתר פרופיל קיים
        let fetch = FetchDescriptor<UserProfile>(
            predicate: #Predicate { $0.userIdentifier == userIdentifier },
            sortBy: []
        )
        if let existing = try? context.fetch(fetch).first {
            // לא לדרוס ערכים קיימים ב-nil
            if let fn = fullName, !fn.isEmpty { existing.displayName = fn }
            if let em = email, !em.isEmpty { existing.email = em }
            try? context.save()
            return existing
        }

        // לא קיים — ניצור חדש
        let profile = UserProfile()
        profile.userIdentifier = userIdentifier
        if let fn = fullName, !fn.isEmpty { profile.displayName = fn }
        if let em = email, !em.isEmpty { profile.email = em }
        context.insert(profile)
        try? context.save()
        return profile
    }

    private func updateIfChanged<T: Equatable>(_ target: inout T, _ newValue: T) {
        if target != newValue {
            target = newValue
        }
    }

    private func updateIfChanged<T: Equatable>(_ target: inout T?, _ newValue: T?) {
        if target != newValue {
            target = newValue
        }
    }
}

// MARK: - Very small keychain helper

enum Keychain {
    static func save(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      key,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary) // מחיקה אם קיים
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      key,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
