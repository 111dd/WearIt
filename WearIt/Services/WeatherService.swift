import Foundation
import CoreLocation

// צילום מצב שמסכם את התחזית הקרובה (ל־N שעות קדימה)
struct WeatherSnapshot: Sendable {
    let temperatureC: Double       // ממוצע טמפ' בחלון
    let isRaining: Bool            // האם צפוי גשם באחת השעות בחלון
    let source: String             // לזיהוי מקור המידע
}

enum WeatherService {
    // ממוצע טמפ' ל־`hours` הקרובות + האם צפוי גשם (ע"פ weathercode/הסתברות)
    static func forecastNextHours(lat: Double, lon: Double, hours: Int = 6) async throws -> WeatherSnapshot {
        let h = max(1, min(hours, 48)) // תחום סביר
        let url = try buildURL(lat: lat, lon: lon, hours: h)

        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)

        let now = Date()
        let horizon = now.addingTimeInterval(Double(h) * 3600)

        // פורמט ISO8601 פעם אחת (יעיל ובטוח)
        let times: [Date] = decoded.hourly.time.compactMap { iso.date(from: $0) }

        var temps: [Double] = []
        var rainFlags: [Bool] = []

        // נלך לפי האינדקס המשותף של כל הסדרות, עם בדיקת גבולות בטוחה
        let count = min(times.count,
                        decoded.hourly.temperature_2m.count,
                        decoded.hourly.weathercode.count,
                        decoded.hourly.precipitation_probability.count)

        for i in 0..<count {
            let t = times[i]
            guard t >= now && t <= horizon else { continue }

            let temp = decoded.hourly.temperature_2m[i]
            let code = decoded.hourly.weathercode[i]
            let prob = decoded.hourly.precipitation_probability[i]   // 0..100

            temps.append(temp)
            let rainy = isRainy(code: code) || prob >= 30
            rainFlags.append(rainy)
        }

        // ממוצע טמפ' – אם אין נתוני שעה, ניפול לטמפ' הנוכחית
        let avgTemp: Double = {
            if !temps.isEmpty { return temps.reduce(0, +) / Double(temps.count) }
            return decoded.current_weather?.temperature ?? 22
        }()

        // גשם צפוי – אם אין נתוני שעה, נפתח מהמצב הנוכחי
        let raining: Bool = {
            if !rainFlags.isEmpty { return rainFlags.contains(true) }
            if let cw = decoded.current_weather { return isRainy(code: cw.weathercode) }
            return false
        }()

        return WeatherSnapshot(temperatureC: avgTemp, isRaining: raining, source: "Open-Meteo")
    }

    // MARK: - Helpers

    private static func buildURL(lat: Double, lon: Double, hours: Int) throws -> URL {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weathercode"),
            URLQueryItem(name: "current_weather", value: "true"),
            URLQueryItem(name: "timezone", value: "auto"),
            // לא כל ה־deployments של Open-Meteo תומכים ב־forecast_hours; אם יוסר, עדיין נקבל שעות קדימה ונחתוך בקוד
            URLQueryItem(name: "forecast_hours", value: String(hours))
        ]
        guard let url = comps.url else { throw URLError(.badURL) }
        return url
    }

    // קודי גשם (Open-Meteo/WW)
    private static func isRainy(code: Int) -> Bool {
        switch code {
        case 51...67, 80...82, 95...99: return true
        default: return false
        }
    }

    // ISO8601 formatter אחד לשימוש פנימי
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds] // תומך בשני הסגנונות
        return f
    }()
}

// MARK: - API Models

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
        let precipitation_probability: [Int] // 0..100
        let weathercode: [Int]
    }
}
