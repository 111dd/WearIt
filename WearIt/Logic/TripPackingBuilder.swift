import Foundation

/// What goes in the suitcase besides the day's looks: counts the user can change,
/// plus a coat or swimwear when the destination's forecast calls for it.
enum TripPackingBuilder {
    static let hotHighC = 26.0
    static let coldLowC = 12.0

    struct Climate: Equatable {
        var suggestsSwim: Bool
        var suggestsCoat: Bool
        var averageHigh: Double?
        var averageLow: Double?
    }

    struct Quantity: Codable, Equatable, Identifiable {
        var id: String
        var count: Int
        var packed: Bool
    }

    static func climate(forecasts: [DayForecast]) -> Climate {
        let highs = forecasts.map(\.highTempC).filter(\.isFinite)
        let lows = forecasts.map(\.lowTempC).filter(\.isFinite)
        let averageHigh = highs.isEmpty ? nil : highs.reduce(0, +) / Double(highs.count)
        let averageLow = lows.isEmpty ? nil : lows.reduce(0, +) / Double(lows.count)
        return Climate(
            suggestsSwim: (averageHigh ?? -100) >= hotHighC,
            suggestsCoat: (averageLow ?? 100) <= coldLowC,
            averageHigh: averageHigh,
            averageLow: averageLow
        )
    }

    /// Underwear and socks scale with the length of the trip. Swimwear and a
    /// generic coat appear only when the forecast says so and the closet has
    /// nothing specific to pack.
    static func quantities(dayCount: Int, climate: Climate, hasCoatInCloset: Bool) -> [Quantity] {
        let days = max(1, dayCount)
        var lines = [
            Quantity(id: "underwear", count: days + 1, packed: false),
            Quantity(id: "socks", count: days + 1, packed: false)
        ]
        if climate.suggestsSwim {
            lines.append(Quantity(id: "swim", count: 1, packed: false))
        }
        if climate.suggestsCoat, !hasCoatInCloset {
            lines.append(Quantity(id: "coat", count: 1, packed: false))
        }
        return lines
    }

    static func isSwimwear(_ garment: Garment) -> Bool {
        if garment.occasionTags?.contains(.beach) == true { return true }
        let title = garment.displayTitle.lowercased()
        let needles = ["swim", "bikini", "בגד ים", "בגד-ים", "swimsuit"]
        return needles.contains { title.contains($0) }
    }

    static func coatCandidates(_ garments: [Garment], veryCold: Bool) -> [Garment] {
        let coats = garments.filter { garment in
            guard garment.category == .outer, !garment.isBlocked, !garment.isCurrentlyUnavailable else { return false }
            switch garment.itemType {
            case .coat, .parka, .puffer, .jacket, .raincoat:
                return true
            default:
                return garment.warmth >= 4
            }
        }
        .sorted { $0.warmth > $1.warmth }
        let limit = veryCold ? 2 : 1
        return Array(coats.prefix(limit))
    }

    static func swimCandidates(_ garments: [Garment]) -> [Garment] {
        Array(garments.filter { isSwimwear($0) && !$0.isBlocked && !$0.isCurrentlyUnavailable }.prefix(2))
    }
}

/// Saved suitcase. Day looks, extra closet pieces (coat, swim), and quantity lines.
struct PackingList: Codable, Equatable {
    var tripID: String
    var days: [PackingDay]
    /// Coats and swimwear pulled from the closet, in addition to the day looks.
    var extraGarmentIDs: [UUID]
    var packedGarmentIDs: [UUID]
    var quantities: [TripPackingBuilder.Quantity]

    static func empty(tripID: String) -> PackingList {
        PackingList(tripID: tripID, days: [], extraGarmentIDs: [], packedGarmentIDs: [], quantities: [])
    }

    var bagGarmentIDs: [UUID] {
        var seen: [UUID] = []
        for day in days {
            for id in day.slotGarments.values where !seen.contains(id) {
                seen.append(id)
            }
        }
        for id in extraGarmentIDs where !seen.contains(id) {
            seen.append(id)
        }
        return seen
    }
}

struct PackingDay: Codable, Equatable, Identifiable {
    var dayStamp: TimeInterval
    /// Slot raw value → garment id.
    var slotGarments: [String: UUID]

    var id: TimeInterval { dayStamp }

    var date: Date { Date(timeIntervalSince1970: dayStamp) }
}

enum TripPackingStore {
    private static let manualKey = "tripPacking.manualTrips"

    static func list(for tripID: String) -> PackingList? {
        guard let data = UserDefaults.standard.data(forKey: storageKey(tripID)) else { return nil }
        return try? JSONDecoder().decode(PackingList.self, from: data)
    }

    static func save(_ list: PackingList) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: storageKey(list.tripID))
    }

    static func manualTrips() -> [TripSpan] {
        guard let data = UserDefaults.standard.data(forKey: manualKey) else { return [] }
        return (try? JSONDecoder().decode([TripSpan].self, from: data)) ?? []
    }

    static func saveManual(_ trips: [TripSpan]) {
        guard let data = try? JSONEncoder().encode(trips) else { return }
        UserDefaults.standard.set(data, forKey: manualKey)
    }

    private static func storageKey(_ tripID: String) -> String {
        "tripPacking.list." + tripID
    }
}
