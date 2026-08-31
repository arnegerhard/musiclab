import SwiftUI

struct RootView: View {
    @Environment(StemsClient.self) private var client

    var body: some View {
        if client.baseURL == nil {
            NavigationStack { ConnectView() }
        } else {
            TabView {
                NavigationStack { LibraryView() }
                    .tabItem { Label("Library", systemImage: "square.stack.3d.up") }
                NavigationStack { PlaylistsView() }
                    .tabItem { Label("Playlists", systemImage: "music.note.list") }
            }
        }
    }
}

/// First run: find the Mac, or let someone type its address.
struct ConnectView: View {
    @Environment(StemsClient.self) private var client
    @Environment(ServerDiscovery.self) private var discovery
    @State private var manualHost = ""
    @State private var error: String?
    @State private var checking = false

    var body: some View {
        List {
            Section {
                if discovery.servers.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for your Mac…")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(discovery.servers) { server in
                    Button {
                        Task { await connect(to: server.url) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).font(.body)
                            Text(server.url.absoluteString)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("On this network")
            } footer: {
                Text("Run `python -m stems.cli --serve` on the Mac holding your stems.")
            }

            Section("By address") {
                HStack {
                    TextField("192.168.1.10:8000", text: $manualHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Connect") {
                        Task { await connectManually() }
                    }
                    .disabled(manualHost.isEmpty || checking)
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.callout) }
            }
        }
        .navigationTitle("Musiclab")
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private func connectManually() async {
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
            error = "No stems server answered at \(url.absoluteString)."
        }
    }
}
