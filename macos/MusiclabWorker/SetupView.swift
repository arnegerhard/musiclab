import SwiftUI

/// First run: which server, and who to sign in as.
struct SetupView: View {
    var onSignedIn: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var server = "https://arnegerhard--musiclab-web.modal.run"
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign this Mac in").font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("It will separate songs for the account you sign in as, and "
                 + "keep nothing once each one is sent back.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Server", text: $server)
                TextField("Email", text: $email)
                SecureField("Password", text: $password)
            }
            .formStyle(.grouped)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Sign in") { Task { await signIn() } }
                    .buttonStyle(.borderedProminent)
                    // Only disabled while a request is in flight. A greyed-out
                    // button that will not say why is worse than one that
                    // presses and explains.
                    .disabled(working)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onDisappear {
            // Back to an accessory once the window is gone, so the app leaves
            // no Dock icon behind.
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    /// Exchanges the password for a token immediately, and keeps only the
    /// token. The password is never written anywhere.
    private func signIn() async {
        let address = server.trimmingCharacters(in: .whitespaces)
        let account = email.trimmingCharacters(in: .whitespaces)
        guard !account.isEmpty, !password.isEmpty else {
            error = "Fill in the email and password."
            return
        }

        working = true
        error = nil
        defer { working = false }

        guard let url = URL(string: address)?.appendingPathComponent("api/auth/login")
        else {
            error = "That server address does not look right."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["email": account, "password": password]
        )
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard http.statusCode == 200, let token = payload?["token"] as? String else {
                error = (payload?["detail"] as? String) ?? "Could not sign in."
                return
            }
            Keychain.write(token)
            try WorkerProcess.save(configuration: .init(server: address, email: account))
            onSignedIn()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
