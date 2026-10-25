import SwiftUI
import MapKit

struct DriverTabs: View {
    @Environment(DataStore.self) private var store
    var body: some View {
        TabView {
            if let t = store.activeTow { DriverActiveJobView(job: t).tabItem { Label("Active job", systemImage: "location.fill") } }
            DriverJobsView().tabItem { Label("Jobs", systemImage: "list.bullet") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

struct DriverJobsView: View {
    @Environment(AuthService.self) private var auth
    @Environment(DataStore.self) private var store
    @Environment(LocationService.self) private var location

    var body: some View {
        NavigationStack {
            List(store.openTowRequests) { t in
                VStack(alignment: .leading, spacing: 6) {
                    Text(t.customerName).font(.headline)
                    if let n = t.note { Text(n).font(.subheadline) }
                    if let d = location.distance(to: t.coordinate) { Label("\(String(format: "%.1f", d / 1000)) km away", systemImage: "location") .font(.caption) }
                    Text(t.createdAt.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                    Button("Accept job") { if let u = auth.user { Task { await store.accept(t, driver: u) } } }
                        .buttonStyle(PrimaryButtonStyle()).disabled(store.activeTow != nil)
                }.accessibilityElement(children: .contain)
            }
            .overlay { if store.openTowRequests.isEmpty { ContentUnavailableView("No open requests", systemImage: "truck.box") } }
            .navigationTitle("Tow Requests")
            .onAppear { location.requestPermission(); location.start() }
        }
    }
}

struct DriverActiveJobView: View {
    let job: TowRequest
    @Environment(DataStore.self) private var store
    @Environment(LocationService.self) private var location
    @State private var route: MKRoute?
    @State private var lastPublished: CLLocation?
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        VStack(spacing: 0) {
            Map(position: $camera) {
                UserAnnotation()
                Marker(job.customerName, systemImage: "car.fill", coordinate: job.coordinate).tint(.red)
                if let route { MapPolyline(route).stroke(.blue, lineWidth: 5) }
            }.mapControls { MapUserLocationButton(); MapCompass() }
            VStack(alignment: .leading, spacing: 10) {
                Text(job.status.title).font(.title3.bold())
                Text(job.customerName)
                if let p = job.customerPhone, let url = URL(string: "tel:\(p.filter { $0.isNumber || $0 == "+" })") { Link(destination: url) { Label("Call customer", systemImage: "phone.fill") } }
                if let r = route { Label("\(Int(r.expectedTravelTime / 60)) min · \(String(format: "%.1f", r.distance / 1000)) km", systemImage: "clock") }
                Button("Open in Apple Maps navigation") {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: job.coordinate)); item.name = job.customerName
                    item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
                }.buttonStyle(.bordered)
                if let n = job.status.next {
                    Button("Mark: \(n.title)") { Task { await store.advance(job) } }.buttonStyle(PrimaryButtonStyle(tint: .green))
                }
            }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.bar)
        }
        .onAppear { location.start(); location.monitorArrival(id: job.id ?? "job", at: job.coordinate) }
        .onDisappear { location.stopMonitoring() }
        .onChange(of: location.current) { _, new in Task { await publish(new) } }
        .onChange(of: location.arrivedRegionId) { _, id in if id != nil, job.status == .enRoute { Task { await store.advance(job) } } }
        .task(id: location.current?.coordinate.latitude) { await refreshRoute() }
    }

    private func publish(_ loc: CLLocation?) async {
        guard let loc, (lastPublished?.distance(from: loc) ?? .infinity) > 20 else { return }
        lastPublished = loc
        await store.publishDriverLocation(job, loc.coordinate)
    }
    private func refreshRoute() async {
        guard let me = location.current else { return }
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: me.coordinate))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: job.coordinate))
        req.transportType = .automobile
        route = try? await MKDirections(request: req).calculate().routes.first
    }
}

