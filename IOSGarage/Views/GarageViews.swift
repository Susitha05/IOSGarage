import SwiftUI
import Charts

struct GarageTabs: View {
    var body: some View {
        TabView {
            GarageAppointmentsView().tabItem { Label("Appointments", systemImage: "calendar") }
            InventoryView().tabItem { Label("Inventory", systemImage: "shippingbox.fill") }
            InsightsView().tabItem { Label("Insights", systemImage: "chart.xyaxis.line") }
            StaffView().tabItem { Label("Staff", systemImage: "person.3.fill") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

// MARK: - Appointments
struct GarageAppointmentsView: View {
    @Environment(DataStore.self) private var store
    @State private var filter: AppointmentStatus? = .pending

    private var rows: [Appointment] {
        store.appointments.filter { filter == nil || $0.status == filter }.sorted { $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Filter", selection: $filter) {
                    Text("All").tag(AppointmentStatus?.none)
                    ForEach([AppointmentStatus.pending, .confirmed, .inProgress, .completed], id: \.self) { Text($0.title).tag(Optional($0)) }
                }.pickerStyle(.segmented).listRowSeparator(.hidden)
                ForEach(rows) { a in
                    NavigationLink { AppointmentDetailView(appointment: a) } label: { AppointmentRow(a: a, history: store.appointments) }
                }
            }
            .overlay { if rows.isEmpty { ContentUnavailableView("No appointments", systemImage: "calendar") } }
            .navigationTitle("Appointments")
        }
    }
}

struct AppointmentRow: View {
    let a: Appointment; let history: [Appointment]
    var body: some View {
        let risk = a.status == .pending || a.status == .confirmed ? MLService.shared.noShowRisk(for: a, history: history) : nil
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(a.service).font(.headline); Spacer(); Badge(text: a.status.title, color: a.status.color) }
            Text("\(a.customerName) · \(a.vehiclePlate)").font(.subheadline)
            Text(a.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            if let risk, risk > 0.3 { Label("No-show risk \(Int(risk * 100))%", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(risk > 0.5 ? .red : .orange) }
        }.accessibilityElement(children: .combine)
    }
}

struct AppointmentDetailView: View {
    let appointment: Appointment
    @Environment(DataStore.self) private var store
    @State private var newDate = Date()
    private var live: Appointment { store.appointments.first { $0.id == appointment.id } ?? appointment }

    var body: some View {
        Form {
            Section("Details") {
                LabeledContent("Customer", value: live.customerName)
                LabeledContent("Vehicle", value: "\(live.vehicleLabel) (\(live.vehiclePlate))")
                LabeledContent("Service", value: live.service)
                LabeledContent("When", value: live.date.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Status") { Badge(text: live.status.title, color: live.status.color) }
                let r = MLService.shared.noShowRisk(for: live, history: store.appointments)
                LabeledContent("No-show risk", value: "\(Int(r * 100))%")
            }
            Section("Actions") {
                ForEach(AppointmentStatus.allCases.filter { live.status.canTransition(to: $0) }, id: \.self) { s in
                    Button(actionTitle(s), role: (s == .rejected || s == .cancelled) ? .destructive : nil) { Task { await store.setStatus(live, s) } }
                        .frame(minHeight: 44)
                }
            }
            Section("Assign staff") {
                if let best = Analytics.leastLoaded(store.staff, store.appointments) { Text("Suggested (least loaded): \(best.name)").font(.footnote).foregroundStyle(.secondary) }
                ForEach(store.staff) { s in
                    Button { Task { await store.assign(live, to: s) } } label: {
                        HStack { Text(s.name); Spacer(); if live.assignedStaffId == s.id { Image(systemName: "checkmark") } }
                    }
                }
            }
            Section("Reschedule") {
                DatePicker("New slot", selection: $newDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                Button("Reschedule") { Task { await store.reschedule(live, to: newDate) } }
            }
        }
        .navigationTitle("Appointment").onAppear { newDate = appointment.date }
    }
    private func actionTitle(_ s: AppointmentStatus) -> String {
        switch s { case .confirmed: "Accept"; case .rejected: "Reject"; case .inProgress: "Start work"; case .completed: "Mark completed"; case .noShow: "Mark no-show"; default: "Cancel" }
    }
}

// MARK: - Inventory
struct InventoryView: View {
    @Environment(AuthService.self) private var auth
    @Environment(DataStore.self) private var store
    @State private var editing: InventoryItem?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.inventory) { item in
                    let f = Analytics.inventoryForecast(item)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(item.name).font(.headline); Spacer(); if item.isLow { Badge(text: "Low stock", color: .red) } }
                        ProgressView(value: Double(item.stock), total: Double(max(item.stock, item.minThreshold * 3, 1)))
                        Text("Stock \(item.stock) · min \(item.minThreshold) · forecast next month \(Int(f.demand.rounded()))").font(.caption)
                        if f.reorder > 0 { Label("Suggested reorder: \(f.reorder)", systemImage: "cart.badge.plus").font(.caption.bold()).foregroundStyle(.orange) }
                        HStack { Button("Use 1") { Task { await store.recordUsage(item, qty: 1) } }.buttonStyle(.bordered)
                                 Button("Edit") { editing = item }.buttonStyle(.bordered) }
                    }
                    .accessibilityElement(children: .combine)
                    .swipeActions { Button("Delete", role: .destructive) { Task { await store.delete(item) } } }
                }
            }
            .overlay { if store.inventory.isEmpty { ContentUnavailableView("No parts", systemImage: "shippingbox", description: Text("Tap + or load demo data in Settings.")) } }
            .navigationTitle("Inventory")
            .toolbar { Button { editing = InventoryItem(garageId: auth.user?.id ?? "", name: "", stock: 0, minThreshold: 5, unitCost: 0, monthlyUsage: [0]) } label: { Image(systemName: "plus") }.accessibilityLabel("Add part") }
            .sheet(item: $editing) { InventoryEditor(item: $0) }
        }
    }
}

struct InventoryEditor: View {
    @State var item: InventoryItem
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("Part name", text: $item.name)
                Stepper("Stock: \(item.stock)", value: $item.stock, in: 0...10_000)
                Stepper("Minimum threshold: \(item.minThreshold)", value: $item.minThreshold, in: 0...1_000)
                TextField("Unit cost", value: $item.unitCost, format: .number).keyboardType(.decimalPad)
            }
            .navigationTitle("Part").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await store.save(item); dismiss() } }.disabled(item.name.isEmpty) }
            }
        }
    }
}

// MARK: - ML insights
struct InsightsView: View {
    @Environment(DataStore.self) private var store
    var body: some View {
        let rev = Analytics.revenueForecast(store.appointments, months: 3)
        let bookings = Analytics.bookingsForecast(store.appointments, months: 3)
        let anomalies = Analytics.anomalies(store.appointments)
        let atRisk = store.appointments.filter { $0.status == .pending || $0.status == .confirmed }
            .filter { MLService.shared.noShowRisk(for: $0, history: store.appointments) > 0.4 }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        Text("Revenue forecast").font(.headline)
                        if rev.history.isEmpty { Text("Not enough completed jobs yet. Load demo data in Settings.").font(.footnote) }
                        else {
                            Chart {
                                ForEach(rev.history.suffix(12), id: \.month) { BarMark(x: .value("Month", $0.month, unit: .month), y: .value("Revenue", $0.value)).foregroundStyle(.blue) }
                                ForEach(rev.forecast, id: \.month) { BarMark(x: .value("Month", $0.month, unit: .month), y: .value("Revenue", $0.value)).foregroundStyle(.orange) }
                            }.frame(height: 200).accessibilityLabel("Revenue history in blue and three month forecast in orange")
                            Text("Next 3 months (orange): \(rev.forecast.reduce(0) { $0 + $1.value }.money)").font(.footnote)
                        }
                    }
                    Card {
                        Text("Workload forecast (bookings)").font(.headline)
                        Chart(bookings, id: \.month) { LineMark(x: .value("Month", $0.month, unit: .month), y: .value("Jobs", $0.value)); PointMark(x: .value("Month", $0.month, unit: .month), y: .value("Jobs", $0.value)) }
                            .frame(height: 140)
                        if let m = bookings.map(\.value).max() { Text("Peak expected: ~\(Int(m)) jobs/month").font(.footnote) }
                    }
                    Card {
                        Text("Staff workload (active jobs)").font(.headline)
                        let active = store.appointments.filter { $0.status == .confirmed || $0.status == .inProgress }
                        Chart(store.staff) { s in BarMark(x: .value("Jobs", active.filter { $0.assignedStaffId == s.id }.count), y: .value("Staff", s.name)) }.frame(height: CGFloat(max(60, store.staff.count * 36)))
                    }
                    Card {
                        Text("High no-show risk (\(atRisk.count))").font(.headline)
                        ForEach(atRisk.prefix(5)) { Text("\($0.customerName) – \($0.date.formatted(date: .abbreviated, time: .shortened))").font(.subheadline) }
                        if atRisk.isEmpty { Text("None 🎉").font(.footnote) }
                    }
                    Card {
                        Text("Repair anomalies (\(anomalies.count))").font(.headline)
                        ForEach(anomalies.prefix(6)) { Label($0.reason, systemImage: "exclamationmark.magnifyingglass").font(.footnote).foregroundStyle(.orange) }
                        if anomalies.isEmpty { Text("No unusual patterns detected.").font(.footnote) }
                    }
                }.padding()
            }.navigationTitle("Insights")
        }
    }
}

// MARK: - Staff
struct StaffView: View {
    @Environment(AuthService.self) private var auth
    @Environment(DataStore.self) private var store
    @State private var name = ""
    var body: some View {
        NavigationStack {
            List {
                Section("Add employee") {
                    HStack { TextField("Name", text: $name)
                        Button("Add") { Task { await store.addStaff(name: name, garageId: auth.user?.id ?? ""); name = "" } }.disabled(name.isEmpty) }
                }
                Section("Team workload") {
                    ForEach(store.staff) { s in
                        let mine = store.appointments.filter { $0.assignedStaffId == s.id }
                        VStack(alignment: .leading) {
                            Text(s.name).font(.headline)
                            Text("Active: \(mine.filter { $0.status == .confirmed || $0.status == .inProgress }.count) · Completed: \(mine.filter { $0.status == .completed }.count)").font(.caption)
                        }.accessibilityElement(children: .combine)
                        .swipeActions { Button("Delete", role: .destructive) { Task { await store.delete(s) } } }
                    }
                }
            }.navigationTitle("Staff")
        }
    }
}
