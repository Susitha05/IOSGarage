import SwiftUI
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import GoogleSignIn
import LocalAuthentication

@Observable @MainActor
final class AuthService {
    var user: AppUser?
    var isLoading = true
    var errorMessage: String?

    private var handle: AuthStateDidChangeListenerHandle?
    private var pendingProfile: (name: String, role: UserRole, phone: String)?
    private var db: Firestore { Firestore.firestore() }

    func start() {
        guard handle == nil else { return }
        handle = Auth.auth().addStateDidChangeListener { [weak self] _, fbUser in
            Task { @MainActor in await self?.loadProfile(fbUser) }
        }
    }

    private func loadProfile(_ fbUser: FirebaseAuth.User?) async {
        defer { isLoading = false }
        guard let fbUser else { user = nil; return }
        let ref = db.collection("users").document(fbUser.uid)
        do {
            let snap = try await ref.getDocument()
            if snap.exists, let u = try? snap.data(as: AppUser.self) { user = u; return }
            let p = pendingProfile
            let new = AppUser(name: p?.name ?? fbUser.displayName ?? "Customer",
                              email: fbUser.email ?? "", role: p?.role ?? .customer, phone: p?.phone)
            try ref.setData(from: new)
            pendingProfile = nil
            user = try await ref.getDocument().data(as: AppUser.self)
        } catch { errorMessage = error.localizedDescription }
    }

    func signIn(email: String, password: String) async {
        errorMessage = nil
        do { try await Auth.auth().signIn(withEmail: email, password: password) }
        catch { errorMessage = error.localizedDescription }
    }

    func signUp(name: String, email: String, password: String, role: UserRole, phone: String) async {
        errorMessage = nil
        pendingProfile = (name, role, phone)
        do { try await Auth.auth().createUser(withEmail: email, password: password) }
        catch { pendingProfile = nil; errorMessage = error.localizedDescription }
    }

    func signInWithGoogle() async {
        errorMessage = nil
        do {
            guard let clientID = FirebaseApp.app()?.options.clientID,
                  let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let root = scene.windows.first?.rootViewController else { return }
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: root)
            guard let idToken = result.user.idToken?.tokenString else { return }
            let cred = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
            try await Auth.auth().signIn(with: cred)
        } catch { errorMessage = error.localizedDescription }
    }

    func resetPassword(email: String) async {
        do { try await Auth.auth().sendPasswordReset(withEmail: email) }
        catch { errorMessage = error.localizedDescription }
    }

    func updateProfile(name: String, phone: String) async {
        guard let id = user?.id else { return }
        try? await db.collection("users").document(id).updateData(["name": name, "phone": phone])
        user?.name = name; user?.phone = phone
    }

    func signOut() { try? Auth.auth().signOut(); GIDSignIn.sharedInstance.signOut(); user = nil }
}

// MARK: - Face ID
enum BiometricService {
    static var biometryName: String {
        let c = LAContext(); _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return c.biometryType == .touchID ? "Touch ID" : "Face ID"
    }
    static func authenticate(reason: String = "Unlock your garage account") async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
