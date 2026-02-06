//
//  ForecastService.swift
//  WearIt
//
//  3-day weather forecast service using Apple WeatherKit

import Foundation
import WeatherKit
import CoreLocation

// MARK: - Day Forecast Model

struct DayForecast: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let temperatureC: Double
    let highTempC: Double
    let lowTempC: Double
    let rainProbability: Double  // 0.0 - 1.0
    let condition: WeatherCondition
    
    init(
        id: UUID = UUID(),
        date: Date,
        temperatureC: Double,
        highTempC: Double,
        lowTempC: Double,
        rainProbability: Double,
        condition: WeatherCondition
    ) {
        self.id = id
        self.date = date
        self.temperatureC = temperatureC
        self.highTempC = highTempC
        self.lowTempC = lowTempC
        self.rainProbability = rainProbability
        self.condition = condition
    }
    
    static func == (lhs: DayForecast, rhs: DayForecast) -> Bool {
        lhs.id == rhs.id &&
        lhs.date == rhs.date &&
        lhs.temperatureC == rhs.temperatureC &&
        lhs.rainProbability == rhs.rainProbability &&
        lhs.condition == rhs.condition
    }
    
    var isRaining: Bool {
        rainProbability > 0.3
    }
    
    var dayName: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return String(localized: "day_today")
        } else if calendar.isDateInTomorrow(date) {
            return String(localized: "day_tomorrow")
        } else {
            return Self.dayNameFormatter.string(from: date)
        }
    }
    
    var shortDayName: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return String(localized: "day_today")
        } else if calendar.isDateInTomorrow(date) {
            return String(localized: "day_tomorrow")
        } else {
            return Self.shortDayNameFormatter.string(from: date)
        }
    }

    private static let dayNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private static let shortDayNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()
}

enum WeatherCondition: String, Codable {
    case sunny = "sun.max.fill"
    case partlyCloudy = "cloud.sun.fill"
    case cloudy = "cloud.fill"
    case rain = "cloud.rain.fill"
    case storm = "cloud.bolt.rain.fill"
    case snow = "cloud.snow.fill"
    
    var icon: String { rawValue }
    
    var description: String {
        switch self {
        case .sunny: return String(localized: "weather_sunny")
        case .partlyCloudy: return String(localized: "weather_partly_cloudy")
        case .cloudy: return String(localized: "weather_cloudy")
        case .rain: return String(localized: "weather_rainy")
        case .storm: return String(localized: "weather_stormy")
        case .snow: return String(localized: "weather_snow")
        }
    }
}

// MARK: - Weather Provider Protocol

protocol WeatherProvider {
    func forecastNext3Days(for location: CLLocation) async throws -> [DayForecast]
}

// MARK: - WeatherKit Provider (Real Apple Weather)

final class WeatherKitProvider: WeatherProvider {
    // Use fully qualified name to avoid collision with local WeatherService enum
    private let appleWeatherService = WeatherKit.WeatherService.shared
    
    func forecastNext3Days(for location: CLLocation) async throws -> [DayForecast] {
        // Request daily forecast from Apple WeatherKit
        let daily: Forecast<DayWeather> = try await appleWeatherService.weather(
            for: location,
            including: .daily
        )
        
        // Get next 3 days
        let next3 = daily.prefix(3).map { day in
            DayForecast(
                date: day.date,
                temperatureC: day.highTemperature.converted(to: UnitTemperature.celsius).value,
                highTempC: day.highTemperature.converted(to: UnitTemperature.celsius).value,
                lowTempC: day.lowTemperature.converted(to: UnitTemperature.celsius).value,
                rainProbability: day.precipitationChance,
                condition: mapCondition(day.condition)
            )
        }
        
        return Array(next3)
    }
    
    private func mapCondition(_ condition: WeatherKit.WeatherCondition) -> WeatherCondition {
        switch condition {
        // Clear / Sunny
        case .clear, .hot, .mostlyClear, .sunFlurries, .sunShowers:
            return .sunny
        // Partly Cloudy
        case .partlyCloudy:
            return .partlyCloudy
        // Cloudy
        case .cloudy, .mostlyCloudy, .foggy, .haze, .smoky, .windy, .breezy, .blowingDust:
            return .cloudy
        // Rain
        case .rain, .drizzle, .heavyRain, .freezingDrizzle, .freezingRain, .hail:
            return .rain
        // Storm
        case .thunderstorms, .isolatedThunderstorms, .scatteredThunderstorms, .strongStorms, .tropicalStorm, .hurricane:
            return .storm
        // Snow
        case .snow, .flurries, .heavySnow, .sleet, .wintryMix, .blizzard, .blowingSnow, .frigid:
            return .snow
        @unknown default:
            return .cloudy
        }
    }
}

// MARK: - Mock Weather Provider (Fallback)

final class MockWeatherProvider: WeatherProvider {
    
    /// Generate mock forecasts based on current season
    func forecastNext3Days(for location: CLLocation) async throws -> [DayForecast] {
        let calendar = Calendar.current
        let today = Date()
        
        // Base temperature on season (Northern Hemisphere approximation)
        let month = calendar.component(.month, from: today)
        let seasonBase = seasonalBaseTemp(month: month)
        
        var forecasts: [DayForecast] = []
        
        for dayOffset in 0..<3 {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            
            // Add some variance per day
            let variance = Double.random(in: -3...3)
            let temp = seasonBase + variance
            let high = temp + Double.random(in: 2...5)
            let low = temp - Double.random(in: 3...6)
            
            // Rain probability varies
            let rainProb = Double.random(in: 0...0.6)
            
            // Determine condition based on rain and season
            let condition = determineCondition(rainProb: rainProb, temp: temp)
            
            forecasts.append(DayForecast(
                date: date,
                temperatureC: temp.rounded(),
                highTempC: high.rounded(),
                lowTempC: low.rounded(),
                rainProbability: rainProb,
                condition: condition
            ))
        }
        
        return forecasts
    }
    
    private func seasonalBaseTemp(month: Int) -> Double {
        switch month {
        case 12, 1, 2: return 8   // Winter
        case 3, 4, 5: return 16   // Spring
        case 6, 7, 8: return 28   // Summer
        case 9, 10, 11: return 18 // Fall
        default: return 20
        }
    }
    
    private func determineCondition(rainProb: Double, temp: Double) -> WeatherCondition {
        if temp < 0 && rainProb > 0.3 {
            return .snow
        } else if rainProb > 0.6 {
            return .storm
        } else if rainProb > 0.3 {
            return .rain
        } else if rainProb > 0.15 {
            return .partlyCloudy
        } else if rainProb > 0.05 {
            return .cloudy
        } else {
            return .sunny
        }
    }
}

// MARK: - Forecast Service (Singleton)

@MainActor
final class ForecastService: ObservableObject {
    static let shared = ForecastService()
    
    @Published private(set) var forecasts: [DayForecast] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var usedMockData: Bool = false
    @Published private(set) var locationName: String?
    
    private var provider: WeatherProvider = WeatherKitProvider()
    private var fallbackProvider: WeatherProvider = MockWeatherProvider()
    
    /// Cache interval: refresh only if last update was more than this many seconds ago
    private let cacheInterval: TimeInterval = 3600  // 1 hour
    private let minRefreshInterval: TimeInterval = 3600
    private var lastRefreshAttempt: Date?
    
    private init() {}
    
    /// Refresh forecasts using device location
    func refresh(force: Bool = false) async {
        guard !isLoading else { return }
        let now = Date()
        if !force, let lastAttempt = lastRefreshAttempt,
           now.timeIntervalSince(lastAttempt) < minRefreshInterval {
            return
        }
        // Check if we have recent data
        if !force, let lastUpdate = lastUpdated, now.timeIntervalSince(lastUpdate) < cacheInterval {
            return  // Use cached data
        }
        
        updateIfChanged(&isLoading, true)
        lastRefreshAttempt = now
        updateIfChanged(&errorMessage, nil)
        updateIfChanged(&usedMockData, false)
        
        do {
            // Get current location
            let location = try await LocationManager.shared.requestLocation()
            let clLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
            
            // Resolve location name for UI display
            updateIfChanged(&locationName, await resolveLocationName(for: clLocation))
            
            // Try WeatherKit first
            do {
                setForecastsIfChanged(try await provider.forecastNext3Days(for: clLocation))
                updateIfChanged(&lastUpdated, Date())
            } catch {
                // Fall back to mock data
                print("WeatherKit failed, using mock: \(error.localizedDescription)")
                setForecastsIfChanged(try await fallbackProvider.forecastNext3Days(for: clLocation))
                updateIfChanged(&lastUpdated, Date())
                updateIfChanged(&usedMockData, true)
            }
        } catch {
            if let locError = error as? LocationManager.LocError {
                switch locError {
                case .busy:
                    updateIfChanged(&isLoading, false)
                    return
                default:
                    break
                }
            }
            // Location failed, use mock with default location
            print("Location failed: \(error.localizedDescription)")
            do {
                let defaultLocation = CLLocation(latitude: 32.0853, longitude: 34.7818) // Tel Aviv
                updateIfChanged(&locationName, nil)
                setForecastsIfChanged(try await fallbackProvider.forecastNext3Days(for: defaultLocation))
                updateIfChanged(&lastUpdated, Date())
                updateIfChanged(&usedMockData, true)
            } catch {
                updateIfChanged(&errorMessage, error.localizedDescription)
            }
        }
        
        updateIfChanged(&isLoading, false)
    }
    
    /// Force refresh (ignores cache)
    func forceRefresh() async {
        lastUpdated = nil
        lastRefreshAttempt = nil
        await refresh(force: true)
    }

    /// Resolve a human-readable location name for display
    private func resolveLocationName(for location: CLLocation) async -> String? {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else { return nil }
            
            if let locality = placemark.locality, !locality.isEmpty {
                return locality
            }
            if let subAdmin = placemark.subAdministrativeArea, !subAdmin.isEmpty {
                return subAdmin
            }
            if let admin = placemark.administrativeArea, !admin.isEmpty {
                return admin
            }
            if let country = placemark.country, !country.isEmpty {
                return country
            }
            return nil
        } catch {
            return nil
        }
    }
    
    /// Get forecast for a specific day index (0 = today, 1 = tomorrow, 2 = day after)
    func forecast(for dayIndex: Int) -> DayForecast? {
        guard dayIndex >= 0 && dayIndex < forecasts.count else { return nil }
        return forecasts[dayIndex]
    }
    
    /// Get temperature profile for a specific day (with smart hints)
    func temperatureProfile(for dayIndex: Int) -> DayTemperatureProfile? {
        guard let forecast = forecast(for: dayIndex) else { return nil }
        return DayTemperatureProfile(from: forecast)
    }
    
    /// Get all temperature profiles
    var temperatureProfiles: [DayTemperatureProfile] {
        forecasts.map { DayTemperatureProfile(from: $0) }
    }
    
    /// Swap provider (for testing)
    func setProvider(_ newProvider: WeatherProvider) {
        provider = newProvider
    }

    private func updateIfChanged<T: Equatable>(_ target: inout T, _ newValue: T) {
        if target != newValue {
            target = newValue
        }
    }

    private func updateIfChanged<T: Equatable>(_ target: inout T?, _ newValue: T?) {
        if target != newValue {
            target = newValue
        }
    }

    private func setForecastsIfChanged(_ newForecasts: [DayForecast]) {
        guard !forecastsEqual(forecasts, newForecasts) else { return }
        forecasts = newForecasts
    }

    private func forecastsEqual(_ lhs: [DayForecast], _ rhs: [DayForecast]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            if left.date != right.date ||
                left.temperatureC != right.temperatureC ||
                left.highTempC != right.highTempC ||
                left.lowTempC != right.lowTempC ||
                left.rainProbability != right.rainProbability ||
                left.condition != right.condition {
                return false
            }
        }
        return true
    }
}
