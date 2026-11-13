import SwiftUI

/// An explainable fit index. Percent is deliberately separate from sale/ranking boosts.
struct ShopMatchBadge: View {
    let match: PurchaseScorer.Match?
    @State private var showDetails = false

    var body: some View {
        if let match {
            Button { showDetails = true } label: {
                Label(String(format: String(localized: "shop_match_percent_format"), match.percent), systemImage: "info.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderless)
            .sheet(isPresented: $showDetails) {
                NavigationStack {
                    List {
                        Section {
                            component("shop_match_style", value: match.taste)
                            if let wardrobe = match.wardrobe { component("shop_match_wardrobe", value: wardrobe) }
                            if let weather = match.weather { component("shop_match_weather", value: weather) }
                        } footer: {
                            Text(String(localized: match.wardrobe == nil ? "shop_match_style_only" : "shop_match_explanation"))
                        }
                        Section {
                            Text(String(localized: match.signals < 10 ? "shop_match_learning" : "shop_match_learned"))
                        } footer: {
                            Text(String(localized: "shop_match_estimate"))
                        }
                    }
                    .navigationTitle(String(localized: "shop_match_title"))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "action_ok")) { showDetails = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        } else {
            Text(String(localized: "shop_match_not_enough"))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func component(_ key: LocalizedStringKey, value: Double) -> some View {
        HStack {
            Text(key)
            Spacer()
            Text(min(1, max(0, value)), format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
        }
    }
}
