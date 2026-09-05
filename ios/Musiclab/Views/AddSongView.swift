import SwiftUI
import UniformTypeIdentifiers

/// The "+" tab: gather songs from wherever they come from, then decide once
/// where they should be separated.
struct AddSongView: View {
    @Environment(StemsClient.self) private var client
    @Environment(AppleMusicSource.self) private var apple
    @Environment(SpotifySource.self) private var spotify
    @Environment(JobQueue.self) private var queue
    @Environment(Basket.self) private var basket
    @Environment(\.scenePhase) private var scenePhase

    @State private var link = ""
    @State private var picking = false
    @State private var pairing = false
    @State private var showingSpotifySetup = false
    @State private var submitting = false
    @State private var progress = ""
    @State private var added: String?
    @State private var error: String?
    /// Whether this account has a Mac at all. Without one only the cloud can
    /// do anything, and only with songs that need no fetching.
    @State private var hasMac = false

    var body: some View {
        // A VStack rather than another safeAreaInset: the mini player already
        // insets the bottom of this tab, and two of them do not stack -- the
        // buttons ended up underneath the bar, sliced in half. Laid out as a
        // sibling, the footer sits above whatever the bar reserves.
        VStack(spacing: 0) {
        List {
            // A link, an Apple Music track and a Spotify track all have to be
            // downloaded from somewhere that answers a home connection, which
            // is a paired Mac. Without one they are not slow or awkward, they
            // are impossible, so they are not offered.
            if hasMac { linkSection }
            fileSection
            if hasMac { servicesSection } else { noMacSection }
            if !basket.isEmpty { chosenSection }
        }
        // Not rows. A confirmation and an error are momentary, and as
        // conditional sections in the same list as one that gains several
        // items at once -- picking three files adds three -- they made two
        // sections change shape in a single update, which is the diff
        // UICollectionView refuses to accept.
        .safeAreaInset(edge: .top) {
            if let added {
                notice(added, systemImage: "checkmark.circle.fill", tint: .green)
            } else if let error {
                notice(error, systemImage: "exclamationmark.triangle.fill",
                       tint: .red)
            }
        }
        .navigationTitle("Add a song")
        .navigationDestination(for: MusicSource.self) { MusicBrowserView(source: $0) }
        .sheet(isPresented: $showingSpotifySetup) { SpotifySetupView(spotify: spotify) }
        .fileImporter(
            isPresented: $picking,
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                for url in urls where url.startAccessingSecurityScopedResource() {
                    basket.add(.file(url))
                }
                added = nil
            }
        }
        // The confirmation says the songs were queued. Once the queue has
        // drained they are not queued any more, they are done -- and a green
        // tick still claiming otherwise is just wrong by then.
        .onChange(of: queue.count) { _, remaining in
            if remaining == 0 { added = nil }
        }
        .task { await checkForMac() }
        // Pairing happens elsewhere -- the Queue tab, or the sheet below --
        // and .task only ever runs once, so this screen went on believing
        // there was no Mac long after one had been adopted.
        .onAppear { Task { await checkForMac() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await checkForMac() } }
        }
        .sheet(isPresented: $pairing) {
            PairMacView()
        }
        .onChange(of: pairing) { _, showing in
            if !showing { Task { await checkForMac() } }
        }

            footer
        }
    }

    // MARK: - Ways in

    private var linkSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField("youtube.com/watch?v=…", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .onSubmit(addLink)
                if link.isEmpty {
                    Button("Paste") {
                        link = UIPasteboard.general.string?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    }
                    .font(.callout).buttonStyle(.bordered)
                } else {
                    Button("Add", action: addLink)
                        .font(.callout).buttonStyle(.borderedProminent)
                        .disabled(!looksLikeLink)
                }
            }
        } header: {
            Text("Paste a link")
        } footer: {
            Text(hasMac
                 ? "Any link yt-dlp understands, not only YouTube."
                 : "Any link yt-dlp understands — but a link has to be "
                   + "downloaded by a Mac, and none is paired yet.")
        }
    }

    private var fileSection: some View {
        Section {
            Button {
                added = nil
                picking = true
            } label: {
                Label("Choose audio files", systemImage: "waveform.badge.plus")
            }
        } header: {
            Text("Files you already have")
        } footer: {
            Text("MP3, M4A, FLAC, WAV, OGG — whatever it is, it gets converted.")
        }
    }

    private var noMacSection: some View {
        Section {
            Button {
                pairing = true
            } label: {
                HStack {
                    Label("No Mac is paired",
                          systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .font(.callout)
        } footer: {
            Text("Links, Apple Music and Spotify all need a Mac to download "
                 + "the audio — the cloud is refused by YouTube. Tap to pair "
                 + "one, or separate files you already have.")
        }
    }

    private var servicesSection: some View {
        Section("From your music") {
            appleRow
            spotifyRow
        }
    }

    private func notice(
        _ text: String, systemImage: String, tint: Color
    ) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(tint)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
    }

    // MARK: - What has been chosen

    private var chosenSection: some View {
        Section {
            ForEach(basket.items) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.callout).lineLimit(1)
                        Text(item.subtitle)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    // A visible control as well as the swipe: a swipe is not
                    // something you can see, and this is a list people will
                    // want to correct before spending ten minutes on it.
                    Button {
                        withAnimation { basket.remove(item) }
                        added = nil
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(item.title)")
                }
            }
            .onDelete { basket.remove(atOffsets: $0) }
        } header: {
            HStack {
                Text("Ready to separate (\(basket.count))")
                Spacer()
                if basket.count > 1 {
                    Button("Remove all") {
                        withAnimation { basket.clear() }
                        added = nil
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
        }
    }

    /// Both places to send it, side by side.
    ///
    /// A menu hid the choice behind a tap and named only one of the two on
    /// the button, which made the cheap option look like the only option.
    @ViewBuilder private var footer: some View {
        if !basket.isEmpty {
            VStack(spacing: 8) {
                if submitting {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(progress).font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("\(basket.count) song\(basket.count == 1 ? "" : "s") ready — separate them")
                        .font(.caption).foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        if hasMac {
                            Button {
                                Task { await send(to: "mac") }
                            } label: {
                                VStack(spacing: 2) {
                                    Label("On a Mac", systemImage: "desktopcomputer")
                                        .fontWeight(.medium)
                                    Text("free, slower").font(.caption2).opacity(0.8)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        Button {
                            Task { await send(to: "cloud") }
                        } label: {
                            VStack(spacing: 2) {
                                Label("On Modal", systemImage: "bolt")
                                    .fontWeight(.medium)
                                Text("costs money, fast").font(.caption2).opacity(0.8)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
            .background(.bar)
        }
    }

    // MARK: - Rows

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
            // A saved client ID must always have a way back to the form, or a
            // typo can be entered once and never corrected.
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

    private func addLink() {
        guard looksLikeLink else { return }
        basket.add(.link(link.trimmingCharacters(in: .whitespaces)))
        link = ""
        added = nil
    }

    // MARK: - Handing it all over

    private func checkForMac() async {
        let url = client.baseURL.appendingPathComponent("api/auth/pairings")
        let found = try? await URLSession.shared.data(for: client.request(url))
        guard let data = found?.0,
              let list = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return }
        hasMac = !list.isEmpty
    }

    /// Everything in the basket, in one go, to one place.
    private func send(to destination: String) async {
        submitting = true
        error = nil
        added = nil
        defer { submitting = false; progress = "" }

        let links = basket.links
        let files = basket.files
        let tracks = basket.tracks
        var sent = 0

        do {
            for (index, link) in links.enumerated() {
                progress = "Sending link \(index + 1) of \(links.count)…"
                _ = try await client.separate(link: link, destination: destination)
                sent += 1
            }
            for (index, file) in files.enumerated() {
                progress = "Uploading file \(index + 1) of \(files.count)…"
                _ = try await client.upload(
                    file: file,
                    title: file.deletingPathExtension().lastPathComponent,
                    destination: destination
                )
                sent += 1
            }
            if !tracks.isEmpty {
                progress = "Sending \(tracks.count) song\(tracks.count == 1 ? "" : "s")…"
                _ = try await client.separate(tracks: tracks, destination: destination)
                sent += tracks.count
            }
            // clear() releases the files it drops.
            basket.clear()
            added = "\(sent) song\(sent == 1 ? "" : "s") queued "
                + (destination == "cloud" ? "for Modal" : "for a Mac")
            await queue.refresh()
        } catch {
            // Whatever went over is queued; what is left stays in the basket
            // so it is obvious what still needs sending.
            self.error = sent == 0
                ? error.localizedDescription
                : "Queued \(sent), then: \(error.localizedDescription)"
        }
    }
}
