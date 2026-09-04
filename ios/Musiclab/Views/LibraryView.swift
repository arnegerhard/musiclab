import SwiftUI

struct LibraryView: View {
    @Environment(StemsClient.self) private var client
    @Environment(Account.self) private var account
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SpatialEngine.self) private var engine
    @Environment(NowPlaying.self) private var nowPlaying
    @State private var entries: [LibraryEntry] = []
    @State private var error: String?
    @State private var loading = true
    /// Held rather than deleted on the spot: this cannot be undone, and the
    /// song costs ten minutes of a Mac to make again.
    @State private var confirming: LibraryEntry?
    @State private var closingAccount = false

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
                Button {
                    nowPlaying.open(entry)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title).lineLimit(2)
                            Text("\(entry.stemCount) stems · \(format(entry.duration))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if engine.loadedSlug == entry.slug {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption).foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                confirming = offsets.first.map { entries[$0] }
            }
            if let error {
                // There is one server and it is not going anywhere, so the
                // only useful offer is to ask it again.
                VStack(alignment: .leading, spacing: 10) {
                    Text(error).foregroundStyle(.red).font(.callout)
                    Button("Try again") { Task { await reload() } }
                        .font(.callout)
                }
            }
        }
        .navigationTitle("Library")
        .confirmationDialog(
            "Delete \(account.user?.email ?? "this account")?",
            isPresented: $closingAccount,
            titleVisibility: .visible
        ) {
            Button("Delete account and every song", role: .destructive) {
                Task { await closeAccount() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("""
                This cannot be undone. Every song separated for this account is \
                deleted from the server and from this phone, and any paired Mac \
                stops working for it.
                """)
        }
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
            Text("""
                \(entry.stemCount) stems, here and on the server. Separating it \
                again takes about as long as it did the first time.
                """)
        }
        .toolbar {
            Menu {
                if let email = account.user?.email {
                    Text(email)
                }
                // Signed out is the only way to not be signed in. There used
                // to be a second, "Disconnect", which forgot the server as
                // well -- a distinction that meant something when the server
                // might be a Mac on this network, and nothing since.
                Button("Sign out", systemImage: "person.crop.circle.badge.xmark") {
                    Task { await account.signOut() }
                }
                Divider()
                Button("Delete account", systemImage: "trash", role: .destructive) {
                    closingAccount = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let host = client.baseURL.host() {
                Text("\(Distribution.current.label) · \(host)")
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

    private func closeAccount() async {
        // Whatever is playing belongs to the account that is going.
        engine.teardown()
        nowPlaying.clear()
        if await account.deleteAccount() {
            entries = []
        } else {
            error = "Could not delete the account. Try again in a moment."
        }
    }

    private func delete(_ entry: LibraryEntry) async {
        confirming = nil
        // Playing the song that is being deleted: stop, or the engine holds
        // files that are no longer there.
        if engine.loadedSlug == entry.slug {
            engine.teardown()
            nowPlaying.clear()
        }
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
