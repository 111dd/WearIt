import Foundation

/// Local presentation preference only: dismissing advice is not outfit feedback.
enum PlannerChangeSuggestionVisibility {
    private static func key(date: Date, lookTime: LookTime) -> String {
        "\(Calendar.current.startOfDay(for: date).timeIntervalSince1970)|\(lookTime.rawValue)"
    }

    static func isHidden(in stored: String, date: Date, lookTime: LookTime) -> Bool {
        stored.split(separator: "\n").contains(Substring(key(date: date, lookTime: lookTime)))
    }

    static func hiding(in stored: String, date: Date, lookTime: LookTime, now: Date = Date()) -> String {
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: now) ?? now
        var keys = Set(stored.split(separator: "\n").map(String.init).filter { record in
            guard let timestamp = record.split(separator: "|").first.flatMap({ Double($0) }) else { return false }
            return timestamp >= cutoff.timeIntervalSince1970
        })
        keys.insert(key(date: date, lookTime: lookTime))
        return keys.sorted().suffix(64).joined(separator: "\n")
    }
}
