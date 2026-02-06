import Foundation
import CoreLocation

@MainActor
final class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()

    private let manager = CLLocationManager()
    private var isRequestingAuth = false
    private var authWaiters: [CheckedContinuation<Void, Error>] = []
    private var locCont: CheckedContinuation<CLLocationCoordinate2D, Error>?

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    enum LocError: Error, LocalizedError {
        case denied, restricted, servicesDisabled, busy, timeout, noLocation, underlying(Error)
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

    // MARK: Public API

    func requestLocation() async throws -> CLLocationCoordinate2D {
        guard await servicesEnabled() else {
            throw LocError.servicesDisabled
        }

        try await requestWhenInUseAuthorization()

        if locCont != nil { throw LocError.busy }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CLLocationCoordinate2D, Error>) in
            self.locCont = cont
            self.manager.requestLocation()

            // Timeout אחרי 10 שניות
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

    // MARK: Authorization

    private func requestWhenInUseAuthorization() async throws {
        guard await servicesEnabled() else {
            throw LocError.servicesDisabled
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Check current authorization status first to avoid unnecessary prompting on the main thread
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                cont.resume()
                return
            case .denied:
                cont.resume(throwing: LocError.denied)
                return
            case .restricted:
                cont.resume(throwing: LocError.restricted)
                return
            case .notDetermined:
                break // proceed to request below
            @unknown default:
                cont.resume(throwing: LocError.restricted)
                return
            }

            // Queue the continuation and request authorization only once
            authWaiters.append(cont)

            if !isRequestingAuth {
                isRequestingAuth = true
                manager.requestWhenInUseAuthorization()
            }
        }
    }

    private func servicesEnabled() async -> Bool {
        await Task.detached(priority: .utility) {
            CLLocationManager.locationServicesEnabled()
        }.value
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: @MainActor CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            let waiters = authWaiters; authWaiters.removeAll(); isRequestingAuth = false
            waiters.forEach { $0.resume() }

        case .denied:
            let waiters = authWaiters; authWaiters.removeAll(); isRequestingAuth = false
            waiters.forEach { $0.resume(throwing: LocError.denied) }

        case .restricted:
            let waiters = authWaiters; authWaiters.removeAll(); isRequestingAuth = false
            waiters.forEach { $0.resume(throwing: LocError.restricted) }

        case .notDetermined:
            break

        @unknown default:
            let waiters = authWaiters; authWaiters.removeAll(); isRequestingAuth = false
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
        let ns = error as NSError
        if ns.domain == kCLErrorDomain as String, ns.code == 1 {
            cont.resume(throwing: LocError.denied)
        } else {
            cont.resume(throwing: LocError.underlying(error))
        }
    }
}
