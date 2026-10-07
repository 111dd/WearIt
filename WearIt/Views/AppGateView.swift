import SwiftUI

struct AppGateView: View {
    @EnvironmentObject private var auth: AuthManager
    @AppStorage("didSkipSignIn") private var didSkipSignIn = false
    @AppStorage(OnboardingState.completedKey) private var didCompleteOnboarding = false

    var body: some View {
        Group {
            if auth.isSignedIn || didSkipSignIn {
                RootView()
            } else if !didCompleteOnboarding {
                OnboardingView()
            } else {
                SignInView()
            }
        }
        // BootstrapCoordinator owns the launch credential check. Running it
        // here too duplicates the request while this view is under the overlay.
    }
}
