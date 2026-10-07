import SwiftUI

/// Empty-wardrobe message that says "restoring from iCloud" while a sync is running,
/// so a new device doesn't look like a lost wardrobe. Observes the sync monitor itself,
/// keeping its status flips out of the big screens that host it.
struct EmptyWardrobeState: View {
    @EnvironmentObject private var cloudKit: CloudKitSyncMonitor

    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        if cloudKit.status == .syncing {
            DSEmptyState(
                icon: "icloud.and.arrow.down",
                title: String(localized: "wardrobe_restoring_title"),
                message: String(localized: "wardrobe_restoring_message")
            )
        } else {
            DSEmptyState(
                icon: "tshirt",
                title: title,
                message: message,
                actionTitle: actionTitle,
                action: action
            )
        }
    }
}
