import Foundation
import CoreLocation

/// Forecast at a calendar pin. WeatherKit first, Open-Meteo if that fails.
/// A miss leaves the home forecast in place — never a made-up temperature.
@MainActor
final class EventLocationForecastService {
    static let shared = EventLocationForecastService()

    private struct Entry {
        var fetchedAt: Date
        var days: [DayForecast]
        var ttl: TimeInterval
    }

    private var cache: [String: Entry] = [:]
    private let successTTL: TimeInterval = 3600
    private let failureTTL: TimeInterval = 15 * 60

    /// ~1 km. Pins in the same city share one fetch.
    /// Nonisolated: trip detection calls this off the main actor.
    nonisolated static func placeKey(_ place: EventPlace) -> String {
        let lat = (place.latitude * 100).rounded() / 100
        let lon = (place.longitude * 100).rounded() / 100
        return "\(lat),\(lon)"
    }

    static func storageKey(for place: EventPlace, on date: Date) -> String {
        let day = Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
        return "\(placeKey(place))|\(day)"
    }

    /// The forecast day closest to `date`, within the gap a timezone can open
    /// between the device and the pin. The next calendar day stays out.
    static func match(_ days: [DayForecast], to date: Date) -> DayForecast? {
        let target = Calendar.current.startOfDay(for: date)
        return days
            .filter { abs($0.date.timeIntervalSince(target)) < 18 * 3600 }
            .min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
    }

    func forecasts(for place: EventPlace) async -> [DayForecast] {
        let key = Self.placeKey(place)
        if let hit = cache[key], Date().timeIntervalSince(hit.fetchedAt) < hit.ttl {
            return hit.days
        }
        let days = await load(place)
        cache[key] = Entry(
            fetchedAt: Date(),
            days: days,
            ttl: days.isEmpty ? failureTTL : successTTL
        )
        return days
    }

    private func load(_ place: EventPlace) async -> [DayForecast] {
        let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
        if let days = try? await WeatherKitProvider().forecastNext3Days(for: location), !days.isEmpty {
            return days
        }
        return await OpenMeteoPlaceForecast.fetch(for: location)
    }

    /// Enough days for a trip. WeatherKit first (about 10 days), then Open-Meteo.
    func forecasts(for place: EventPlace, days: Int) async -> [DayForecast] {
        let capped = max(1, min(days, 16))
        let key = "\(Self.placeKey(place))#\(capped)"
        if let hit = cache[key], Date().timeIntervalSince(hit.fetchedAt) < hit.ttl {
            return hit.days
        }
        let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
        var daysOut: [DayForecast] = []
        if capped <= 10, let fetched = try? await WeatherKitProvider().forecast(for: location, days: capped), !fetched.isEmpty {
            daysOut = fetched
        }
        if daysOut.isEmpty {
            daysOut = await OpenMeteoPlaceForecast.fetch(for: location, days: capped)
        }
        cache[key] = Entry(
            fetchedAt: Date(),
            days: daysOut,
            ttl: daysOut.isEmpty ? failureTTL : successTTL
        )
        return daysOut
    }
}

/// One place, up to three days, hourly. Used only when WeatherKit fails.
private enum OpenMeteoPlaceForecast {
    static func fetch(for location: CLLocation, days: Int = 3) async -> [DayForecast] {
        guard let url = url(for: location, days: days) else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return []
        }
        let timeZone = TimeZone(identifier: decoded.timezone) ?? .current
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"

        let hourly = decoded.hourly
        let count = min(
            hourly.time.count,
            hourly.temperature_2m.count,
            hourly.apparent_temperature.count,
            hourly.precipitation_probability.count,
            hourly.weathercode.count
        )
        var samples: [Sample] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            guard let date = formatter.date(from: hourly.time[index]),
                  let temperature = hourly.temperature_2m[index].value else { continue }
            samples.append(Sample(
                date: date,
                temperatureC: temperature,
                apparentC: hourly.apparent_temperature[index].value,
                rainProbability: (hourly.precipitation_probability[index].value ?? 0) / 100,
                code: Int(hourly.weathercode[index].value ?? 0)
            ))
        }

        let calendar = Calendar.current
        let grouped = Dictionary(grouping: samples) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted().map { day in
            let hours = grouped[day] ?? []
            let temps = hours.map(\.temperatureC)
            let high = temps.max() ?? 20
            let low = temps.min() ?? high
            let rain = hours.map(\.rainProbability).max() ?? 0
            let codes = hours.map(\.code)
            return DayForecast(
                date: day,
                temperatureC: high,
                highTempC: high,
                lowTempC: low,
                rainProbability: rain,
                condition: condition(codes: codes, rain: rain),
                thermalHours: hours.map {
                    ThermalWeatherSample(
                        date: $0.date,
                        temperatureC: $0.temperatureC,
                        apparentTemperatureC: $0.apparentC,
                        rainProbability: $0.rainProbability
                    )
                }
            )
        }
    }

    private static func url(for location: CLLocation, days: Int) -> URL? {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        comps?.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(location.coordinate.longitude)),
            URLQueryItem(name: "hourly", value: "temperature_2m,apparent_temperature,precipitation_probability,weathercode"),
            URLQueryItem(name: "forecast_days", value: String(max(1, min(days, 16)))),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        return comps?.url
    }

    private static func condition(codes: [Int], rain: Double) -> WeatherCondition {
        if codes.contains(where: { (95...99).contains($0) }) { return .storm }
        if codes.contains(where: { (71...77).contains($0) || (85...86).contains($0) }) { return .snow }
        if rain >= 0.3 || codes.contains(where: { (51...67).contains($0) || (80...82).contains($0) }) {
            return .rain
        }
        if codes.contains(3) || codes.contains(where: { (45...48).contains($0) }) { return .cloudy }
        if codes.contains(1) || codes.contains(2) { return .partlyCloudy }
        return .sunny
    }

    private struct Sample {
        var date: Date
        var temperatureC: Double
        var apparentC: Double?
        var rainProbability: Double
        var code: Int
    }

    private struct Response: Decodable {
        var timezone: String
        var hourly: Hourly
    }

    /// Open-Meteo mixes numbers and nulls in the same column.
    private struct LossyNumber: Decodable {
        var value: Double?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                value = nil
                return
            }
            if let number = try? container.decode(Double.self) {
                value = number
                return
            }
            if let number = try? container.decode(Int.self) {
                value = Double(number)
                return
            }
            value = nil
        }
    }

    private struct Hourly: Decodable {
        var time: [String]
        var temperature_2m: [LossyNumber]
        var apparent_temperature: [LossyNumber]
        var precipitation_probability: [LossyNumber]
        var weathercode: [LossyNumber]
    }
}
