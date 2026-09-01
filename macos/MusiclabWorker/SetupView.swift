import SwiftUI

/// First run: which server, and a pairing code from the owner's app.
///
/// Deliberately not a sign-in. This Mac gets a credential of its own that can
/// claim work and hand it back and nothing else, so the account's password
/// never reaches it -- and an account that signed up with Apple, and therefore
/// has no password at all, can still put a Mac to work.
struct SetupView: View {
    var onSignedIn: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var server = "https://arnegerhard--musiclab-web.modal.run"
    @State private var code = ""
    @State private var label = Host.current().localizedName ?? "This Mac"
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair this Mac").font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("In Musiclab on your phone, open Settings and tap Pair a Mac. "
                 + "Type the code it shows here. This Mac will separate songs "
                 + "for that account and keep nothing once each one is sent back.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Server", text: $server)
                TextField("Pairing code", text: $code)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: code) { _, new in
                        // The code is shown grouped and upper case; accept it
                        // typed any way at all.
                        let cleaned = new.uppercased().filter { $0.isLetter || $0.isNumber }
                        code = cleaned.count > 4
                            ? String(cleaned.prefix(4)) + "-" + String(cleaned.dropFirst(4).prefix(4))
                            : cleaned
                    }
                TextField("This Mac's name", text: $label)
            }
            .formStyle(.grouped)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Pair") { Task { await connect() } }
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

    /// Trades the code for this machine's own token, and keeps only the token.
    private func connect() async {
        let address = server.trimmingCharacters(in: .whitespaces)
        let name = label.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else {
            error = "Enter the pairing code from the app."
            return
        }

        working = true
        error = nil
        defer { working = false }

        guard let url = URL(string: address)?
            .appendingPathComponent("api/auth/pair/claim")
        else {
            error = "That server address does not look right."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["code": code, "label": name]
        )
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard http.statusCode == 200, let token = payload?["token"] as? String else {
                error = (payload?["detail"] as? String)
                    ?? "That code was not accepted. Codes last ten minutes and work once."
                return
            }
            Keychain.write(token)
            try WorkerProcess.save(configuration: .init(server: address, label: name))
            onSignedIn()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
