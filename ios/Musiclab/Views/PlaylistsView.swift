import SwiftUI

/// Browse playlists from Apple Music and Spotify, and pick songs to separate.
///
/// Neither service exposes audio, so these are choosing surfaces only: what
/// gets separated is whatever the Mac matches each track to.
struct PlaylistsView: View {
    @Environment(StemsClient.self) private var client
    @State private var apple = AppleMusicSource()
    @State private var spotify = SpotifySource()
    @State private var source: MusicSource = .appleMusic
    @State private var showingSpotifySetup = false

    var body: some View {
        List {
            Picker("Source", selection: $source) {
                ForEach(MusicSource.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            switch source {
            case .appleMusic: appleSection
            case .spotify: spotifySection
            }

            Section {
                Text("Playlists choose the song. The audio is found separately — "
                     + "neither Apple Music nor Spotify lets an app read their audio.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Playlists")
        .navigationDestination(for: PlaylistSummary.self) { playlist in
            PlaylistDetailView(playlist: playlist, apple: apple, spotify: spotify)
        }
        .sheet(isPresented: $showingSpotifySetup) {
            SpotifySetupView(spotify: spotify)
        }
        .task {
            if apple.status == .authorized { apple.load() }
        }
    }

    @ViewBuilder private var appleSection: some View {
        if apple.status != .authorized {
            Section {
                Button {
                    Task { await apple.requestAccess() }
                } label: {
                    Label("Allow access to your music", systemImage: "music.note")
                }
                if let error = apple.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        } else if apple.playlists.isEmpty {
            Text("No playlists in your library.")
                .foregroundStyle(.secondary)
        } else {
            Section("\(apple.playlists.count) playlists") {
                ForEach(apple.playlists) { row(for: $0) }
            }
        }
    }

    @ViewBuilder private var spotifySection: some View {
        if !spotify.isConnected {
            Section {
                Button {
                    if spotify.clientID.isEmpty { showingSpotifySetup = true }
                    else { Task { await spotify.connect() } }
                } label: {
                    Label("Connect Spotify", systemImage: "waveform")
                }
                if let error = spotify.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Needs a client ID from your own Spotify developer dashboard.")
            }
        } else if spotify.playlists.isEmpty {
            Section { HStack { ProgressView(); Text("Loading…") } }
                .task { await spotify.loadPlaylists() }
        } else {
            Section("\(spotify.playlists.count) playlists") {
                ForEach(spotify.playlists) { row(for: $0) }
            }
            Section {
                Button("Disconnect Spotify", role: .destructive) { spotify.disconnect() }
                    .font(.callout)
            }
        }
    }

    private func row(for playlist: PlaylistSummary) -> some View {
        NavigationLink(value: playlist) {
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).lineLimit(1)
                Text("\(playlist.trackCount) songs")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SpotifySetupView: View {
    let spotify: SpotifySource
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Client ID", text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Spotify client ID")
                } footer: {
                    Text("""
                    Create an app at developer.spotify.com/dashboard, then add \
                    this exact redirect URI to it:

                    \(SpotifySource.redirectURI)

                    Spotify never exposes audio, so this only reads your \
                    playlist names and track titles.
                    """)
                }
            }
            .navigationTitle("Connect Spotify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        spotify.clientID = clientID.trimmingCharacters(in: .whitespaces)
                        dismiss()
                        Task { await spotify.connect() }
                    }
                    .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { clientID = spotify.clientID }
        }
    }
}
