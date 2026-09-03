import SwiftUI

struct RootView: View {
    @Environment(StemsClient.self) private var client
    @Environment(Account.self) private var account
    @Environment(JobQueue.self) private var queue
    @Environment(NowPlaying.self) private var nowPlaying
    @Environment(SpatialEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase
    @State private var checkedSavedServer = false
    @State private var showingWelcome = false

    var body: some View {
        Group {
            if !checkedSavedServer {
                // Checking a remembered address can take a few seconds when
                // it has gone away. An unexplained spinner reads as a hang.
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for your server…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .task { await validateSavedServer() }
            } else if client.baseURL == nil {
                NavigationStack { ConnectView() }
            } else if !account.isSignedIn {
                NavigationStack { SignInView() }
            } else {
                // The bar is a row inside each tab, above that tab's own
                // content and below nothing but the tab bar.
                //
                // Not a safe area inset: an inset on the TabView lands under
                // the tabs and hides them, and an inset on a NavigationStack
                // is only a request that a List inside it does not honour --
                // the Add screen's buttons stayed sliced in half underneath
                // the bar. A stack row is arithmetic rather than a request.
                TabView {
                    VStack(spacing: 0) {
                        NavigationStack { LibraryView() }
                        MiniPlayerBar()
                    }
                    .tabItem { Label("Library", systemImage: "square.stack.3d.up") }

                    VStack(spacing: 0) {
                        NavigationStack { QueueView() }
                        MiniPlayerBar()
                    }
                    .tabItem { Label("Queue", systemImage: "clock.arrow.circlepath") }
                    // Only when there is something to say. A zero badge is a
                    // permanent little alarm about nothing.
                    .badge(queue.count == 0 ? 0 : queue.count)

                    VStack(spacing: 0) {
                        NavigationStack { AddSongView() }
                        MiniPlayerBar()
                    }
                    .tabItem { Label("Add", systemImage: "plus.circle.fill") }
                }
                // A sheet rather than a cover: swiping it down is the whole
                // point, and that is what a sheet does for free.
                .sheet(isPresented: Bindable(nowPlaying).isExpanded) {
                    if let entry = nowPlaying.entry {
                        NavigationStack { PlayerView(entry: entry) }
                            .presentationDetents([.large])
                            .presentationDragIndicator(.visible)
                    }
                }
                .task {
                    queue.begin(with: client)
                    nowPlaying.wireRemoteCommands(engine: engine, client: client)
                }
                // The system keeps its own clock from the rate and the
                // elapsed time, so this only has to speak when something
                // actually changes.
                .onChange(of: nowPlaying.entry?.slug) { _, _ in
                    nowPlaying.publish(engine: engine, client: client)
                }
                .onChange(of: engine.isPlaying) { _, _ in
                    nowPlaying.publish(engine: engine, client: client)
                }
                .onChange(of: engine.loadedSlug) { _, _ in
                    nowPlaying.publish(engine: engine, client: client)
                }
            }
        }
        .sheet(isPresented: $showingWelcome) {
            WelcomeView(onDone: finishWelcome)
        }
        // Signing in is the moment the account exists; before it there is no
        // one to have welcomed.
        .onChange(of: account.user?.id) { _, id in considerWelcome(id) }
        .onChange(of: client.baseURL) { _, url in
            // Whatever server was just settled on, the stored session has not
            // been checked against it. Without this, falling back from a Mac
            // that has gone away lands on the sign-in screen holding a
            // perfectly good token.
            if url != nil, !client.token.isEmpty, !account.isSignedIn {
                Task { await account.restore() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the app is exactly when the network may have
            // changed underneath it -- a different Wi-Fi, a Mac that went to
            // sleep, a new DHCP address.
            if phase == .active, checkedSavedServer {
                Task { await validateSavedServer() }
            }
        }
    }

    /// Once per account, and only the first time. Everything that makes this
    /// app unusual -- that separating happens elsewhere, and that where is a
    /// choice -- is invisible from the library, and the Add screen offers the
    /// choice without ever explaining it.
    private func considerWelcome(_ id: String?) {
        guard let id, !UserDefaults.standard.bool(forKey: Self.welcomeKey(id))
        else { return }
        showingWelcome = true
    }

    private func finishWelcome() {
        if let id = account.user?.id {
            UserDefaults.standard.set(true, forKey: Self.welcomeKey(id))
        }
        showingWelcome = false
    }

    private static func welcomeKey(_ id: String) -> String { "welcomed-\(id)" }

    /// A remembered address is a guess, not a fact: the Mac may have moved,
    /// changed port, or shut down. Probe it, and if it is gone drop back to
    /// discovery so the usual local-then-cloud fallback can run.
    private func validateSavedServer() async {
        if let saved = client.baseURL,
           await client.probe(saved, timeout: ServerResolver.timeout(for: saved)) == false {
            client.baseURL = nil
        }
        // A stored session is a guess too: it may have expired or been revoked.
        await account.restore()
        checkedSavedServer = true
    }
}

/// Finds a server without being asked: the Mac when this build is being
/// developed against it, the deployed host otherwise or as a fallback.
struct ConnectView: View {
    @Environment(StemsClient.self) private var client
    @Environment(ServerDiscovery.self) private var discovery
    @State private var resolver = ServerResolver()
    @State private var manualHost = ""
    @State private var token = ""
    @State private var error: String?
    @State private var checking = false
    @State private var showingManual = false

    var body: some View {
        List {
            Section {
                if resolver.isResolving {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for your Mac…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        Task { await autoConnect() }
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                    }
                }
            } header: {
                Text("Server")
            } footer: {
                Text(explanation)
            }

            if !discovery.servers.isEmpty {
                Section("On this network") {
                    ForEach(discovery.servers) { server in
                        Button {
                            Task { await connect(to: server.url) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                Text(server.url.absoluteString)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if let message = error ?? resolver.lastError {
                Section { Text(message).foregroundStyle(.red).font(.callout) }
            }

            Section {
                Button("Enter an address") { showingManual = true }
                    .font(.callout)
            }
        }
        .navigationTitle("Musiclab")
        .sheet(isPresented: $showingManual) {
            manualSheet
        }
        .task { await autoConnect() }
    }

    private var explanation: String {
        let fallback = ServerResolver.cloudURL?.host() ?? "the deployed server"
        return "\(Distribution.current.label): the Mac on this network if it is "
            + "running, otherwise \(fallback)."
    }

    private var manualSheet: some View {
        NavigationStack {
            Form {
                Section("Address") {
                    TextField("192.168.1.10:8000", text: $manualHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section {
                    SecureField("Token (only if the server needs one)", text: $token)
                } footer: {
                    Text("A server exposed to the internet should be run with "
                         + "STEMS_TOKEN set. Leave this empty on a home network.")
                }
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingManual = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        showingManual = false
                        Task { await connectManually() }
                    }
                    .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { token = client.token }
        }
    }

    private func autoConnect() async {
        error = nil
        if let url = await resolver.resolve(using: client, discovery: discovery) {
            client.baseURL = url
        }
    }

    private func connectManually() async {
        if !token.isEmpty { client.token = token }
        var text = manualHost.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "http://\(text)" }
        guard let url = URL(string: text) else {
            error = "That does not look like an address."
            return
        }
        await connect(to: url)
    }

    private func connect(to url: URL) async {
        checking = true
        defer { checking = false }
        if await client.probe(url) {
            client.baseURL = url
            discovery.stop()
        } else {
            error = "No server answered at \(url.absoluteString)."
        }
    }
}
