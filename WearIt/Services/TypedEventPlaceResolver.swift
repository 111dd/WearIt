import Foundation
import CoreLocation

/// Turns a typed event location ("Eilat", "London") into a place, for events
/// with no map pin. A guessed place counts only for trips and all-day events,
/// so "office" on a meeting never moves a look; a place the user picked from
/// the search list counts for any event. Answers are cached for good, so each
/// text is looked up once.
@MainActor
final class TypedEventPlaceResolver {
    static let shared = TypedEventPlaceResolver()

    private struct Stored: Codable {
        var name: String?
        var latitude: Double?
        var longitude: Double?
        /// Set when the geocoder found nothing; retried after `missRetry`.
        var missedAt: Date?
        /// Chosen by the user from the place search. Never replaced by a guess.
        var userPicked: Bool?
    }

    private let defaultsKey = "calendar.typedPlaces.v1"
    private let missRetry: TimeInterval = 7 * 24 * 3600
    private let maxLookupsPerPass = 5
    private var stored: [String: Stored]
    private var pending: [String] = []
    private var isResolving = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Stored].self, from: data) {
            stored = decoded
        } else {
            stored = [:]
        }
    }

    /// Cached place for a typed location, or nil. With `allowGuess`, a text not
    /// looked up yet is queued for `resolvePending()`; without it only the
    /// user's own pick counts.
    func place(for rawText: String, allowGuess: Bool = true) -> EventPlace? {
        guard let key = Self.key(rawText) else { return nil }
        if !allowGuess {
            guard let hit = stored[key], hit.userPicked == true else { return nil }
        }
        if let hit = stored[key] {
            if let lat = hit.latitude, let lon = hit.longitude {
                return EventPlace(name: hit.name ?? rawText.trimmingCharacters(in: .whitespacesAndNewlines),
                                  latitude: lat, longitude: lon)
            }
            if let missedAt = hit.missedAt, Date().timeIntervalSince(missedAt) < missRetry { return nil }
        }
        if !pending.contains(key) { pending.append(key) }
        return nil
    }

    /// Whether this text can be given a place (not a link or a video call).
    static func canPick(_ rawText: String) -> Bool { key(rawText) != nil }

    func isUserPicked(_ rawText: String) -> Bool {
        guard let key = Self.key(rawText) else { return false }
        return stored[key]?.userPicked == true
    }

    /// The user's pick for a typed location. Nil clears it, so the text is
    /// guessed again (trips and all-day events only).
    func setUserPlace(_ place: EventPlace?, for rawText: String) {
        guard let key = Self.key(rawText) else { return }
        if let place {
            stored[key] = Stored(
                name: place.name,
                latitude: place.latitude,
                longitude: place.longitude,
                userPicked: true
            )
        } else {
            stored[key] = nil
        }
        pending.removeAll { $0 == key }
        save()
    }

    /// Looks up queued texts. Returns true when a new place was found, so the
    /// caller can re-read the calendar.
    func resolvePending(near home: CLLocationCoordinate2D?) async -> Bool {
        guard !isResolving, !pending.isEmpty else { return false }
        isResolving = true
        defer { isResolving = false }
        let batch = Array(pending.prefix(maxLookupsPerPass))
        pending.removeFirst(batch.count)
        // Prefer matches near home, so a vague name stays local (and on the home forecast).
        let region = home.map { CLCircularRegion(center: $0, radius: 100_000, identifier: "home") }
        var found = false
        for text in batch where stored[text]?.userPicked != true {
            do {
                let marks = try await CLGeocoder().geocodeAddressString(text, in: region)
                // The user picked a place while this lookup ran: theirs wins.
                if stored[text]?.userPicked == true { continue }
                if let mark = marks.first, let location = mark.location {
                    stored[text] = Stored(
                        name: mark.locality ?? mark.administrativeArea ?? mark.country ?? text,
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude
                    )
                    found = true
                } else {
                    stored[text] = Stored(missedAt: Date())
                }
            } catch let error as CLError where error.code == .geocodeFoundNoResult
                || error.code == .geocodeFoundPartialResult {
                stored[text] = Stored(missedAt: Date())
            } catch {
                // Offline or throttled: try again on a later pass.
                pending.append(text)
                break
            }
        }
        save()
        return found
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// Normalized lookup text, or nil for links and text that can't be a place.
    private static func key(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= 120 else { return nil }
        let lower = text.lowercased()
        let online = ["http", "www.", "zoom", "teams", "meet.google", "webex", "online", "אונליין", "זום"]
        if online.contains(where: { lower.contains($0) }) { return nil }
        guard text.contains(where: \.isLetter) else { return nil }
        return text
    }
}
