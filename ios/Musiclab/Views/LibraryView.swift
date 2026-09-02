import SwiftUI

struct LibraryView: View {
    @Environment(StemsClient.self) private var client
    @Environment(Account.self) private var account
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SpatialEngine.self) private var engine
    @State private var entries: [LibraryEntry] = []
    @State private var error: String?
    @State private var loading = true
    /// Held rather than deleted on the spot: this cannot be undone, and the
    /// song costs ten minutes of a Mac to make again.
    @State private var confirming: LibraryEntry?

    /// Songs arrive without the phone asking: a Mac finishes one minutes after
    /// it was requested, possibly while this screen is not even on top. There
    /// is nothing to push that news, so look again now and then.
    private let ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

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
            .onDelete { offsets in
                confirming = offsets.first.map { entries[$0] }
            }
            if let error {
                VStack(alignment: .leading, spacing: 10) {
                    Text(error).foregroundStyle(.red).font(.callout)
                    Button("Find the server again") { client.baseURL = nil }
                        .font(.callout)
                }
            }
        }
        .navigationTitle("Library")
        .confirmationDialog(
            confirming.map { "Delete \($0.title)?" } ?? "",
            isPresented: Binding(get: { confirming != nil },
                                 set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { entry in
            Button("Delete song and stems", role: .destructive) {
                Task { await delete(entry) }
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { entry in
            Text("\(entry.stemCount) stems, here and on the server. "
                 + "Separating it again takes about as long as it did the first time.")
        }
        .navigationDestination(for: LibraryEntry.self) { PlayerView(entry: $0) }
        .toolbar {
            Menu {
                if let email = account.user?.email {
                    Text(email)
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
        // .task fires once for the life of the view. Coming back from the
        // player, or from the Add tab after a song was queued, does not
        // re-run it -- which is how a finished song stayed invisible until
        // the app was restarted.
        .onAppear { Task { await reload(quietly: true) } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload(quietly: true) } }
        }
        .onReceive(ticker) { _ in Task { await reload(quietly: true) } }
    }

    /// `quietly` for the automatic passes: a spinner every fifteen seconds,
    /// and an error banner for one dropped request, would be worse than the
    /// staleness this is fixing.
    private func reload(quietly: Bool = false) async {
        if !quietly { loading = true }
        defer { loading = false }
        do {
            entries = try await client.library()
            error = nil
        } catch {
            if !quietly { self.error = error.localizedDescription }
        }
    }

    private func delete(_ entry: LibraryEntry) async {
        confirming = nil
        // Playing the song that is being deleted: stop, or the engine holds
        // files that are no longer there.
        if engine.loadedSlug == entry.slug { engine.teardown() }
        do {
            try await client.delete(slug: entry.slug)
            withAnimation { entries.removeAll { $0.slug == entry.slug } }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
