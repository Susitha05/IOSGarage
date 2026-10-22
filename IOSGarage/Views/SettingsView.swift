import SwiftUI

struct SettingsView: View {
    @Environment(AuthService.self) private var auth
    @Environment(DataStore.self) private var store
    @AppStorage("faceIDEnabled") private var faceID = false
    @AppStorage("notifyBookings") private var notifyBookings = true
    @AppStorage("notifyMaintenance") private var notifyMaintenance = true
    @AppStorage("notifyTow") private var notifyTow = true
    @State private var name = "", phone = ""
    @State private var seeded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                    TextField("Phone", text: $phone).keyboardType(.phonePad)
                    LabeledContent("Email", value: auth.user?.email ?? "")
                    LabeledContent("Role", value: auth.user?.role.title ?? "")
                    Button("Save profile") { Task { await auth.updateProfile(name: name, phone: phone) } }
                }
                Section("Security") {
                    Toggle("Require \(BiometricService.biometryName)", isOn: Binding(get: { faceID }, set: { on in
                        if on { Task { if await BiometricService.authenticate(reason: "Enable app lock") { faceID = true } } } else { faceID = false } }))
                }
                Section("Notifications") {
                    Toggle("Booking updates", isOn: $notifyBookings)
                    Toggle("Maintenance reminders", isOn: $notifyMaintenance)
                    Toggle("Tow status", isOn: $notifyTow)
                }
                if auth.user?.role == .garageOwner, let u = auth.user {
                    Section("Developer") {
                        Button(seeded ? "Demo data loaded ✓" : "Load demo history (staff, parts, 2 years of jobs)") { seeded = true; Task { await store.seedDemoData(garage: u) } }.disabled(seeded)
                    }
                }
                Section { Button("Sign out", role: .destructive) { auth.signOut() } }
            }
            .navigationTitle("Settings")
            .onAppear { name = auth.user?.name ?? ""; phone = auth.user?.phone ?? "" }
        }
    }
}
