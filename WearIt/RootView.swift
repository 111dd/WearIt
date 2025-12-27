import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @StateObject private var auth = AuthManager()

    var body: some View {
        Group {
            if auth.isSignedIn {
                TabView {
                    OutfitView()
                        .tabItem { Label("Outfit", systemImage: "house") }
                    WardrobeView()
                        .tabItem { Label("Wardrobe", systemImage: "square.grid.2x2") }
                    AddGarmentView()
                        .tabItem { Label("Add", systemImage: "plus.circle") }
                    StatsView()
                        .tabItem { Label("Stats", systemImage: "chart.bar") }
                }
                .background(.ultraThinMaterial)
                .tint(.accentColor)
                .toolbar {
                    // כפתור התנתקות פשוט בתפריט הטאבים (אופציונלי)
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if let id = auth.userIdentifier {
                                Text("User: \(id)").font(.caption)
                            }
                            Button(role: .destructive) {
                                auth.signOut()
                            } label: {
                                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                    }
                }
            } else {
                SignInView(auth: auth)
            }
        }
        .onAppear {
            // אפקט רך לטרנזישן
            UIView.appearance(whenContainedInInstancesOf: [UITabBarController.self]).backgroundColor = .clear
        }
        .task {
            SeedData.load(context: context)
        }
    }
}
