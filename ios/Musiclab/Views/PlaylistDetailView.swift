import SwiftUI

/// Tracks in one playlist, with multi-select and a hand-off to the Mac.
struct PlaylistDetailView: View {
    let playlist: PlaylistSummary
    let apple: AppleMusicSource
    let spotify: SpotifySource

    @Environment(StemsClient.self) private var client
    @State private var tracks: [PlaylistTrack] = []
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var batchID: String?
    @State private var error: String?

    var body: some View {
        List {
            if loading {
                HStack(spacing: 12) { ProgressView(); Text("Loading tracks…") }
            }
            ForEach(tracks) { track in
                Button {
                    if selected.contains(track.id) { selected.remove(track.id) }
                    else { selected.insert(track.id) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected.contains(track.id)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(track.id) ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).lineLimit(1)
                            Text(track.artist).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let duration = track.duration {
                            Text(clock(duration))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { footer }
        .navigationDestination(item: $batchID) { id in
            BatchView(batchID: id)
        }
        .toolbar {
            Button(selected.count == tracks.count ? "None" : "All") {
                selected = selected.count == tracks.count ? [] : Set(tracks.map(\.id))
            }
            .font(.callout)
        }
        .task { await load() }
    }

    @ViewBuilder private var footer: some View {
        if !selected.isEmpty {
            VStack(spacing: 6) {
                Button {
                    Task { await separate() }
                } label: {
                    Text("Separate \(selected.count) song\(selected.count == 1 ? "" : "s")")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                // Separation is slow and the machine does one at a time, so an
                // honest estimate up front beats a surprise later.
                Text("Roughly \(estimate) on the Mac, one song at a time.")
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
        if minutes < 60 { return "\(max(1, minutes)) min" }
        return String(format: "%.1f hours", Double(minutes) / 60)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        switch playlist.source {
        case .appleMusic: tracks = apple.tracks(in: playlist)
        case .spotify: tracks = await spotify.tracks(in: playlist)
        }
    }

    private func separate() async {
        let chosen = tracks.filter { selected.contains($0.id) }
        do {
            batchID = try await client.separate(tracks: chosen).id
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
