import SwiftUI
import AuthenticationServices
import SwiftData

struct SignInView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var cloudKit: CloudKitSyncMonitor
    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false
    @AppStorage("didSkipSignIn") private var didSkipSignIn = false
    @State private var showPrivacyPolicy = false

    var body: some View {
        content
            .withLocalAppBackdropPainted()
            .sheet(isPresented: $showPrivacyPolicy) {
                NavigationStack {
                    PrivacyPolicyView()
                }
            }
    }

    private var content: some View {
        ZStack {
            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 12) {
                    Image(systemName: "tshirt.fill")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                    
                    Text("WearIt")
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .foregroundStyle(.primary)

                    Text(String(localized: "signin_subtitle"))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .font(.headline)
                }
                .padding(.horizontal)

                // Shared adaptive content surface keeps account controls legible.
                VStack(spacing: 20) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.secondary)
                        Text(String(localized: "signin_badge"))
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
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 56)
                    .clipShape(Capsule())

                    Button {
                        didSkipSignIn = true
                        didCompleteOnboarding = true
                    } label: {
                        Text(String(localized: "signin_continue_offline"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.accentColor.opacity(0.10), in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.6)
                            )
                    }
                    .buttonStyle(.plain)
                    
                    if cloudKit.status == .notAvailable {
                        Text(String(localized: "signin_icloud_guidance"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .dsCard(cornerRadius: 28)

                Spacer()

                Button {
                    showPrivacyPolicy = true
                } label: {
                    Text(String(localized: "signin_privacy_footer"))
                        .font(.footnote)
                        .underline()
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
            }
        }
    }
}
