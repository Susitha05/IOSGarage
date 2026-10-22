import SwiftUI

struct RootView: View {
    @Environment(AuthService.self) private var auth
    @Environment(DataStore.self) private var store
    @Environment(\.scenePhase) private var phase
    @AppStorage("faceIDEnabled") private var faceID = false
    @State private var locked = true

    var body: some View {
        Group {
            if auth.isLoading { ProgressView("Loading…") }
            else if let user = auth.user {
                if faceID && locked { LockView(locked: $locked) }
                else {
                    switch user.role {
                    case .customer: CustomerTabs()
                    case .garageOwner: GarageTabs()
                    case .towDriver: DriverTabs()
                    }
                }
            } else { AuthView() }
        }
        .task(id: auth.user?.id) {
            if let u = auth.user { store.start(for: u); await NotificationService.shared.requestPermission() }
            else { store.stop() }
        }
        .onChange(of: phase) { _, new in if new == .background { locked = true } }
    }
}

struct LockView: View {
    @Binding var locked: Bool
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "faceid").font(.system(size: 72)).accessibilityHidden(true)
            Text("Garage is locked").font(.title2.bold())
            Button("Unlock with \(BiometricService.biometryName)") { Task { await unlock() } }
                .buttonStyle(PrimaryButtonStyle()).padding(.horizontal, 40)
        }
        .task { await unlock() }
    }
    private func unlock() async { if await BiometricService.authenticate() { locked = false } }
}
