import SwiftUI

/// Adopt a Mac on this network so it can do separation work for this account.
///
/// Both ends have to agree: this screen finds Macs that are offering
/// themselves, and the Mac asks its own person before accepting. The six
/// digits shown on both are how you know the two are talking to each other.
struct PairMacView: View {
    @Environment(StemsClient.self) private var client
    @Environment(\.dismiss) private var dismiss

    @State private var browser = WorkerBrowser()
    @State private var session: PairingSession?
    @State private var machines: [PairedMac] = []
    @State private var error: String?

    private let ticker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    struct PairedMac: Codable, Identifiable, Equatable {
        let id: String
        let label: String?
        let machine: String?
        let createdAt: Double
        let lastSeen: Double?

        enum CodingKeys: String, CodingKey {
            case id, label, machine
            case createdAt = "created_at"
            case lastSeen = "last_seen"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let session {
                    Section("Pairing with \(session.macName)") {
                        pairing(session)
                    }
                } else {
                    Section {
                        if browser.macs.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Looking for Macs…").foregroundStyle(.secondary)
                            }
                        }
                        ForEach(browser.macs) { mac in
                            Button {
                                start(with: mac)
                            } label: {
                                Label(mac.name, systemImage: "desktopcomputer")
                            }
                        }
                    } header: {
                        Text("Macs offering to help")
                    } footer: {
                        Text("Open Musiclab Worker on a Mac on this network. "
                             + "A Mac only appears here while it is unpaired, "
                             + "and it will ask before it accepts.")
                    }
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
            .navigationTitle("Macs")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            browser.start()
            await load()
        }
        .onDisappear {
            session?.cancel()
            browser.stop()
        }
        .onReceive(ticker) { _ in Task { await load() } }
    }

    @ViewBuilder
    private func pairing(_ session: PairingSession) -> some View {
        switch session.step {
        case .connecting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(.secondary)
            }
        case let .confirm(number):
            VStack(spacing: 10) {
                Text(number)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                Text("Pair only if \(session.macName) is showing these same six digits.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Cancel", role: .cancel) { stop() }
                    Spacer()
                    Button("Pair") { session.confirm() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        case let .waitingForMac(number):
            VStack(spacing: 8) {
                Text(number)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for \(session.macName) to allow it…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        case .handingOver:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Setting it up…").foregroundStyle(.secondary)
            }
        case .paired:
            Label("\(session.macName) is ready to work", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .task {
                    await load()
                    self.session = nil
                }
        case let .failed(reason):
            VStack(alignment: .leading, spacing: 8) {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout)
                Button("Try again") { stop() }
            }
        }
    }

    private func start(with mac: WorkerBrowser.Found) {
        error = nil
        session = PairingSession(mac: mac) {
            // The code is minted only once both ends have agreed, and it is
            // spent by the Mac within seconds.
            try await mintCode()
        }
    }

    private func stop() {
        session?.cancel()
        session = nil
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

    // MARK: - Requests

    private func mintCode() async throws -> (code: String, server: String) {
        guard let baseURL = client.baseURL else { throw StemsClient.ClientError.notConnected }
        var request = client.request(baseURL.appendingPathComponent("api/auth/pair"))
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = payload["code"] as? String
        else { throw StemsClient.ClientError.badResponse(0) }
        return (code, baseURL.absoluteString)
    }

    private func load() async {
        guard let url = client.baseURL?.appendingPathComponent("api/auth/pairings")
        else { return }
        do {
            let (data, _) = try await URLSession.shared.data(for: client.request(url))
            machines = (try? JSONDecoder().decode([PairedMac].self, from: data)) ?? []
            // Keep the browser's idea of "still offering" honest.
            browser.alreadyPaired = Set(machines.compactMap(\.machine))
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
