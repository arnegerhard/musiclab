import SwiftUI

/// Browse one connected service the way its own app does: search across
/// everything, or drill into playlists and albums.
struct MusicBrowserView: View {
    let source: MusicSource

    @Environment(AppleMusicSource.self) private var apple
    @Environment(SpotifySource.self) private var spotify

    private enum Shelf: String, CaseIterable, Identifiable {
        case playlists, albums
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @State private var shelf: Shelf = .playlists
    @State private var query = ""
    @State private var results: [PlaylistTrack] = []
    @State private var searching = false

    var body: some View {
        List {
            if !query.isEmpty {
                searchResults
            } else {
                if source == .appleMusic {
                    Picker("Shelf", selection: $shelf) {
                        ForEach(Shelf.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                }
                collections
            }
        }
        .listStyle(.plain)
        .navigationTitle(source.label)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Songs, artists, albums")
        .navigationDestination(for: MusicCollection.self) { collection in
            TrackPickerView(title: collection.name, loader: .collection(collection))
        }
        .task(id: query) { await runSearch() }
        .task { if source == .appleMusic { apple.load() } }
    }

    @ViewBuilder private var searchResults: some View {
        if searching {
            HStack(spacing: 12) { ProgressView(); Text("Searching…") }
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            // A search hit goes straight to the picker, already selected.
            Section("\(results.count) songs") {
                ForEach(results) { track in
                    NavigationLink {
                        TrackPickerView(title: track.title, loader: .tracks([track]))
                    } label: {
                        TrackRow(track: track)
                    }
                }
            }
        }
    }

    @ViewBuilder private var collections: some View {
        let items = source == .appleMusic
            ? (shelf == .playlists ? apple.playlists : apple.albums)
            : spotify.playlists

        if items.isEmpty {
            // load() returns empty both when the library really is empty and
            // when the app was never allowed to look. Saying "nothing in your
            // library" to somebody who has simply not granted access yet
            // sends them looking for a problem in the wrong place.
            if source == .appleMusic, !apple.isAuthorised {
                ContentUnavailableView {
                    Label("No access to your music", systemImage: "lock")
                } description: {
                    Text(apple.error
                         ?? "Musiclab has not been allowed to read your music library.")
                } actions: {
                    Button("Allow access") { Task { await apple.requestAccess() } }
                        .buttonStyle(.borderedProminent)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "music.note.list",
                    description: Text(source == .appleMusic
                                      ? "No \(shelf.label.lowercased()) in your library."
                                      : "No playlists on this account.")
                )
            }
        } else {
            ForEach(items) { collection in
                NavigationLink(value: collection) {
                    HStack(spacing: 12) {
                        ArtworkView(artwork: collection.artwork)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(collection.name).lineLimit(1)
                            Text(collection.subtitle.isEmpty
                                 ? "\(collection.trackCount) songs"
                                 : "\(collection.subtitle) · \(collection.trackCount) songs")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func runSearch() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count > 1 else {
            results = []
            return
        }
        searching = true
        defer { searching = false }
        // Let typing settle before hitting the library or the network.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        results = source == .appleMusic ? apple.search(text) : await spotify.search(text)
    }
}

struct TrackRow: View {
    let track: PlaylistTrack
    var selected: Bool?

    var body: some View {
        HStack(spacing: 12) {
            if let selected {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? .green : .secondary)
            }
            ArtworkView(artwork: track.artwork, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                Text(track.album.isEmpty ? track.artist : "\(track.artist) · \(track.album)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let duration = track.duration {
                Text(clock(duration))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
