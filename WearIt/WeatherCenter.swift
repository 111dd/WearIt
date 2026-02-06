//
//  WeatherCenter.swift
//  WearIt
//
//  Central weather data hub with 3-day forecast support

import Foundation

@MainActor
final class WeatherCenter: ObservableObject {
    static let shared = WeatherCenter()
    private init() {}

    // MARK: - Current Weather
    @Published var currentTempC: Double? = nil
    @Published var isRainingNow: Bool = false
    
    // MARK: - 3-Day Forecast
    @Published private(set) var forecasts: [DayForecast] = []
    @Published private(set) var isForecastLoading: Bool = false
    @Published private(set) var forecastLastUpdated: Date?
    @Published private(set) var locationName: String?
    
    private let forecastService = ForecastService.shared
    private let minRefreshInterval: TimeInterval = 3600
    private var lastRefreshAttempt: Date?

    // MARK: - Update Methods

    /// Update from our WeatherService snapshot
    func update(snapshot: WeatherSnapshot) {
        updateIfChanged(&currentTempC, Optional(snapshot.temperatureC))
        updateIfChanged(&isRainingNow, snapshot.isRaining)
    }

    /// Convenience used by BootstrapView
    func update(tempC: Double, isRaining: Bool) {
        updateIfChanged(&currentTempC, Optional(tempC))
        updateIfChanged(&isRainingNow, isRaining)
    }
    
    // MARK: - 3-Day Forecast
    
    /// Refresh the 3-day forecast
    func refreshForecast(force: Bool = false, source: String = "unknown") async {
        if !force, !shouldRefresh(now: Date()) {
            debugLog("Weather refresh skipped (throttled)", source: source)
            return
        }
        guard !isForecastLoading else {
            debugLog("Weather refresh skipped (in-flight)", source: source)
            return
        }
        isForecastLoading = true
        lastRefreshAttempt = Date()
        debugLog("Weather refresh start", source: source)
        await forecastService.refresh(force: force)
        updateIfChanged(&forecasts, forecastService.forecasts)
        updateIfChanged(&forecastLastUpdated, forecastService.lastUpdated)
        updateIfChanged(&locationName, forecastService.locationName)
        
        // Update current weather from today's forecast if available
        if let today = forecasts.first {
            if currentTempC == nil {
                currentTempC = today.temperatureC
            }
            // Only update rain status if we don't have real-time data
            updateIfChanged(&isRainingNow, today.isRaining)
        }
        
        isForecastLoading = false
        debugLog("Weather refresh end", source: source)
    }
    
    /// Get forecast for a specific day (0 = today, 1 = tomorrow, 2 = day 3)
    func forecast(for dayIndex: Int) -> DayForecast? {
        guard dayIndex >= 0 && dayIndex < forecasts.count else { return nil }
        return forecasts[dayIndex]
    }
    
    /// Today's forecast
    var todayForecast: DayForecast? {
        forecasts.first
    }
    
    /// Tomorrow's forecast
    var tomorrowForecast: DayForecast? {
        forecasts.count > 1 ? forecasts[1] : nil
    }
    
    /// Day 3 forecast
    var day3Forecast: DayForecast? {
        forecasts.count > 2 ? forecasts[2] : nil
    }

    private func shouldRefresh(now: Date) -> Bool {
        if let lastUpdated = forecastLastUpdated,
           now.timeIntervalSince(lastUpdated) < minRefreshInterval {
            return false
        }
        if let lastAttempt = lastRefreshAttempt,
           now.timeIntervalSince(lastAttempt) < minRefreshInterval {
            return false
        }
        return true
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

    private func updateIfChanged(_ target: inout [DayForecast], _ newValue: [DayForecast]) {
        guard !forecastsEqual(target, newValue) else { return }
        target = newValue
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

    private func debugLog(_ message: String, source: String) {
        #if DEBUG
        print("WeatherCenter: \(message) [source=\(source)]")
        #endif
    }
}
