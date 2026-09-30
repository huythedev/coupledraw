import CoreLocation
import Foundation
import Combine

/// Opt-in sideload experiment. Location coordinates are ignored and never sent
/// to the sync service; iOS may still suspend the process or stop updates.
final class BackgroundLocationExperiment: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "backgroundLocationExperiment")
    @Published private(set) var message = "Off"
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 500
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        // iOS requires the prominent indicator with When In Use authorization.
        // With Always authorization, Apple permits this property to hide it.
        manager.showsBackgroundLocationIndicator = manager.authorizationStatus != .authorizedAlways
        if enabled { start() }
    }

    func setEnabled(_ active: Bool) {
        enabled = active
        UserDefaults.standard.set(active, forKey: "backgroundLocationExperiment")
        if active { start() } else {
            manager.stopUpdatingLocation()
            message = "Off"
        }
    }

    func requestAlwaysAccess() {
        guard enabled, manager.authorizationStatus == .authorizedWhenInUse else { return }
        message = "iOS may show the Always upgrade later. While Using can still test this session."
        manager.requestAlwaysAuthorization()
    }

    private func start() {
        manager.showsBackgroundLocationIndicator = manager.authorizationStatus != .authorizedAlways
        guard CLLocationManager.locationServicesEnabled() else {
            message = "Enable Location Services in Settings"
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            message = "Choose While Using the App when iOS asks."
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            message = "While Using granted. Background session can be tested; Always is optional."
            manager.startUpdatingLocation()
        case .authorizedAlways:
            message = "Always granted. Prominent background location indicator requested off."
            manager.startUpdatingLocation()
        default:
            message = "Location permission denied; experiment cannot run"
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if enabled { start() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Deliberately discard coordinates. The ordinary sync loop handles polls.
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        message = "Location activity paused: \(error.localizedDescription)"
    }

    var canTryBackground: Bool {
        enabled && (manager.authorizationStatus == .authorizedWhenInUse ||
                    manager.authorizationStatus == .authorizedAlways)
    }
    var canRequestAlways: Bool { enabled && manager.authorizationStatus == .authorizedWhenInUse }
}
