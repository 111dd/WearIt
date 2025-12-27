import SwiftUI
import AuthenticationServices

struct SignInView: View {
    @ObservedObject var auth: AuthManager
    @State private var lastMessage: String?
    @State private var showAlert = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Text("WearIt")
                    .font(.largeTitle.bold())
                Text("Sign in to keep your wardrobe personalized across devices.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            // כפתור SwiftUI הסטנדרטי
            SignInWithAppleButton(.signIn) { request in
                print("SIWA request() called")
                lastMessage = "Preparing request…"
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                switch result {
                case .success(let authResult):
                    print("SIWA success")
                    lastMessage = "Success"
                    auth.handleAuthorization(authResult)
                case .failure(let error):
                    print("SIWA failed: \(error.localizedDescription)")
                    lastMessage = "Error: \(error.localizedDescription)"
                    showAlert = true
                }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .padding(.horizontal)

            // כפתור חלופי (זרימה ידנית) לקבלת שגיאות מפורטות אם הסטנדרטי לא פותח חלון
            Button {
                startManualSignIn()
            } label: {
                Text("Try manual Sign in with Apple")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)

            if let msg = lastMessage {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            Spacer()

            Text("By continuing, you agree to our Terms and Privacy Policy.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        .background(Color(.systemGroupedBackground))
        .alert("Sign in with Apple", isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(lastMessage ?? "Unknown error")
        }
    }

    // MARK: - Manual flow for diagnostics

    private func startManualSignIn() {
        print("Manual SIWA started")
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = ManualDelegate { result in
            switch result {
            case .success(let authResult):
                print("Manual SIWA success")
                lastMessage = "Success (manual)"
                auth.handleAuthorization(authResult)
            case .failure(let err):
                print("Manual SIWA failed: \(err.localizedDescription)")
                lastMessage = "Error (manual): \(err.localizedDescription)"
                showAlert = true
            }
        }
        controller.presentationContextProvider = ManualPresentationAnchor()
        controller.performRequests()
    }
}

// MARK: - Helpers (manual delegate/presentation)

private final class ManualDelegate: NSObject, ASAuthorizationControllerDelegate {
    let onComplete: (Result<ASAuthorization, Error>) -> Void
    init(onComplete: @escaping (Result<ASAuthorization, Error>) -> Void) {
        self.onComplete = onComplete
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        onComplete(.success(authorization))
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        onComplete(.failure(error))
    }
}

private final class ManualPresentationAnchor: NSObject, ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // נסיון למצוא חלון קיים להצגה
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let win = scene.keyWindow ?? scene.windows.first {
            return win
        }
        return UIApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? { windows.first(where: { $0.isKeyWindow }) }
}
