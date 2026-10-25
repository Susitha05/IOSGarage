import Foundation
import SwiftData
import CoreLocation
import FirebaseFirestore

/// Single cloud-sync layer (Firestore). Firestore's built-in disk cache gives offline reads/writes;
/// personal vehicle data lives locally in SwiftData and is mirrored to users/{uid}/vehicles.
@Observable @MainActor
final class DataStore {
    var appointments: [Appointment] = []
    var inventory: [InventoryItem] = []
    var staff: [Staff] = []
    var garages: [AppUser] = []
    var openTowRequests: [TowRequest] = []
    var activeTow: TowRequest?

    private var listeners: [ListenerRegistration] = []
    pprivate var db: Firestore { Firestore.firestore() }
    private var currentUser: AppUser?

    // MARK: listeners
    func start(for user: AppUser) {
        stop()
        guard let uid = user.id else { return }
        currentUser = user
        NotificationService.shared.subscribe(role: user.role)
        switch user.role {
        case .customer:
            listen(db.collection("appointments").whereField("customerId", isEqualTo: uid)) { (r: [Appointment]) in self.appointments = r }
            listen(db.collection("users").whereField("role", isEqualTo: UserRole.garageOwner.rawValue)) { (r: [AppUser]) in self.garages = r }
            listen(db.collection("towRequests").whereField("customerId", isEqualTo: uid)) { (r: [TowRequest]) in
                self.activeTow = r.filter { $0.status.isActive }.sorted { $0.createdAt > $1.createdAt }.first
            }
        case .garageOwner:
            listen(db.collection("appointments").whereField("garageId", isEqualTo: uid)) { (r: [Appointment]) in self.appointments = r }
            listen(db.collection("inventory").whereField("garageId", isEqualTo: uid)) { (r: [InventoryItem]) in self.inventory = r.sorted { $0.name < $1.name } }
            listen(db.collection("staff").whereField("garageId", isEqualTo: uid)) { (r: [Staff]) in self.staff = r.sorted { $0.name < $1.name } }
        case .towDriver:
            listen(db.collection("towRequests").whereField("status", isEqualTo: TowStatus.requested.rawValue)) { (r: [TowRequest]) in
                self.openTowRequests = r.sorted { $0.createdAt > $1.createdAt }
            }
            listen(db.collection("towRequests").whereField("driverId", isEqualTo: uid)) { (r: [TowRequest]) in
                self.activeTow = r.filter { $0.status.isActive }.first
            }
        }
    }

    func stop() {
        listeners.forEach { $0.remove() }; listeners = []
        appointments = []; inventory = []; staff = []; garages = []; openTowRequests = []; activeTow = nil
    }

    private func listen<T: Decodable>(_ query: Query, _ handler: @escaping @MainActor ([T]) -> Void) {
        let l = query.addSnapshotListener { snap, _ in
            guard let docs = snap?.documents else { return }
            let items = docs.compactMap { try? $0.data(as: T.self) }
            Task { @MainActor in handler(items) }
        }
        listeners.append(l)
    }

    // MARK: appointments
    func book(_ a: Appointment) async throws { _ = try db.collection("appointments").addDocument(from: a) }

    func setStatus(_ a: Appointment, _ status: AppointmentStatus) async {
        guard let id = a.id, a.status.canTransition(to: status) else { return }
        var data: [String: Any] = ["status": status.rawValue]
        if status == .completed, a.price == nil { data["price"] = ServiceType(rawValue: a.service)?.basePrice ?? 100 }
        try? await db.collection("appointments").document(id).updateData(data)
    }

    func reschedule(_ a: Appointment, to date: Date) async {
        guard let id = a.id else { return }
        try? await db.collection("appointments").document(id).updateData(["date": Timestamp(date: date)])
    }

    func assign(_ a: Appointment, to s: Staff) async {
        guard let id = a.id else { return }
        try? await db.collection("appointments").document(id)
            .updateData(["assignedStaffId": s.id ?? "", "assignedStaffName": s.name])
    }

    // MARK: inventory & staff
    func save(_ item: InventoryItem) async {
        if let id = item.id { try? db.collection("inventory").document(id).setData(from: item) }
        else { _ = try? db.collection("inventory").addDocument(from: item) }
    }
    func delete(_ item: InventoryItem) async { if let id = item.id { try? await db.collection("inventory").document(id).delete() } }
    func recordUsage(_ item: InventoryItem, qty: Int) async {
        var i = item
        i.stock = max(0, i.stock - qty)
        if i.monthlyUsage.isEmpty { i.monthlyUsage = [0] }
        i.monthlyUsage[i.monthlyUsage.count - 1] += Double(qty)
        await save(i)
    }
    func addStaff(name: String, garageId: String) async { _ = try? db.collection("staff").addDocument(from: Staff(garageId: garageId, name: name)) }
    func delete(_ s: Staff) async { if let id = s.id { try? await db.collection("staff").document(id).delete() } }

    // MARK: towing
    func requestTow(user: AppUser, location: CLLocation, note: String) async throws {
        let req = TowRequest(customerId: user.id ?? "", customerName: user.name, customerPhone: user.phone,
                             lat: location.coordinate.latitude, lon: location.coordinate.longitude,
                             note: note.isEmpty ? nil : note)
        _ = try db.collection("towRequests").addDocument(from: req)
    }
    func cancelTow(_ t: TowRequest) async {
        guard let id = t.id else { return }
        try? await db.collection("towRequests").document(id).updateData(["status": TowStatus.cancelled.rawValue])
    }
    func accept(_ t: TowRequest, driver: AppUser) async {
        guard let id = t.id else { return }
        try? await db.collection("towRequests").document(id)
            .updateData(["status": TowStatus.accepted.rawValue, "driverId": driver.id ?? "", "driverName": driver.name])
    }
    func advance(_ t: TowRequest) async {
        guard let id = t.id, let n = t.status.next else { return }
        try? await db.collection("towRequests").document(id).updateData(["status": n.rawValue])
    }
    func publishDriverLocation(_ t: TowRequest, _ c: CLLocationCoordinate2D) async {
        guard let id = t.id else { return }
        try? await db.collection("towRequests").document(id).updateData(["driverLat": c.latitude, "driverLon": c.longitude])
    }

    // MARK: vehicle cloud sync (SwiftData ⇄ Firestore)
    func sync(_ v: Vehicle) async {
        guard let uid = currentUser?.id else { return }
        let services = v.services.map { s -> [String: Any] in
            ["id": s.id.uuidString, "type": s.type, "date": Timestamp(date: s.date), "mileage": s.mileage,
             "cost": s.cost, "parts": s.parts, "notes": s.notes]
        }
        let data: [String: Any] = ["plate": v.plate, "make": v.make, "model": v.model, "year": v.year,
                                   "mileage": v.mileage, "createdAt": Timestamp(date: v.createdAt), "services": services]
        try? await db.collection("users").document(uid).collection("vehicles").document(v.id.uuidString).setData(data)
    }
    func removeSynced(_ v: Vehicle) async {
        guard let uid = currentUser?.id else { return }
        try? await db.collection("users").document(uid).collection("vehicles").document(v.id.uuidString).delete()
    }
    /// Call when a signed-in user has no local vehicles (new device / reinstall).
    func restoreVehicles(into context: ModelContext) async {
        guard let uid = currentUser?.id,
              let snap = try? await db.collection("users").document(uid).collection("vehicles").getDocuments() else { return }
        for d in snap.documents {
            let x = d.data()
            let v = Vehicle(ownerId: uid, plate: x["plate"] as? String ?? "", make: x["make"] as? String ?? "",
                            model: x["model"] as? String ?? "", year: x["year"] as? Int ?? 2020, mileage: x["mileage"] as? Int ?? 0)
            v.id = UUID(uuidString: d.documentID) ?? UUID()
            v.createdAt = (x["createdAt"] as? Timestamp)?.dateValue() ?? .now
            context.insert(v)
            for s in x["services"] as? [[String: Any]] ?? [] {
                let r = ServiceRecord(date: (s["date"] as? Timestamp)?.dateValue() ?? .now, type: s["type"] as? String ?? "",
                                      mileage: s["mileage"] as? Int ?? 0, cost: s["cost"] as? Double ?? 0,
                                      parts: s["parts"] as? String ?? "", notes: s["notes"] as? String ?? "")
                r.vehicle = v
                context.insert(r)
            }
        }
    }

    // MARK: demo data for garage owners (so ML charts have history)
    func seedDemoData(garage: AppUser) async {
        guard let gid = garage.id else { return }
        let cal = Calendar.current
        let batch = db.batch()
        let names = ["Nimal", "Kasun", "Dilani"]
        var staffIds: [(String, String)] = []
        for n in names {
            let ref = db.collection("staff").document()
            try? batch.setData(from: Staff(garageId: gid, name: n), forDocument: ref)
            staffIds.append((ref.documentID, n))
        }
        let parts: [(String, Int, Int, Double)] = [("Engine Oil 5W-30 (L)", 40, 25, 12), ("Oil Filter", 18, 15, 6),
            ("Brake Pads (set)", 9, 8, 45), ("Air Filter", 22, 10, 9), ("Car Battery", 4, 5, 110), ("Coolant (L)", 30, 12, 8)]
        for (i, p) in parts.enumerated() {
            let usage = (0..<12).map { m in max(0, Double(p.2) / 2 + 3 * sin(Double(m + i) / 12 * 2 * .pi) * 2 + Double.random(in: -2...2)) }
            let item = InventoryItem(garageId: gid, name: p.0, stock: p.1, minThreshold: p.2 / 2, unitCost: p.3, monthlyUsage: usage)
            try? batch.setData(from: item, forDocument: db.collection("inventory").document())
        }
        let services = ServiceType.allCases
        for monthsAgo in stride(from: 23, through: 1, by: -1) {
            guard let base = cal.date(byAdding: .month, value: -monthsAgo, to: .now) else { continue }
            let season = 1 + 0.25 * sin(Double(cal.component(.month, from: base)) / 12 * 2 * .pi)
            let growth = 1 + Double(24 - monthsAgo) * 0.015
            let count = Int(10 * season * growth)
            for _ in 0..<count {
                let s = services.randomElement()!
                let st = staffIds.randomElement()!
                let day = cal.date(byAdding: .day, value: Int.random(in: 0..<27), to: cal.date(from: cal.dateComponents([.year, .month], from: base))!)!
                var price = s.basePrice * Double.random(in: 0.9...1.15)
                if Int.random(in: 0..<60) == 0 { price *= 3.2 }            // injected outlier for anomaly demo
                let a = Appointment(customerId: "demo\(Int.random(in: 1...30))", customerName: "Customer \(Int.random(in: 1...30))",
                                    garageId: gid, garageName: garage.name, vehicleLabel: "Demo Car", vehiclePlate: "CAB-\(Int.random(in: 1000...1040))",
                                    service: s.rawValue, date: day, status: Int.random(in: 0..<12) == 0 ? .noShow : .completed,
                                    assignedStaffId: st.0, assignedStaffName: st.1, price: price)
                try? batch.setData(from: a, forDocument: db.collection("appointments").document())
            }
        }
        try? await batch.commit()
    }
}
