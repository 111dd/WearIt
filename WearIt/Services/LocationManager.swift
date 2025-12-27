import Foundation
import CoreLocation

@MainActor
final class LocationManager: NSObject, ObservableObject {
    private let manager = CLLocationManager()

    // Continuations
    private var isRequestingAuth = false
    private var authWaiters: [CheckedContinuation<Void, Error>] = []
    private var locCont: CheckedContinuation<CLLocationCoordinate2D, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    enum LocError: Error, LocalizedError {
        case denied
        case restricted
        case servicesDisabled
        case busy
        case timeout
        case noLocation
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .denied: return "Location permission was denied."
            case .restricted: return "Location access is restricted."
            case .servicesDisabled: return "Location Services are disabled."
            case .busy: return "A location request is already in progress."
            case .timeout: return "Timed out while fetching location."
            case .noLocation: return "No location available."
            case .underlying(let e): return e.localizedDescription
            }
        }
    }

    // Public API
    func requestLocation() async throws -> CLLocationCoordinate2D {
        // 1) שירותי מיקום פעילים?
        guard CLLocationManager.locationServicesEnabled() else {
            throw LocError.servicesDisabled
        }

        // 2) ודא הרשאה
        switch manager.authorizationStatus {
        case .notDetermined:
            try await requestWhenInUseAuthorization()
        case .denied:
            throw LocError.denied
        case .restricted:
            throw LocError.restricted
        default:
            break
        }

        // 3) מניעת בקשה חופפת
        if locCont != nil {
            throw LocError.busy
        }

        // 4) בקש מיקום + timeout בטוח
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CLLocationCoordinate2D, Error>) in
            self.locCont = cont
            self.manager.requestLocation()

            // Timeout: אם אחרי 10 שניות לא קיבלנו תשובה – נסגור עם שגיאה
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                await MainActor.run {
                    guard let self, let cont = self.locCont else { return }
                    self.locCont = nil
                    cont.resume(throwing: LocError.timeout)
                }
            }
        }
    }

    // MARK: - Authorization flow

    private func requestWhenInUseAuthorization() async throws {
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Enqueue this waiter
            self.authWaiters.append(cont)

            // Fire the system prompt only once
            if !self.isRequestingAuth {
                self.isRequestingAuth = true
                self.manager.requestWhenInUseAuthorization()
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            let waiters = authWaiters
            authWaiters.removeAll()
            isRequestingAuth = false
            waiters.forEach { $0.resume() }

        case .denied:
            let waiters = authWaiters
            authWaiters.removeAll()
            isRequestingAuth = false
            waiters.forEach { $0.resume(throwing: LocError.denied) }

        case .restricted:
            let waiters = authWaiters
            authWaiters.removeAll()
            isRequestingAuth = false
            waiters.forEach { $0.resume(throwing: LocError.restricted) }

        case .notDetermined:
            // עדיין ממתינים – לא להחזיר כלום
            break

        @unknown default:
            let waiters = authWaiters
            authWaiters.removeAll()
            isRequestingAuth = false
            waiters.forEach { $0.resume(throwing: LocError.restricted) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let cont = locCont else { return }
        guard let loc = locations.last else {
            locCont = nil
            cont.resume(throwing: LocError.noLocation)
            return
        }
        locCont = nil
        cont.resume(returning: loc.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let cont = locCont else { return }
        locCont = nil

        // kCLErrorDomain Code=1 => denied
        let ns = error as NSError
        if ns.domain == kCLErrorDomain as String, ns.code == 1 {
            cont.resume(throwing: LocError.denied)
        } else {
            cont.resume(throwing: LocError.underlying(error))
        }
    }
}
