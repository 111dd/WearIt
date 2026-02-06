import SwiftUI

struct AppGateView: View {
    @EnvironmentObject private var auth: AuthManager
    @AppStorage("didSkipSignIn") private var didSkipSignIn = false

    var body: some View {
        Group {
            if auth.isSignedIn || didSkipSignIn {
                RootView()
            } else {
                SignInView()
            }
        }
        .task {
            await auth.refreshCredentialStateIfNeeded()
        }
    }
}
