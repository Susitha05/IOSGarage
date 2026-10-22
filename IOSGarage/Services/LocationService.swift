import CoreLocation
import Observation

@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    var current: CLLocation?
    var status: CLAuthorizationStatus = .notDetermined
    var arrivedRegionId: String?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        status = manager.authorizationStatus
    }

    func requestPermission() { manager.requestWhenInUseAuthorization() }
    func start() { manager.startUpdatingLocation() }
    func stop() { manager.stopUpdatingLocation() }

    /// Geofence around the customer's breakdown point; fires when the driver is within `radius` metres.
    func monitorArrival(id: String, at coordinate: CLLocationCoordinate2D, radius: CLLocationDistance = 100) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let region = CLCircularRegion(center: coordinate, radius: radius, identifier: id)
        region.notifyOnEntry = true; region.notifyOnExit = false
        manager.startMonitoring(for: region)
    }
    func stopMonitoring() { manager.monitoredRegions.forEach { manager.stopMonitoring(for: $0) } }

    func distance(to c: CLLocationCoordinate2D) -> CLLocationDistance? {
        current?.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
    }

    // MARK: delegate
    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) { current = locations.last }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        status = m.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways { m.startUpdatingLocation() }
    }
    func locationManager(_ m: CLLocationManager, didEnterRegion region: CLRegion) { arrivedRegionId = region.identifier }
}
