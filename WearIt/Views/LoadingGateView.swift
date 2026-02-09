import SwiftUI

struct LoadingGateView: View {
    @EnvironmentObject private var cloudKit: CloudKitSyncMonitor
    let message: String

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: DS.Spacing.md) {
                Image(systemName: "tshirt.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(.secondary)

                Text("WearIt")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(.primary)

                ProgressView()
                    .controlSize(.large)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if cloudKit.status == .notAvailable {
                    Text(String(localized: "loading_offline"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(DS.Spacing.lg)
        }
        .onAppear {
            #if DEBUG
            print("LOADING_GATE_SHOWN")
            #endif
        }
    }
}
