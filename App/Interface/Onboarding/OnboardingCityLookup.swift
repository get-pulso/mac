import CoreLocation

/// Asks the system where the Mac is and answers with a city, or with nothing.
/// The first press asks Location Services itself; a refusal, an error or a
/// long silence all come back as `nil`, and the chip becomes a field. Nothing
/// is explained, nothing is stored: the city is the only thing that leaves.
@MainActor
final class OnboardingCityLookup: NSObject, CLLocationManagerDelegate {
    // MARK: Internal

    static func city(timeout: Double = 10) async -> String? {
        let lookup = OnboardingCityLookup()
        Self.active = lookup
        defer { if Self.active === lookup { Self.active = nil } }
        guard let location = await lookup.location(timeout: timeout) else { return nil }
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        return placemark?.locality ?? placemark?.subAdministrativeArea ?? placemark?.administrativeArea
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationChanged(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.finish(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    // MARK: Private

    /// Kept alive for the duration of one lookup; the manager needs an owner.
    private static var active: OnboardingCityLookup?

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var waitingForAuthorization = false

    private func location(timeout: Double) async -> CLLocation? {
        self.manager.delegate = self
        self.manager.desiredAccuracy = kCLLocationAccuracyKilometer
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.authorizationChanged(self.manager.authorizationStatus, initial: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(nil) }
        }
    }

    private func authorizationChanged(_ status: CLAuthorizationStatus, initial: Bool = false) {
        guard self.continuation != nil else { return }
        switch status {
        case .notDetermined:
            // The system asks; the answer arrives here again.
            guard initial, !self.waitingForAuthorization else { return }
            self.waitingForAuthorization = true
            self.manager.requestWhenInUseAuthorization()
        case .authorizedAlways,
             .authorizedWhenInUse:
            self.manager.requestLocation()
        default:
            self.finish(nil)
        }
    }

    private func finish(_ location: CLLocation?) {
        guard let continuation else { return }
        self.continuation = nil
        self.manager.stopUpdatingLocation()
        continuation.resume(returning: location)
    }
}
