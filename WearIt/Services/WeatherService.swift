
import Foundation
import CoreLocation

struct WeatherSnapshot: Sendable {
    let temperatureC: Double
    let isRaining: Bool
    let source: String
}

enum WeatherService {
    // נחזיר ממוצע טמפ' ל-6 שעות הקרובות + האם צפוי גשם
    static func forecastNextHours(lat: Double, lon: Double, hours: Int = 6) async throws -> WeatherSnapshot {
        // Open-Meteo: טמפ' שעתית + weathercode + הסתברות משקעים
        let url = try buildURL(lat: lat, lon: lon, hours: hours)
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)

        // מצא אינדקסים של השעות הבאות בחלון ה-hours
        let now = Date()
        let times = decoded.hourly.time.compactMap { ISO8601DateFormatter().date(from: $0) }
        let horizon = now.addingTimeInterval(Double(hours) * 3600)

        var temps: [Double] = []
        var rainFlags: [Bool] = []

        for (i, t) in times.enumerated() {
            if t >= now && t <= horizon {
                if i < decoded.hourly.temperature_2m.count {
                    temps.append(decoded.hourly.temperature_2m[i])
                }
                let code = (i < decoded.hourly.weathercode.count) ? decoded.hourly.weathercode[i] : 0
                let p = (i < decoded.hourly.precipitation_probability.count) ? decoded.hourly.precipitation_probability[i] : 0
                rainFlags.append(isRainy(code: code) || p >= 30)
            }
        }

        let avgTemp = temps.isEmpty ? decoded.current_weather?.temperature ?? 22 : (temps.reduce(0,+) / Double(temps.count))
        let raining = rainFlags.contains(true) || (decoded.current_weather.map { isRainy(code: $0.weathercode) } ?? false)

        return WeatherSnapshot(temperatureC: avgTemp, isRaining: raining, source: "Open‑Meteo")
    }

    private static func buildURL(lat: Double, lon: Double, hours: Int) throws -> URL {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "hourly", value: "temperature_2m,precipitation_probability,weathercode"),
            .init(name: "current_weather", value: "true"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_hours", value: String(hours))
        ]
        guard let url = comps.url else { throw URLError(.badURL) }
        return url
    }

    private static func isRainy(code: Int) -> Bool {
        // קודים גשומים לפי Open-Meteo/WW codes
        switch code {
        case 51...67, 80...82, 95...99: return true
        default: return false
        }
    }
}

// MARK: - Models

private struct OpenMeteoResponse: Decodable {
    let current_weather: CurrentWeather?
    let hourly: Hourly
    struct CurrentWeather: Decodable {
        let temperature: Double
        let weathercode: Int
        let time: String
    }
    struct Hourly: Decodable {
        let time: [String]
        let temperature_2m: [Double]
        let precipitation_probability: [Int]
        let weathercode: [Int]
    }
}
