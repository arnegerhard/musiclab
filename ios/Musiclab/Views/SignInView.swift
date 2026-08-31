import AuthenticationServices
import SwiftUI

/// Sign in, sign up, and password reset.
struct SignInView: View {
    @Environment(Account.self) private var account
    @Environment(StemsClient.self) private var client

    private enum Mode { case signIn, signUp }
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var showingReset = false

    var body: some View {
        @Bindable var account = account
        List {
            Section {
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { _ in
                    // The controller is driven from Account so the token can be
                    // exchanged with the server; this closure is not used.
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 46)
                .allowsHitTesting(false)
                .overlay {
                    Button("") { Task { await account.signInWithApple() } }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                Text("Apple never shares your password, and can hide your email.")
            }

            Section("Or use an email address") {
                if mode == .signUp {
                    TextField("Name (optional)", text: $name)
                        .textContentType(.name)
                }
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(mode == .signUp ? .newPassword : .password)

                Button {
                    Task {
                        if mode == .signIn {
                            await account.signIn(email: email, password: password)
                        } else {
                            await account.signUp(email: email, password: password,
                                                 name: name.isEmpty ? nil : name)
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        if account.isWorking { ProgressView() }
                        else { Text(mode == .signIn ? "Sign in" : "Create account") }
                        Spacer()
                    }
                }
                .disabled(!isComplete || account.isWorking)
            }

            if let error = account.error {
                Section { Text(error).foregroundStyle(.red).font(.callout) }
            }

            Section {
                Button(mode == .signIn ? "Create an account" : "I already have an account") {
                    withAnimation { mode = mode == .signIn ? .signUp : .signIn }
                    account.error = nil
                }
                .font(.callout)
                if mode == .signIn {
                    Button("Forgot password") { showingReset = true }
                        .font(.callout)
                }
            } footer: {
                if let host = client.baseURL?.host() {
                    Text("Signed in against \(host). Your songs are visible only to you.")
                }
            }
        }
        .navigationTitle("Musiclab")
        .sheet(isPresented: $showingReset) {
            PasswordResetView(initialEmail: email)
        }
    }

    private var isComplete: Bool {
        email.contains("@") && password.count >= 8
    }
}

/// Request a code by email, then set a new password with it.
struct PasswordResetView: View {
    let initialEmail: String

    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var code = ""
    @State private var newPassword = ""
    @State private var codeSent = false
    @State private var sending = false

    var body: some View {
        @Bindable var account = account
        NavigationStack {
            List {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(codeSent)
                } footer: {
                    Text(codeSent
                         ? "If that address has an account, a six-digit code is on its way. It expires in 15 minutes."
                         : "We will email you a six-digit code.")
                }

                if !codeSent {
                    Section {
                        Button {
                            Task {
                                sending = true
                                codeSent = await account.requestReset(email: email)
                                sending = false
                            }
                        } label: {
                            HStack {
                                Spacer()
                                if sending { ProgressView() } else { Text("Send code") }
                                Spacer()
                            }
                        }
                        .disabled(!email.contains("@") || sending)
                    }
                } else {
                    Section("New password") {
                        TextField("Six-digit code", text: $code)
                            .keyboardType(.numberPad)
                        SecureField("New password", text: $newPassword)
                            .textContentType(.newPassword)
                        Button("Set password") {
                            Task {
                                await account.confirmReset(email: email, code: code,
                                                           newPassword: newPassword)
                                if account.isSignedIn { dismiss() }
                            }
                        }
                        .disabled(code.count < 6 || newPassword.count < 8 || account.isWorking)
                    }
                }

                if let error = account.error {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle("Reset password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { if email.isEmpty { email = initialEmail } }
        }
    }
}
