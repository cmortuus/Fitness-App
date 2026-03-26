import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: AuthService
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var loading = false
    @State private var showSignup = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Logo
                VStack(spacing: 8) {
                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.blue)
                    Text("GymTracker")
                        .font(.largeTitle.bold())
                    Text("Sign in to your account")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Form
                VStack(spacing: 16) {
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()

                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)

                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button(action: login) {
                        if loading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Sign In")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(username.isEmpty || password.isEmpty || loading)
                }
                .padding(.horizontal)

                Button("Don't have an account? Sign up") {
                    showSignup = true
                }
                .font(.footnote)

                Spacer()
            }
            .navigationDestination(isPresented: $showSignup) {
                SignupView()
            }
        }
    }

    private func login() {
        loading = true
        error = nil
        Task {
            do {
                try await auth.login(username: username, password: password)
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

struct SignupView: View {
    @EnvironmentObject var auth: AuthService
    @Environment(\.dismiss) var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Text("Create Account")
                    .font(.largeTitle.bold())
                Text("Start tracking your workouts")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 16) {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.newPassword)

                SecureField("Confirm Password", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.newPassword)

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button(action: signup) {
                    if loading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Sign Up")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(username.isEmpty || password.isEmpty || password != confirmPassword || loading)
            }
            .padding(.horizontal)

            Button("Already have an account? Sign in") {
                dismiss()
            }
            .font(.footnote)

            Spacer()
        }
        .navigationBarBackButtonHidden()
    }

    private func signup() {
        guard password == confirmPassword else {
            error = "Passwords don't match"
            return
        }
        loading = true
        error = nil
        Task {
            do {
                try await auth.signup(username: username, password: password)
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
