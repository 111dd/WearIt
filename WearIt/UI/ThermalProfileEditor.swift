import SwiftUI

/// One quiet summary by default; corrections are optional, native menu pickers.
struct ThermalProfileEditor: View {
    let profile: GarmentThermalProfile
    @Binding var warmthOverride: Int?
    @Binding var breathabilityOverride: Int?
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("thermal_edit_hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("thermal_insulation", selection: $warmthOverride) {
                    Text("thermal_automatic").tag(Optional<Int>.none)
                    ForEach(1...5, id: \.self) { value in
                        Text(Self.warmthLabel(value)).tag(Optional(value))
                    }
                }
                .pickerStyle(.menu)
                .frame(minHeight: 44)
                .accessibilityIdentifier("thermal.warmth")
                Picker("thermal_ventilation", selection: $breathabilityOverride) {
                    Text("thermal_automatic").tag(Optional<Int>.none)
                    ForEach(1...5, id: \.self) { value in
                        Text(Self.breathabilityLabel(value)).tag(Optional(value))
                    }
                }
                .pickerStyle(.menu)
                .frame(minHeight: 44)
                .accessibilityIdentifier("thermal.breathability")
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label("thermal_title", systemImage: "thermometer.medium")
                    .font(.subheadline.weight(.semibold))
                Text(Self.summary(profile)).font(.subheadline)
                Text(profile.warmthIsUserAdjusted || profile.breathabilityIsUserAdjusted
                     ? "thermal_source_adjusted" : "thermal_source_estimated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44, alignment: .leading)
        }
        .accessibilityIdentifier("thermal.profile")
        .padding(DS.Spacing.md)
        .liquidGlassSurface(cornerRadius: DS.Radius.card)
    }

    static func summary(_ profile: GarmentThermalProfile) -> String {
        "\(warmthLabel(Int(profile.insulation.rounded()))) · \(breathabilityLabel(Int((profile.breathability * 4).rounded()) + 1))"
    }

    static func warmthLabel(_ value: Int) -> String {
        switch value {
        case 1: return String(localized: "thermal_warmth_1")
        case 2: return String(localized: "thermal_warmth_2")
        case 4: return String(localized: "thermal_warmth_4")
        case 5: return String(localized: "thermal_warmth_5")
        default: return String(localized: "thermal_warmth_3")
        }
    }

    static func breathabilityLabel(_ value: Int) -> String {
        switch value {
        case 1: return String(localized: "thermal_breathability_1")
        case 2: return String(localized: "thermal_breathability_2")
        case 4: return String(localized: "thermal_breathability_4")
        case 5: return String(localized: "thermal_breathability_5")
        default: return String(localized: "thermal_breathability_3")
        }
    }
}

#Preview("Thermal summary") {
    ThermalProfileEditor(
        profile: GarmentThermalProfile(warmth: 2, itemType: .shirt),
        warmthOverride: .constant(nil), breathabilityOverride: .constant(nil)
    ).padding()
}
