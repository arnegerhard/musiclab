import SwiftUI
import UniformTypeIdentifiers

/// The "+" tab: paste a link, or pick from a connected service.
struct AddSongView: View {
    @Environment(StemsClient.self) private var client
    @Environment(AppleMusicSource.self) private var apple
    @Environment(SpotifySource.self) private var spotify
    @Environment(JobQueue.self) private var queue

    @State private var link = ""
    @State private var added: String?
    @State private var picking = false
    @State private var uploading: Double?
    /// Whether this account has a Mac at all. Without one, only the cloud can
    /// do anything -- and only with a file, since a link still has to be
    /// fetched from somewhere YouTube will answer.
    @State private var hasMac = false
    @AppStorage("separateOn") private var destination = "mac"
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
                if submitting {
                    VStack(spacing: 4) {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear).frame(maxWidth: 200)
                        Text(phase).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Menu {
                        Button {
                            destination = "mac"
                            Task { await separateLink() }
                        } label: {
                            Label("Separate on a Mac", systemImage: "desktopcomputer")
                        }
                        .disabled(!hasMac)

                        Button {
                            destination = "cloud"
                            Task { await separateLink() }
                        } label: {
                            Label("Separate in the cloud ($)", systemImage: "bolt")
                        }
                        // A link has to be downloaded by a Mac either way:
                        // YouTube does not answer the deployment.
                        .disabled(!hasMac)
                    } label: {
                        HStack {
                            Spacer()
                            Text("Separate").fontWeight(.medium)
                            Spacer()
                        }
                    }
                    .disabled(!looksLikeLink)
                }
            } header: {
                Text("Paste a link")
            } footer: {
                Text("Any link yt-dlp understands, not only YouTube.")
            }

            Section {
                if let fraction = uploading {
                    VStack(spacing: 4) {
                        ProgressView(value: fraction).progressViewStyle(.linear)
                        Text("Uploading…").font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Menu {
                        Button {
                            destination = "cloud"
                            picking = true
                        } label: {
                            Label("Separate in the cloud ($)", systemImage: "bolt")
                        }
                        Button {
                            destination = "mac"
                            picking = true
                        } label: {
                            Label("Separate on a Mac", systemImage: "desktopcomputer")
                        }
                        .disabled(!hasMac)
                    } label: {
                        Label("Choose an audio file", systemImage: "waveform.badge.plus")
                    }
                }
            } header: {
                Text("Or a file you already have")
            } footer: {
                Text(hasMac
                     ? "MP3, M4A, FLAC, WAV, OGG — whatever it is, it gets "
                       + "converted. A file needs no Mac if the cloud does the work."
                     : "MP3, M4A, FLAC, WAV, OGG. This is the only way to "
                       + "separate anything until a Mac is paired: a link has to "
                       + "be downloaded by one.")
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
        .fileImporter(
            isPresented: $picking,
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task { await uploadFile(url) }
            }
        }
        .task { await checkForMac() }
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

            if let failure = spotify.error {
                Text(failure)
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // A saved client ID used to be the end of it: the button above
            // stopped offering the form and went straight to connecting, so a
            // wrong ID could be entered once and never corrected.
            if !spotify.clientID.isEmpty {
                Button("Change client ID") { showingSpotifySetup = true }
                    .font(.callout)
            }
        }
    }

    private var looksLikeLink: Bool {
        let text = link.trimmingCharacters(in: .whitespaces)
        return text.contains(".") && !text.contains(" ")
    }

    /// Whether any Mac is paired to this account.
    private func checkForMac() async {
        guard let url = client.baseURL?.appendingPathComponent("api/auth/pairings")
        else { return }
        let found = try? await URLSession.shared.data(for: client.request(url))
        guard let data = found?.0,
              let list = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return }
        hasMac = !list.isEmpty
        // With no Mac, a file separated in the cloud is the only thing that
        // works, so do not leave the choice pointing somewhere impossible.
        if !hasMac { destination = "cloud" }
    }

    /// Send a file the person already has, and let the server work out what
    /// format it is in.
    private func uploadFile(_ url: URL) async {
        error = nil
        added = nil
        // A file from the document picker is only readable inside this.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        uploading = 0
        defer { uploading = nil }
        do {
            _ = try await client.upload(
                file: url,
                title: url.deletingPathExtension().lastPathComponent,
                destination: destination,
                progress: { uploading = $0 }
            )
            added = destination == "cloud"
                ? "Uploaded — separating in the cloud"
                : "Uploaded — waiting for a Mac"
            await queue.refresh()
        } catch {
            self.error = error.localizedDescription
        }
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
            _ = try await client.separate(link: title, destination: destination)
            link = ""
            added = destination == "cloud"
                ? "Added — a Mac will fetch it, then the cloud separates"
                : "Added to the queue"
            await queue.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
