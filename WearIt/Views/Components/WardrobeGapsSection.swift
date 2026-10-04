import SwiftUI

/// Stats card listing what the wardrobe is missing, each with its evidence
/// and a taste-shaped suggestion. Dismissing a gap hides it for a while.
struct WardrobeGapsSection: View {
    let gaps: [WardrobeGapAnalyzer.Gap]
    let garmentsByID: [UUID: Garment]
    var onDismiss: (WardrobeGapAnalyzer.Gap) -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        if !gaps.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                DSSectionHeader(String(localized: "stats_gaps_title"), icon: "sparkle.magnifyingglass")
                Text(String(localized: "stats_gaps_subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(gaps) { gap in
                    row(for: gap)
                    if gap.id != gaps.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }
            .dsCard()
        }
    }

    private func row(for gap: WardrobeGapAnalyzer.Gap) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: icon(for: gap))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(title(for: gap))
                    .font(.subheadline.weight(.semibold))
                Text(reasonText(for: gap.reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: DS.Spacing.xxs) {
                    ForEach(gap.suggestion.colors, id: \.self) { color in
                        Circle()
                            .fill(color.color)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                    }
                    Text(String(localized: "gap_suggestion_prefix") + " " + suggestionText(for: gap.suggestion))
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                }
                .padding(.top, DS.Spacing.xxxs)

                HStack(spacing: DS.Spacing.sm) {
                    Button {
                        DS.haptic(0.3)
                        if let url = searchURL(for: gap.suggestion) {
                            openURL(url)
                        }
                    } label: {
                        Label(String(localized: "gap_action_find"), systemImage: "magnifyingglass")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)

                    Button {
                        DS.haptic(0.3)
                        onDismiss(gap)
                    } label: {
                        Text(String(localized: "gap_action_dismiss"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.top, DS.Spacing.xxxs)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.Spacing.xxs)
    }

    // MARK: - Text

    private func icon(for gap: WardrobeGapAnalyzer.Gap) -> String {
        switch gap.kind {
        case .missingCore: return gap.suggestion.category.icon
        case .rainShoes, .rainOuter: return "cloud.rain.fill"
        case .warmOuter: return "thermometer.snowflake"
        case .hotWeatherTops: return "sun.max.fill"
        case .formalTop, .formalBottom, .formalShoes: return "sparkles"
        case .workhorseBackup: return "arrow.triangle.2.circlepath"
        }
    }

    private func title(for gap: WardrobeGapAnalyzer.Gap) -> String {
        switch gap.kind {
        case .missingCore:
            return String(
                format: NSLocalizedString("gap_title_missing_core_format", comment: ""),
                gap.suggestion.category.title
            )
        case .rainShoes: return String(localized: "gap_title_rain_shoes")
        case .rainOuter: return String(localized: "gap_title_rain_outer")
        case .warmOuter: return String(localized: "gap_title_warm_outer")
        case .hotWeatherTops: return String(localized: "gap_title_hot_tops")
        case .formalTop: return String(localized: "gap_title_formal_top")
        case .formalBottom: return String(localized: "gap_title_formal_bottom")
        case .formalShoes: return String(localized: "gap_title_formal_shoes")
        case .workhorseBackup:
            let name: String = {
                if case .heavyRotation(let id, _) = gap.reason, let garment = garmentsByID[id] {
                    return garment.displayTitle
                }
                return gap.suggestion.itemType?.title ?? gap.suggestion.category.title
            }()
            return String(format: NSLocalizedString("gap_title_backup_format", comment: ""), name)
        }
    }

    private func reasonText(for reason: WardrobeGapAnalyzer.Reason) -> String {
        func format(_ key: String, _ value: Int) -> String {
            String(format: NSLocalizedString(key, comment: ""), value)
        }
        func percent(_ share: Double) -> Int { Int((share * 100).rounded()) }

        switch reason {
        case .noItemsInCategory:
            return String(localized: "gap_reason_no_items")
        case .upcomingRain(let days):
            return format("gap_reason_upcoming_rain_format", days)
        case .rainyClimate(let share):
            return format("gap_reason_rainy_climate_format", percent(share))
        case .upcomingCold(let days):
            return format("gap_reason_upcoming_cold_format", days)
        case .coldClimate(let share):
            return format("gap_reason_cold_climate_format", percent(share))
        case .upcomingHeat(let days):
            return format("gap_reason_upcoming_heat_format", days)
        case .hotClimate(let share):
            return format("gap_reason_hot_climate_format", percent(share))
        case .upcomingFormal(let days):
            return format("gap_reason_upcoming_formal_format", days)
        case .formalHabit(let share):
            return format("gap_reason_formal_habit_format", percent(share))
        case .heavyRotation(_, let share):
            return format("gap_reason_heavy_rotation_format", percent(share))
        }
    }

    /// e.g. "Navy boots · waterproof · Timberland"
    private func suggestionText(for suggestion: WardrobeGapAnalyzer.Suggestion) -> String {
        searchTerms(for: suggestion).joined(separator: " · ")
    }

    private func searchTerms(for suggestion: WardrobeGapAnalyzer.Suggestion) -> [String] {
        var terms: [String] = []
        let item = suggestion.itemType?.title ?? suggestion.category.title
        if let color = suggestion.colors.first {
            terms.append("\(color.title) \(item)")
        } else {
            terms.append(item)
        }
        for tag in suggestion.weatherTags {
            switch tag {
            case .waterproof, .rainFriendly: terms.append(String(localized: "gap_tag_waterproof"))
            case .insulated: terms.append(String(localized: "gap_tag_insulated"))
            case .breathable: terms.append(String(localized: "gap_tag_breathable"))
            case .windproof: break
            }
        }
        if let formality = suggestion.formality, formality >= WardrobeGapAnalyzer.formalThreshold {
            terms.append(String(localized: "gap_tag_formal"))
        }
        if let fit = suggestion.fit {
            terms.append(fit.title)
        }
        if let brand = suggestion.brandName {
            terms.append(brand)
        }
        return terms
    }

    private func searchURL(for suggestion: WardrobeGapAnalyzer.Suggestion) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [
            URLQueryItem(name: "tbm", value: "shop"),
            URLQueryItem(name: "q", value: searchTerms(for: suggestion).joined(separator: " "))
        ]
        return components?.url
    }
}
