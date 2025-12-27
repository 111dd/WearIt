
import Foundation
import AuthenticationServices

@MainActor
final class AuthManager: ObservableObject {
    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var userIdentifier: String?

    private let keychainService = KeychainService(service: "WearIt.Auth", account: "appleUserID")

    init() {
        // נסה לטעון מזהה משתמש מה־Keychain
        if let id = try? keychainService.read() {
            self.userIdentifier = id
            self.isSignedIn = true
            // ודא שהאישור עדיין בתוקף
            Task { await self.refreshCredentialStateIfNeeded() }
        } else {
            self.isSignedIn = false
        }
    }

    func handleAuthorization(_ auth: ASAuthorization) {
        switch auth.credential {
        case let appleIDCredential as ASAuthorizationAppleIDCredential:
            let userID = appleIDCredential.user
            do {
                try keychainService.save(userID)
                self.userIdentifier = userID
                self.isSignedIn = true
            } catch {
                print("Keychain save failed: \(error)")
            }
        default:
            break
        }
    }

    func signOut() {
        do {
            try keychainService.delete()
        } catch {
            print("Keychain delete failed: \(error)")
        }
        self.userIdentifier = nil
        self.isSignedIn = false
    }

    private func setSignedOutIfNeeded() {
        if self.isSignedIn {
            self.signOut()
        }
    }

    private func setSignedInIfNeeded(userID: String) {
        if !self.isSignedIn {
            self.userIdentifier = userID
            self.isSignedIn = true
        }
    }

    // בדיקת מצב האישור (רצוי כדי למנוע מצב שה־userID נשמר אבל כבר לא מאושר)
    func refreshCredentialStateIfNeeded() async {
        guard let id = userIdentifier else { return }
        let provider = ASAuthorizationAppleIDProvider()
        do {
            let state = try await provider.credentialState(forUserID: id)
            switch state {
            case .authorized:
                setSignedInIfNeeded(userID: id)
            case .revoked, .notFound, .transferred:
                setSignedOutIfNeeded()
            @unknown default:
                break
            }
        } catch {
            print("credentialState check failed: \(error)")
        }
    }
}
