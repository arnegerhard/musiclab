import SwiftUI

struct LibraryView: View {
    @Environment(StemsClient.self) private var client
    @Environment(Account.self) private var account
    @State private var entries: [LibraryEntry] = []
    @State private var error: String?
    @State private var loading = true
    @State private var pairing = false

    var body: some View {
        List {
            if loading {
                HStack(spacing: 12) { ProgressView(); Text("Loading…") }
            }
            ForEach(entries) { entry in
                NavigationLink(value: entry) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title).lineLimit(2)
                        Text("\(entry.stemCount) stems · \(format(entry.duration))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error {
                VStack(alignment: .leading, spacing: 10) {
                    Text(error).foregroundStyle(.red).font(.callout)
                    Button("Find the server again") { client.baseURL = nil }
                        .font(.callout)
                }
            }
        }
        .sheet(isPresented: $pairing) { PairMacView() }
        .navigationTitle("Library")
        .navigationDestination(for: LibraryEntry.self) { PlayerView(entry: $0) }
        .toolbar {
            Menu {
                if let email = account.user?.email {
                    Text(email)
                }
                Button("Pair a Mac", systemImage: "desktopcomputer") {
                    pairing = true
                }
                Button("Sign out", systemImage: "person.crop.circle.badge.xmark") {
                    Task { await account.signOut() }
                }
                Button("Disconnect", systemImage: "xmark.circle") {
                    Task { await account.signOut() }
                    client.baseURL = nil
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let url = client.baseURL, let host = url.host() {
                // Port included: with a local and a deployed server both in
                // play, the host alone does not say which one answered.
                let port = url.port.map { ":\($0)" } ?? ""
                Text("\(Distribution.current.label) · \(host)\(port)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
        }
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            entries = try await client.library()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
