import Foundation

/// The user's answer to "short sleeves with a jacket, or long?" for a day.
enum DayLayerChoice: String, Codable, CaseIterable, Identifiable {
    case shortWithLayer
    case long
    case shortNoLayer

    var id: String { rawValue }

    var sleeve: SleeveLength { self == .long ? .long : .short }

    var title: String {
        switch self {
        case .shortWithLayer: return String(localized: "comfort_choice_short_layer")
        case .long: return String(localized: "comfort_choice_long")
        case .shortNoLayer: return String(localized: "comfort_choice_short")
        }
    }

    var icon: String {
        switch self {
        case .shortWithLayer: return "jacket"
        case .long: return "tshirt.fill"
        case .shortNoLayer: return "sun.max"
        }
    }
}

/// Day answers plus a small history of them, from which the user's own
/// short-sleeve and jacket temperatures are learned. The planner only asks
/// when a day is close to those temperatures, so it asks less over time.
enum ComfortPreferences {
    struct Sample: Codable, Equatable {
        var temperatureC: Double
        var choice: DayLayerChoice
    }

    private static let samplesKey = "comfortSamples"
    private static let maxSamples = 60
    /// Samples on each side before a threshold counts as learned.
    static let minimumSamplesPerSide = 2

    private static func answerKey(for day: Date) -> String {
        "comfortAnswer.\(Int(Calendar.current.startOfDay(for: day).timeIntervalSince1970))"
    }

    static func answer(for day: Date, defaults: UserDefaults = .standard) -> DayLayerChoice? {
        defaults.string(forKey: answerKey(for: day)).flatMap(DayLayerChoice.init(rawValue:))
    }

    static func setAnswer(_ choice: DayLayerChoice, for day: Date, temperatureC: Double, defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: answerKey(for: day))
        var all = samples(defaults: defaults)
        all.append(Sample(temperatureC: temperatureC, choice: choice))
        if all.count > maxSamples { all.removeFirst(all.count - maxSamples) }
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: samplesKey)
        }
    }

    static func samples(defaults: UserDefaults = .standard) -> [Sample] {
        guard let data = defaults.data(forKey: samplesKey),
              let decoded = try? JSONDecoder().decode([Sample].self, from: data) else { return [] }
        return decoded
    }

    /// The temperature from which the user goes for short sleeves.
    static func shortSleeveFromC(_ samples: [Sample]) -> Double? {
        threshold(
            warmSide: samples.filter { $0.choice.sleeve == .short }.map(\.temperatureC),
            coolSide: samples.filter { $0.choice.sleeve == .long }.map(\.temperatureC)
        )
    }

    /// The temperature below which the user wants a layer over short sleeves.
    static func jacketBelowC(_ samples: [Sample]) -> Double? {
        threshold(
            warmSide: samples.filter { $0.choice == .shortNoLayer }.map(\.temperatureC),
            coolSide: samples.filter { $0.choice == .shortWithLayer }.map(\.temperatureC)
        )
    }

    /// Midpoint between the typical temperature of each side.
    private static func threshold(warmSide: [Double], coolSide: [Double]) -> Double? {
        guard warmSide.count >= minimumSamplesPerSide, coolSide.count >= minimumSamplesPerSide else { return nil }
        let warm = warmSide.reduce(0, +) / Double(warmSide.count)
        let cool = coolSide.reduce(0, +) / Double(coolSide.count)
        return (warm + cool) / 2
    }

    /// Whether the sleeve / jacket call for this temperature is a real toss-up
    /// for this user, so a question is worth one tap.
    static func isBorderline(temperatureC: Double, low: Double, high: Double, samples: [Sample]) -> Bool {
        let learned = [shortSleeveFromC(samples), jacketBelowC(samples)].compactMap { $0 }
        if !learned.isEmpty {
            // The more answers, the narrower the band that still needs asking.
            let band = samples.count >= 8 ? 1.0 : 1.5
            return learned.contains { abs(temperatureC - $0) <= band }
        }
        let swings = high - low >= 8 && high >= 20 && low <= 18
        return (17...23).contains(temperatureC) || swings
    }

    /// The outer-layer policy after the user's answer for the day.
    static func adjusted(_ policy: OuterLayerPolicy, choice: DayLayerChoice?, isRaining: Bool) -> OuterLayerPolicy {
        switch choice {
        case .shortWithLayer?:
            return policy == .suppress ? .lightOnly : policy
        case .shortNoLayer?:
            return isRaining ? policy : .suppress
        case .long?, nil:
            return policy
        }
    }
}
