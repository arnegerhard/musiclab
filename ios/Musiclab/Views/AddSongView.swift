import SwiftUI

/// The "+" tab: paste a link, or pick from a connected service.
struct AddSongView: View {
    @Environment(StemsClient.self) private var client
    @Environment(AppleMusicSource.self) private var apple
    @Environment(SpotifySource.self) private var spotify
    @Environment(JobQueue.self) private var queue

    @State private var link = ""
    @State private var added: String?
    @State private var error: String?
    @State private var submitting = false
    @State private var showingSpotifySetup = false
    @State private var phase = ""
    @State private var fraction: Double = 0

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    TextField("youtube.com/watch?v=…", text: $link)
                        .onChange(of: link) { _, _ in added = nil }
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
                        if submitting {
                            VStack(spacing: 4) {
                                ProgressView(value: fraction)
                                    .progressViewStyle(.linear).frame(maxWidth: 200)
                                Text(phase).font(.caption2).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Separate")
                        }
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

            if let added {
                Section {
                    Label(added, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.callout) }
            }
        }
        .navigationTitle("Add a song")
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

    /// Hand the song over and stay here.
    ///
    /// This screen used to push into the progress view, which made adding two
    /// songs in a row a matter of navigating back out of something. The queue
    /// is a tab of its own now, so this can go back to being the place where
    /// songs are added.
    private func separateLink() async {
        submitting = true
        error = nil
        defer { submitting = false; phase = ""; fraction = 0 }
        do {
            phase = "Sending to the server"
            let title = link.trimmingCharacters(in: .whitespaces)
            _ = try await client.separate(link: title)
            link = ""
            added = "Added to the queue"
            await queue.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
