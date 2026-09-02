import SwiftUI

/// Pick which songs to separate, from a collection or a search hit.
struct TrackPickerView: View {
    enum Loader: Hashable {
        case collection(MusicCollection)
        case tracks([PlaylistTrack])
    }

    let title: String
    let loader: Loader

    @Environment(StemsClient.self) private var client

    @Environment(JobQueue.self) private var queue
    @Environment(Basket.self) private var basket
    @Environment(\.dismiss) private var dismiss
    @Environment(AppleMusicSource.self) private var apple
    @Environment(SpotifySource.self) private var spotify

    @State private var tracks: [PlaylistTrack] = []
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if loading {
                HStack(spacing: 12) { ProgressView(); Text("Loading…") }
            }
            ForEach(tracks) { track in
                Button {
                    if selected.contains(track.id) { selected.remove(track.id) }
                    else { selected.insert(track.id) }
                } label: {
                    TrackRow(track: track, selected: selected.contains(track.id))
                }
                .buttonStyle(.plain)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { footer }
        .toolbar {
            if tracks.count > 1 {
                Button(selected.count == tracks.count ? "None" : "All") {
                    selected = selected.count == tracks.count ? [] : Set(tracks.map(\.id))
                }
                .font(.callout)
            }
        }
        .task { await load() }
    }

    @ViewBuilder private var footer: some View {
        if !selected.isEmpty {
            VStack(spacing: 6) {
                Button(action: collect) {
                    Text("Add \(selected.count) song\(selected.count == 1 ? "" : "s")")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                // Separation is slow and runs one at a time, so an honest
                // estimate up front beats a surprise later.
                Text("Roughly \(estimate) on a Mac, one song at a time.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
            .background(.bar)
        }
    }

    private var estimate: String {
        // Measured at roughly 2.5x realtime across all three stages.
        let seconds = tracks
            .filter { selected.contains($0.id) }
            .reduce(0.0) { $0 + ($1.duration ?? 240) } * 2.5
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(max(1, minutes)) min"
                            : String(format: "%.1f hours", Double(minutes) / 60)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        switch loader {
        case let .tracks(given):
            tracks = given
            selected = Set(given.map(\.id))     // a single hit is already the choice
        case let .collection(collection):
            tracks = collection.source == .appleMusic
                ? apple.tracks(in: collection)
                : await spotify.tracks(in: collection)
        }
    }

    /// Put the selection in the basket and go back.
    ///
    /// Nothing is sent from here any more: where these get separated is one
    /// decision made on the Add screen, alongside whatever else was chosen
    /// from a link, a file, or the other service.
    private func collect() {
        basket.add(tracks: tracks.filter { selected.contains($0.id) })
        selected = []
        dismiss()
    }
}
