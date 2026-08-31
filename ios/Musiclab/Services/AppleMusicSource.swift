import MediaPlayer
import Observation

/// Reads playlists from the local music library.
///
/// Deliberately MediaPlayer rather than MusicKit: reading library playlists
/// here needs only a usage description, where MusicKit would need the MusicKit
/// service enabled on a paid App ID. Since Apple Music will not surrender audio
/// either way, metadata is all we are after.
@Observable
final class AppleMusicSource {
    private(set) var playlists: [PlaylistSummary] = []
    private(set) var authorised = false
    private(set) var error: String?

    private var collections: [String: MPMediaPlaylist] = [:]

    var status: MPMediaLibraryAuthorizationStatus {
        MPMediaLibrary.authorizationStatus()
    }

    func requestAccess() async {
        let status = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        authorised = status == .authorized
        if authorised {
            load()
        } else if status == .denied {
            error = "Music library access is off. Turn it on in Settings › Musiclab."
        }
    }

    func load() {
        guard let found = MPMediaQuery.playlists().collections else {
            playlists = []
            return
        }
        var summaries: [PlaylistSummary] = []
        for case let playlist as MPMediaPlaylist in found {
            let name = playlist.value(forProperty: MPMediaPlaylistPropertyName) as? String
            let id = "\(playlist.persistentID)"
            collections[id] = playlist
            summaries.append(
                PlaylistSummary(
                    id: id,
                    name: name ?? "Untitled playlist",
                    trackCount: playlist.count,
                    source: .appleMusic
                )
            )
        }
        playlists = summaries
            .filter { $0.trackCount > 0 }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func tracks(in playlist: PlaylistSummary) -> [PlaylistTrack] {
        guard let collection = collections[playlist.id] else { return [] }
        return collection.items.map { item in
            PlaylistTrack(
                id: "\(item.persistentID)",
                title: item.title ?? "Unknown",
                artist: item.artist ?? item.albumArtist ?? "",
                duration: item.playbackDuration > 0 ? item.playbackDuration : nil,
                sourceName: "apple"
            )
        }
    }
}
