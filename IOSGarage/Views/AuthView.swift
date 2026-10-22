import SwiftUI

struct AuthView: View {
    @Environment(AuthService.self) private var auth
    @State private var isSignUp = false
    @State private var name = "", email = "", password = "", phone = ""
    @State private var role: UserRole = .customer
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "car.side.fill").font(.system(size: 56)).foregroundStyle(.tint).accessibilityHidden(true)
                        Text("Smart Garage").font(.largeTitle.bold())
                        Text("Vehicle care, garage ops & roadside help").font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
                Section {
                    Picker("Mode", selection: $isSignUp) { Text("Sign in").tag(false); Text("Create account").tag(true) }
                        .pickerStyle(.segmented)
                    if isSignUp {
                        TextField("Full name", text: $name).textContentType(.name)
                        TextField("Phone", text: $phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                        Picker("I am a", selection: $role) { ForEach(UserRole.allCases) { Text($0.title).tag($0) } }
                    }
                    TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    SecureField("Password", text: $password).textContentType(isSignUp ? .newPassword : .password)
                }
                if let e = auth.errorMessage { Section { Text(e).foregroundStyle(.red).font(.footnote) } }
                Section {
                    Button(isSignUp ? "Create account" : "Sign in") { Task { await submit() } }
                        .buttonStyle(PrimaryButtonStyle()).disabled(busy || email.isEmpty || password.count < 6 || (isSignUp && name.isEmpty))
                        .listRowInsets(.init()).listRowBackground(Color.clear)
                    Button { Task { await auth.signInWithGoogle() } } label: { Label("Continue with Google", systemImage: "g.circle.fill").frame(maxWidth: .infinity, minHeight: 44) }
                    if !isSignUp { Button("Forgot password?") { Task { await auth.resetPassword(email: email) } }.font(.footnote) }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    private func submit() async {
        busy = true; defer { busy = false }
        if isSignUp { await auth.signUp(name: name, email: email, password: password, role: role, phone: phone) }
        else { await auth.signIn(email: email, password: password) }
    }
}
