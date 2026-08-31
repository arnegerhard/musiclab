import SwiftUI

struct RootView: View {
    @Environment(StemsClient.self) private var client
    @Environment(Account.self) private var account
    @Environment(\.scenePhase) private var scenePhase
    @State private var checkedSavedServer = false

    var body: some View {
        Group {
            if !checkedSavedServer {
                ProgressView().task { await validateSavedServer() }
            } else if client.baseURL == nil {
                NavigationStack { ConnectView() }
            } else if !account.isSignedIn {
                NavigationStack { SignInView() }
            } else {
                TabView {
                    NavigationStack { LibraryView() }
                        .tabItem { Label("Library", systemImage: "square.stack.3d.up") }
                    NavigationStack { AddSongView() }
                        .tabItem { Label("Add", systemImage: "plus.circle.fill") }
                }
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

    /// A remembered address is a guess, not a fact: the Mac may have moved,
    /// changed port, or shut down. Probe it, and if it is gone drop back to
    /// discovery so the usual local-then-cloud fallback can run.
    private func validateSavedServer() async {
        if let saved = client.baseURL, await client.probe(saved, timeout: 25) == false {
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
