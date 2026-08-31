import SwiftUI

/// The "+" tab: paste a link, or pick from a connected service.
struct AddSongView: View {
    @Environment(StemsClient.self) private var client
    @Environment(AppleMusicSource.self) private var apple
    @Environment(SpotifySource.self) private var spotify

    @State private var link = ""
    @State private var batchID: String?
    @State private var error: String?
    @State private var submitting = false
    @State private var showingSpotifySetup = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    TextField("youtube.com/watch?v=…", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit { Task { await separateLink() } }
                    if link.isEmpty {
                        Button("Paste") {
                            link = UIPasteboard.general.string?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        }
                        .font(.callout)
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            link = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    Task { await separateLink() }
                } label: {
                    HStack {
                        Spacer()
                        if submitting { ProgressView() } else { Text("Separate") }
                        Spacer()
                    }
                }
                .disabled(!looksLikeLink || submitting)
            } header: {
                Text("Paste a link")
            } footer: {
                Text("Any link yt-dlp understands, not only YouTube.")
            }

            Section("From your music") {
                appleRow
                spotifyRow
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.callout) }
            }
        }
        .navigationTitle("Add a song")
        .navigationDestination(item: $batchID) { BatchView(batchID: $0) }
        .navigationDestination(for: MusicSource.self) { source in
            MusicBrowserView(source: source)
        }
        .sheet(isPresented: $showingSpotifySetup) { SpotifySetupView(spotify: spotify) }
        .task { if apple.isAuthorised { apple.load() } }
    }

    @ViewBuilder private var appleRow: some View {
        if apple.isAuthorised {
            NavigationLink(value: MusicSource.appleMusic) {
                Label("Apple Music", systemImage: "music.note")
            }
        } else {
            Button {
                Task { await apple.requestAccess() }
            } label: {
                Label("Connect Apple Music", systemImage: "music.note")
            }
        }
    }

    @ViewBuilder private var spotifyRow: some View {
        if spotify.isConnected {
            NavigationLink(value: MusicSource.spotify) {
                Label("Spotify", systemImage: "waveform")
            }
        } else {
            Button {
                if spotify.clientID.isEmpty { showingSpotifySetup = true }
                else { Task { await spotify.connect() } }
            } label: {
                Label("Connect Spotify", systemImage: "waveform")
            }
        }
    }

    private var looksLikeLink: Bool {
        let text = link.trimmingCharacters(in: .whitespaces)
        return text.contains(".") && !text.contains(" ")
    }

    private func separateLink() async {
        submitting = true
        error = nil
        defer { submitting = false }
        do {
            let job = try await client.separate(link: link.trimmingCharacters(in: .whitespaces))
            link = ""
            batchID = job
        } catch {
            self.error = error.localizedDescription
        }
    }
}
