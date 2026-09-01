import SwiftUI
import UniformTypeIdentifiers

/// Hand a Mac permission to do separation work for this account.
///
/// The Mac never learns the password -- it trades this code for a credential
/// that may claim work and return it and nothing else. That also means an
/// account created with Sign in with Apple, which has no password to give,
/// can still put a Mac to work.
struct PairMacView: View {
    @Environment(StemsClient.self) private var client
    @Environment(\.dismiss) private var dismiss

    @State private var code: String?
    @State private var secondsLeft = 0
    @State private var machines: [PairedMac] = []
    @State private var error: String?
    @State private var working = false
    @State private var copied = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    struct PairedMac: Codable, Identifiable, Equatable {
        let id: String
        let label: String?
        let createdAt: Double
        let lastSeen: Double?

        enum CodingKeys: String, CodingKey {
            case id, label
            case createdAt = "created_at"
            case lastSeen = "last_seen"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let code {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(code)
                                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .center)
                            Button {
                                copyToClipboard(code)
                                copied = true
                            } label: {
                                Label(copied ? "Copied" : "Copy",
                                      systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity, alignment: .center)

                            Text(secondsLeft > 0
                                 ? "Type or paste this into Musiclab Worker on the Mac. Expires in \(secondsLeft / 60):\(String(format: "%02d", secondsLeft % 60))."
                                 : "Expired. Create another.")
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .padding(.vertical, 6)
                    }
                    Button(code == nil ? "Create a code" : "Create another code") {
                        Task { await mint() }
                    }
                    .disabled(working)
                } header: {
                    Text("Pair a Mac")
                } footer: {
                    Text("Open Musiclab Worker on the Mac, choose Pair, and type "
                         + "the code. Each code works once. The Mac never "
                         + "receives your password.")
                }

                Section("Paired Macs") {
                    if machines.isEmpty {
                        Text("None yet.").foregroundStyle(.secondary)
                    }
                    ForEach(machines) { machine in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(machine.label ?? "A Mac")
                            Text(describe(machine))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        Task { await revoke(offsets.map { machines[$0] }) }
                    }
                }

                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            .refreshable { await load() }
            .navigationTitle("Macs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
        .onReceive(ticker) { _ in
            guard secondsLeft > 0 else { return }
            secondsLeft -= 1
            // While a code is outstanding the Mac may pair at any moment, and
            // nothing pushes that back to the phone. Poll only during the
            // window when something is actually expected to happen.
            if secondsLeft % 3 == 0 { Task { await load() } }
        }
    }

    private func describe(_ machine: PairedMac) -> String {
        guard let seen = machine.lastSeen else { return "Never checked in" }
        let ago = Date.now.timeIntervalSince1970 - seen
        if ago < 90 { return "Working now" }
        let formatter = RelativeDateTimeFormatter()
        return "Last seen " + formatter.localizedString(
            for: Date(timeIntervalSince1970: seen), relativeTo: .now
        )
    }

    /// Put the code on the clipboard in a way that can reach the Mac.
    ///
    /// Plain `.string =` is eligible for Universal Clipboard already, but says
    /// nothing about intent; setting localOnly explicitly does. The expiry
    /// matches the code's own ten minutes -- a spent code left sitting on
    /// every signed-in device is worth nothing to anyone.
    private func copyToClipboard(_ text: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [
                .localOnly: false,
                .expirationDate: Date().addingTimeInterval(TimeInterval(max(60, secondsLeft))),
            ]
        )
    }

    // MARK: - Requests

    private func load() async {
        guard let url = client.baseURL?.appendingPathComponent("api/auth/pairings")
        else { return }
        do {
            let (data, _) = try await URLSession.shared.data(for: client.request(url))
            let found = (try? JSONDecoder().decode([PairedMac].self, from: data)) ?? []
            // A code is good for one machine, so a new arrival means this one
            // has been spent. Clearing it says so without an alert.
            if found.count > machines.count, code != nil {
                code = nil
                secondsLeft = 0
            }
            machines = found
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func mint() async {
        guard let url = client.baseURL?.appendingPathComponent("api/auth/pair") else { return }
        working = true
        error = nil
        defer { working = false }

        var request = client.request(url)
        request.httpMethod = "POST"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let issued = payload["code"] as? String
            else {
                error = "Could not create a code."
                return
            }
            code = issued
            copied = false
            secondsLeft = Int(payload["expires_in"] as? Double ?? 600)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func revoke(_ targets: [PairedMac]) async {
        for machine in targets {
            guard let url = client.baseURL?
                .appendingPathComponent("api/auth/pairings/\(machine.id)") else { continue }
            var request = client.request(url)
            request.httpMethod = "DELETE"
            _ = try? await URLSession.shared.data(for: request)
        }
        await load()
    }
}
