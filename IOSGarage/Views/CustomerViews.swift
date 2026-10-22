import SwiftUI
import SwiftData
import Charts
import MapKit
import PhotosUI

// MARK: - Tabs
struct CustomerTabs: View {
    var body: some View {
        TabView {
            CustomerHome().tabItem { Label("Home", systemImage: "house.fill") }
            VehicleListView().tabItem { Label("Vehicles", systemImage: "car.fill") }
            BookingView().tabItem { Label("Book", systemImage: "calendar.badge.plus") }
            CustomerTowView().tabItem { Label("Tow", systemImage: "truck.box.fill") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

// MARK: - Home dashboard
struct CustomerHome: View {
    @Environment(AuthService.self) private var auth
    @Environment(DataStore.self) private var store
    @Environment(\.modelContext) private var context
    @Query(sort: \Vehicle.createdAt) private var all: [Vehicle]
    private var vehicles: [Vehicle] { all.filter { $0.ownerId == auth.user?.id } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Hello, \(auth.user?.name.components(separatedBy: " ").first ?? "")").font(.largeTitle.bold())

                    if let tow = store.activeTow {
                        Card { Label("Tow: \(tow.status.title)", systemImage: "truck.box.fill").font(.headline)
                            if let d = tow.driverName { Text("Driver: \(d)").font(.subheadline) } }
                    }
                    if let next = store.appointments.filter({ $0.date >= .now && $0.status != .cancelled && $0.status != .rejected }).min(by: { $0.date < $1.date }) {
                        Card {
                            Label("Next appointment", systemImage: "calendar").font(.headline)
                            Text("\(next.service) · \(next.garageName)")
                            Text(next.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                            Badge(text: next.status.title, color: next.status.color)
                        }
                    }
                    Text("Predicted maintenance").font(.title3.bold())
                    if vehicles.isEmpty { ContentUnavailableView("No vehicles yet", systemImage: "car", description: Text("Add one in the Vehicles tab.")) }
                    ForEach(vehicles) { v in
                        NavigationLink { VehicleDetailView(vehicle: v) } label: {
                            Card {
                                Text(v.title).font(.headline)
                                ForEach(MLService.shared.predictMaintenance(for: v).prefix(2)) { PredictionRow(p: $0) }
                            }
                        }.buttonStyle(.plain)
                    }
                    NavigationLink { ExpensesView() } label: {
                        Card { Label("Expenses & receipts", systemImage: "doc.text.viewfinder").font(.headline) }
                    }.buttonStyle(.plain)
                }.padding()
            }
            .navigationTitle("Home").navigationBarTitleDisplayMode(.inline)
            .task { await refreshWidgetAndReminders() }
            .task(id: auth.user?.id) { if vehicles.isEmpty { await store.restoreVehicles(into: context) } }
        }
    }

    private func refreshWidgetAndReminders() async {
        guard let v = vehicles.first, let p = MLService.shared.predictMaintenance(for: v).first else { return }
        SharedStore.write(vehicle: v.title, item: p.component.rawValue, kmRemaining: Int(p.kmRemaining),
                          daysRemaining: p.daysRemaining, tow: store.activeTow?.status.title ?? "")
        for vv in vehicles {
            for p in MLService.shared.predictMaintenance(for: vv) where p.urgency != .ok {
                NotificationService.shared.schedule(id: "maint-\(vv.id)-\(p.component.rawValue)",
                    title: "\(p.component.rawValue) due soon", body: "\(vv.title): ~\(max(0, Int(p.kmRemaining))) km remaining.",
                    at: Calendar.current.date(byAdding: .day, value: 1, to: .now)!)
            }
        }
    }
}

struct PredictionRow: View {
    let p: MaintenancePrediction
    var color: Color { p.urgency == .overdue ? .red : p.urgency == .soon ? .orange : .green }
    var body: some View {
        HStack {
            Image(systemName: p.component.icon).foregroundStyle(color).frame(width: 28)
            VStack(alignment: .leading) {
                Text(p.component.rawValue).font(.subheadline.bold())
                Text(p.kmRemaining <= 0 ? "Overdue" : "in ~\(Int(p.kmRemaining)) km · \(p.dueDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(p.source).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(p.component.rawValue), \(p.kmRemaining <= 0 ? "overdue" : "due in about \(Int(p.kmRemaining)) kilometres")")
    }
}

// MARK: - Vehicles
struct VehicleListView: View {
    @Environment(AuthService.self) private var auth
    @Environment(DataStore.self) private var store
    @Environment(\.modelContext) private var context
    @Query(sort: \Vehicle.createdAt) private var all: [Vehicle]
    @State private var adding = false
    private var vehicles: [Vehicle] { all.filter { $0.ownerId == auth.user?.id } }

    var body: some View {
        NavigationStack {
            List {
                ForEach(vehicles) { v in
                    NavigationLink { VehicleDetailView(vehicle: v) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(v.title).font(.headline)
                            Text("\(v.plate) · \(v.mileage.formatted()) km").font(.subheadline).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine)
                    }
                }
                .onDelete { idx in idx.map { vehicles[$0] }.forEach { v in Task { await store.removeSynced(v) }; context.delete(v) } }
            }
            .overlay { if vehicles.isEmpty { ContentUnavailableView("No vehicles", systemImage: "car", description: Text("Tap + to register your first vehicle.")) } }
            .navigationTitle("My Vehicles")
            .toolbar { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add vehicle") }
            .sheet(isPresented: $adding) { AddVehicleView() }
        }
    }
}

struct AddVehicleView: View {
    @Environment(AuthService.self) private var auth
    @Environment(DataStore.self) private var store
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var plate = "", make = "", model = "", mileage = ""
    @State private var year = Calendar.current.component(.year, from: .now) - 3

    var body: some View {
        NavigationStack {
            Form {
                TextField("Registration number", text: $plate).textInputAutocapitalization(.characters)
                TextField("Make (e.g. Toyota)", text: $make)
                TextField("Model (e.g. Aqua)", text: $model)
                Stepper("Year: \(year.formatted(.number.grouping(.never)))", value: $year, in: 1980...2030)
                TextField("Current mileage (km)", text: $mileage).numeric()
            }
            .navigationTitle("Add Vehicle").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let v = Vehicle(ownerId: auth.user?.id ?? "", plate: plate, make: make, model: model, year: year, mileage: Int(mileage) ?? 0)
                        context.insert(v); Task { await store.sync(v) }; dismiss()
                    }.disabled(plate.isEmpty || make.isEmpty || model.isEmpty)
                }
            }
        }
    }
}

struct VehicleDetailView: View {
    @Bindable var vehicle: Vehicle
    @Environment(DataStore.self) private var store
    @State private var addingService = false
    @State private var mileageText = ""

    private enum Entry: Identifiable {
        case done(ServiceRecord), predicted(MaintenancePrediction)
        var id: String { switch self { case .done(let r): r.id.uuidString; case .predicted(let p): p.id.uuidString } }
        var date: Date { switch self { case .done(let r): r.date; case .predicted(let p): p.dueDate } }
    }
    private var timeline: [Entry] {
        (vehicle.services.map(Entry.done) + MLService.shared.predictMaintenance(for: vehicle).filter { $0.urgency != .ok || $0.daysRemaining < 365 }.map(Entry.predicted))
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            Section("Vehicle") {
                LabeledContent("Registration", value: vehicle.plate)
                HStack { Text("Mileage (km)"); Spacer()
                    TextField("km", text: $mileageText).numeric().multilineTextAlignment(.trailing)
                        .onSubmit { if let m = Int(mileageText) { vehicle.mileage = m; Task { await store.sync(vehicle) } } } }
            }
            Section("AI predictions (\(MLService.shared.predictMaintenance(for: vehicle).first?.source ?? ""))") {
                ForEach(MLService.shared.predictMaintenance(for: vehicle)) { PredictionRow(p: $0) }
            }
            Section("Health timeline") {
                ForEach(timeline) { e in
                    switch e {
                    case .done(let r):
                        VStack(alignment: .leading) {
                            Label(r.type, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.subheadline.bold())
                            Text("\(r.date.formatted(date: .abbreviated, time: .omitted)) · \(r.mileage.formatted()) km · \(r.cost.money)").font(.caption)
                            if !r.parts.isEmpty { Text("Parts: \(r.parts)").font(.caption).foregroundStyle(.secondary) }
                        }.accessibilityElement(children: .combine)
                    case .predicted(let p):
                        Label("\(p.component.rawValue) – predicted \(p.dueDate.formatted(date: .abbreviated, time: .omitted))", systemImage: "sparkles")
                            .foregroundStyle(.orange).font(.subheadline)
                    }
                }
            }
        }
        .navigationTitle(vehicle.title).navigationBarTitleDisplayMode(.inline)
        .toolbar { Button { addingService = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add service record") }
        .sheet(isPresented: $addingService) { AddServiceRecordView(vehicle: vehicle) }
        .onAppear { mileageText = String(vehicle.mileage) }
    }
}

struct AddServiceRecordView: View {
    let vehicle: Vehicle
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var type = ServiceType.oilChange
    @State private var date = Date()
    @State private var mileage = ""
    @State private var cost = ""
    @State private var parts = "", notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Service", selection: $type) { ForEach(ServiceType.allCases) { Text($0.rawValue).tag($0) } }
                DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                TextField("Mileage at service", text: $mileage).numeric()
                TextField("Cost", text: $cost).keyboardType(.decimalPad)
                TextField("Parts replaced", text: $parts)
                TextField("Notes", text: $notes, axis: .vertical)
            }
            .navigationTitle("Service Record").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let m = Int(mileage) ?? vehicle.mileage
                        let r = ServiceRecord(date: date, type: type.rawValue, mileage: m, cost: Double(cost) ?? 0, parts: parts, notes: notes)
                        vehicle.services.append(r); vehicle.mileage = max(vehicle.mileage, m)
                        Task { await store.sync(vehicle) }; dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Booking
struct BookingView: View {
    @Environment(AuthService.self) private var auth
    @Environment(DataStore.self) private var store
    @Query private var all: [Vehicle]
    @State private var vehicle: Vehicle?
    @State private var garage: AppUser?
    @State private var service = ServiceType.fullService
    @State private var date = Calendar.current.date(byAdding: .day, value: 2, to: .now)!
    @State private var message: String?
    private var vehicles: [Vehicle] { all.filter { $0.ownerId == auth.user?.id } }

    var body: some View {
        NavigationStack {
            Form {
                Section("1 · Vehicle") {
                    Picker("Vehicle", selection: $vehicle) { Text("Select").tag(Vehicle?.none); ForEach(vehicles) { Text($0.title).tag(Optional($0)) } }
                }
                Section("2 · Service") { Picker("Service", selection: $service) { ForEach(ServiceType.allCases) { Text("\($0.rawValue) – \($0.basePrice.money)").tag($0) } } }
                Section("3 · Garage") {
                    Picker("Garage", selection: $garage) { Text("Select").tag(AppUser?.none); ForEach(store.garages, id: \.id) { Text($0.name).tag(Optional($0)) } }
                }
                Section("4 · Date & time") {
                    DatePicker("Slot", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                }
                Section {
                    Button("Confirm booking") { Task { await book() } }
                        .buttonStyle(PrimaryButtonStyle()).disabled(vehicle == nil || garage == nil)
                        .listRowInsets(.init()).listRowBackground(Color.clear)
                    if let message { Text(message).font(.footnote) }
                }
                Section("My appointments") {
                    ForEach(store.appointments.sorted { $0.date > $1.date }) { a in
                        HStack {
                            VStack(alignment: .leading) { Text(a.service).bold(); Text("\(a.garageName) · \(a.date.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                            Spacer(); Badge(text: a.status.title, color: a.status.color)
                        }.accessibilityElement(children: .combine)
                    }
                }
            }.navigationTitle("Book a Service")
        }
    }
    private func book() async {
        guard let u = auth.user, let v = vehicle, let g = garage else { return }
        let a = Appointment(customerId: u.id ?? "", customerName: u.name, garageId: g.id ?? "", garageName: g.name,
                            vehicleLabel: v.title, vehiclePlate: v.plate, service: service.rawValue, date: date)
        do { try await store.book(a); message = "Booked! The garage will confirm shortly." } catch { message = error.localizedDescription }
    }
}

// MARK: - Towing (customer)
struct CustomerTowView: View {
    @Environment(AuthService.self) private var auth
    @Environment(DataStore.self) private var store
    @Environment(LocationService.self) private var location
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var route: MKRoute?
    @State private var note = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Map(position: $camera) {
                    UserAnnotation()
                    if let t = store.activeTow {
                        Marker("Breakdown", systemImage: "car.fill", coordinate: t.coordinate).tint(.red)
                        if let d = t.driverCoordinate { Marker("Driver", systemImage: "truck.box.fill", coordinate: d).tint(.blue) }
                    }
                    if let route { MapPolyline(route).stroke(.blue, lineWidth: 5) }
                }
                .mapControls { MapUserLocationButton(); MapCompass() }
                .accessibilityLabel("Map showing your location and tow driver")

                VStack(alignment: .leading, spacing: 10) {
                    if let t = store.activeTow {
                        Text(t.status.title).font(.title3.bold())
                        if let n = t.driverName { Text("Driver: \(n)") }
                        if let r = route, t.status == .accepted || t.status == .enRoute {
                            Label("ETA \(Int(r.expectedTravelTime / 60)) min · \(String(format: "%.1f", r.distance / 1000)) km", systemImage: "clock")
                        }
                        if t.status == .requested { ProgressView("Waiting for a driver…"); Button("Cancel request", role: .destructive) { Task { await store.cancelTow(t) } } }
                    } else {
                        TextField("What happened? (optional)", text: $note).textFieldStyle(.roundedBorder)
                        Button("Request tow to my location") { Task { await request() } }
                            .buttonStyle(PrimaryButtonStyle(tint: .red)).disabled(location.current == nil)
                        if location.current == nil { Text("Waiting for GPS… allow location access.").font(.footnote) }
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.bar)
            }
            .navigationTitle("Roadside Tow").navigationBarTitleDisplayMode(.inline)
            .onAppear { location.requestPermission(); location.start() }
            .task(id: store.activeTow?.driverLat) { await refreshRoute() }
            .onChange(of: store.activeTow?.status) { _, s in if let s { NotificationService.shared.notifyNow(title: "Tow update", body: s.title) } }
        }
    }
    private func request() async {
        guard let u = auth.user, let loc = location.current else { return }
        do { try await store.requestTow(user: u, location: loc, note: note) } catch { self.error = error.localizedDescription }
    }
    private func refreshRoute() async {
        guard let t = store.activeTow, let d = t.driverCoordinate, t.status == .accepted || t.status == .enRoute else { route = nil; return }
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: d))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: t.coordinate))
        req.transportType = .automobile
        route = try? await MKDirections(request: req).calculate().routes.first
    }
}

// MARK: - Expenses & receipt scanning
struct ExpensesView: View {
    @Environment(AuthService.self) private var auth
    @Environment(\.modelContext) private var context
    @Query(sort: \Expense.date, order: .reverse) private var all: [Expense]
    @State private var picked: PhotosPickerItem?
    @State private var scanning = false
    @State private var draft: Expense?
    private var expenses: [Expense] { all.filter { $0.ownerId == auth.user?.id } }

    private var byMonth: [(month: Date, category: String, total: Double)] {
        let cal = Calendar.current
        let g = Dictionary(grouping: expenses) { e in
            "\(cal.date(from: cal.dateComponents([.year, .month], from: e.date))!.timeIntervalSince1970)|\(e.category)" }
        return g.map { k, v in
            let parts = k.split(separator: "|")
            return (Date(timeIntervalSince1970: Double(parts[0])!), String(parts[1]), v.reduce(0) { $0 + $1.amount })
        }.sorted { $0.month < $1.month }
    }

    var body: some View {
        List {
            Section("Spending trend") {
                if expenses.isEmpty { Text("No expenses yet") } else {
                    Chart(byMonth, id: \.month) { BarMark(x: .value("Month", $0.month, unit: .month), y: .value("Spent", $0.total)).foregroundStyle(by: .value("Category", $0.category)) }
                        .frame(height: 180).accessibilityLabel("Monthly spending chart")
                    Text("Total: \(expenses.reduce(0) { $0 + $1.amount }.money)").font(.headline)
                }
            }
            Section("Receipts") {
                ForEach(expenses) { e in
                    VStack(alignment: .leading) {
                        HStack { Text(e.vendor).bold(); Spacer(); Text(e.amount.money) }
                        Text("\(e.category) · \(e.date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        if let w = e.warrantyUntil { Label("Warranty until \(w.formatted(date: .abbreviated, time: .omitted))", systemImage: "checkmark.shield").font(.caption).foregroundStyle(w > .now ? .green : .red) }
                    }.accessibilityElement(children: .combine)
                }.onDelete { $0.map { expenses[$0] }.forEach(context.delete) }
            }
        }
        .navigationTitle("Expenses")
        .toolbar {
            PhotosPicker(selection: $picked, matching: .images) { Image(systemName: "doc.text.viewfinder") }.accessibilityLabel("Scan receipt")
            Button { draft = Expense(ownerId: auth.user?.id ?? "", date: .now, vendor: "", amount: 0, category: "Service") } label: { Image(systemName: "plus") }.accessibilityLabel("Add expense")
        }
        .overlay { if scanning { ProgressView("Reading receipt…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .onChange(of: picked) { _, item in Task { await scan(item) } }
        .sheet(item: $draft) { ExpenseEditor(expense: $0) }
    }

    private func scan(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else { return }
        scanning = true; defer { scanning = false; picked = nil }
        if let r = try? await ReceiptScanner.scan(img) {
            draft = Expense(ownerId: auth.user?.id ?? "", date: r.date ?? .now, vendor: r.vendor, amount: r.total ?? 0, category: "Service", receiptData: data)
        }
    }
}

struct ExpenseEditor: View {
    @Bindable var expense: Expense
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var hasWarranty = false
    @State private var warranty = Calendar.current.date(byAdding: .year, value: 1, to: .now)!
    let categories = ["Service", "Parts", "Fuel", "Insurance", "Tyres", "Other"]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Vendor", text: $expense.vendor)
                TextField("Amount", value: $expense.amount, format: .number).keyboardType(.decimalPad)
                Picker("Category", selection: $expense.category) { ForEach(categories, id: \.self) { Text($0) } }
                DatePicker("Date", selection: $expense.date, displayedComponents: .date)
                Toggle("Has warranty", isOn: $hasWarranty)
                if hasWarranty { DatePicker("Warranty until", selection: $warranty, displayedComponents: .date) }
                if let d = expense.receiptData, let img = UIImage(data: d) { Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 160).accessibilityLabel("Scanned receipt") }
            }
            .navigationTitle("Expense").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { expense.warrantyUntil = hasWarranty ? warranty : nil; context.insert(expense); dismiss() } }
            }
        }
    }
}
