import SwiftUI
import AuthenticationServices
import SwiftData

struct SignInView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var cloudKit: CloudKitSyncMonitor
    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false
    @AppStorage("didSkipSignIn") private var didSkipSignIn = false

    var body: some View {
        ZStack {
            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 12) {
                    Image(systemName: "tshirt.fill")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, .white.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Color.black.opacity(0.2), radius: 12, x: 0, y: 6)
                    
                    Text("WearIt")
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, .white.opacity(0.9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)

                    Text("Sign in to keep your wardrobe\npersonalized across devices.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.9))
                        .font(.headline)
                        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                }
                .padding(.horizontal)

                // כרטיס זכוכית משופר
                VStack(spacing: 20) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.secondary)
                        Text("Fast & Private")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }

                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        switch result {
                        case .success(let authResult):
                            auth.handleAuthorization(authResult, context: context)
                            didCompleteOnboarding = true
                            didSkipSignIn = false
                        case .failure(let error):
                            print("Sign in with Apple failed:", error.localizedDescription)
                        }
                    }
                    .signInWithAppleButtonStyle(.whiteOutline)
                    .frame(height: 56)
                    .clipShape(Capsule())
                    .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 6)

                    Button {
                        didSkipSignIn = true
                        didCompleteOnboarding = true
                    } label: {
                        Text(String(localized: "signin_continue_offline"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.12), in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.6)
                            )
                    }
                    .buttonStyle(.plain)
                    
                    if cloudKit.status == .notAvailable {
                        Text(String(localized: "signin_icloud_guidance"))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                    }
                }
                .glassCard(corner: 28, intensity: .thin)

                Spacer()

                Text("By continuing, you agree to our Terms and Privacy Policy.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 20)
            }
        }
    }
}
