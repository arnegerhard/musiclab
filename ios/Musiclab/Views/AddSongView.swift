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
    @State private var phase = ""
    @State private var fraction: Double = 0

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
                Text("The download happens on this phone. YouTube refuses a "
                     + "server in a datacenter but not a phone, so the audio is "
                     + "fetched here and only the audio is sent on.")
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

    /// Wraps a failure with the step it happened in.
    private struct Step: LocalizedError {
        let step: String
        let underlying: Error

        static func failed(_ step: String, _ error: Error) -> Step {
            Step(step: step, underlying: error)
        }

        var errorDescription: String? {
            "\(step) failed: \(underlying.localizedDescription)"
        }
    }

    private var looksLikeLink: Bool {
        let text = link.trimmingCharacters(in: .whitespaces)
        return text.contains(".") && !text.contains(" ")
    }

    private func separateLink() async {
        submitting = true
        error = nil
        fraction = 0
        defer { submitting = false; phase = ""; fraction = 0 }

        let text = link.trimmingCharacters(in: .whitespaces)
        do {
            if YouTubeFetcher.videoID(from: text) != nil {
                phase = "Downloading from YouTube"
                let fetched: YouTubeFetcher.Fetched
                do {
                    fetched = try await YouTubeFetcher.fetch(link: text) { done in
                        Task { @MainActor in fraction = done * 0.6 }
                    }
                } catch {
                    // Naming the step matters: "the network connection was
                    // lost" means very different things on either side of it.
                    throw Step.failed("Downloading from YouTube", error)
                }
                defer { try? FileManager.default.removeItem(at: fetched.file) }

                let size = (try? FileManager.default.attributesOfItem(
                    atPath: fetched.file.path)[.size] as? Int) ?? 0
                phase = "Uploading \(size / 1_000_000) MB"
                let job: String
                do {
                    job = try await client.upload(
                        file: fetched.file, title: fetched.title,
                        videoID: fetched.videoID, pageURL: fetched.pageURL
                    ) { done in
                        Task { @MainActor in fraction = 0.6 + done * 0.4 }
                    }
                } catch {
                    throw Step.failed("Uploading to the server", error)
                }
                link = ""
                batchID = job
            } else {
                // Not YouTube: let the server fetch it, which it can.
                phase = "Sending to the server"
                let job = try await client.separate(link: text)
                link = ""
                batchID = job
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
