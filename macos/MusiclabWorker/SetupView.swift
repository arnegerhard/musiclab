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
                    .disabled(working || email.isEmpty || password.count < 8)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    /// Exchanges the password for a token immediately, and keeps only the
    /// token. The password is never written anywhere.
    private func signIn() async {
        working = true
        error = nil
        defer { working = false }

        guard let url = URL(string: server.trimmingCharacters(in: .whitespaces))?
            .appendingPathComponent("api/auth/login")
        else {
            error = "That server address does not look right."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["email": email, "password": password]
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
            try WorkerProcess.save(configuration: .init(
                server: server.trimmingCharacters(in: .whitespaces), email: email
            ))
            onSignedIn()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
