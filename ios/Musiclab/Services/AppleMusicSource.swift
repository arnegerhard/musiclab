import MediaPlayer
import Observation

/// Browses the local music library: playlists, albums, and songs.
///
/// Deliberately MediaPlayer rather than MusicKit: reading the library here
/// needs only a usage description, where MusicKit would need the MusicKit
/// service enabled on a paid App ID. Since Apple Music will not surrender
/// audio either way, metadata is all we are after.
@Observable
final class AppleMusicSource {
    private(set) var playlists: [MusicCollection] = []
    private(set) var albums: [MusicCollection] = []
    private(set) var error: String?

    private var collections: [String: MPMediaItemCollection] = [:]

    var status: MPMediaLibraryAuthorizationStatus {
        MPMediaLibrary.authorizationStatus()
    }

    var isAuthorised: Bool { status == .authorized }

    func requestAccess() async {
        let status = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        if status == .authorized {
            load()
        } else if status == .denied {
            error = "Music library access is off. Turn it on in Settings › Musiclab."
        }
    }

    func load() {
        guard isAuthorised else { return }
        playlists = read(MPMediaQuery.playlists(), kind: .playlist,
                         name: MPMediaPlaylistPropertyName)
        albums = read(MPMediaQuery.albums(), kind: .album,
                      name: MPMediaItemPropertyAlbumTitle)
    }

    private func read(
        _ query: MPMediaQuery, kind: MusicCollection.Kind, name: String
    ) -> [MusicCollection] {
        guard let found = query.collections else { return [] }
        var out: [MusicCollection] = []
        for collection in found where collection.count > 0 {
            let identifier = "\(kind.rawValue):\(collection.persistentID)"
            collections[identifier] = collection
            let item = collection.representativeItem
            let title = (collection.value(forProperty: name) as? String)
                ?? item?.albumTitle ?? "Untitled"
            out.append(MusicCollection(
                id: identifier,
                name: title,
                subtitle: kind == .album ? (item?.albumArtist ?? item?.artist ?? "") : "",
                trackCount: collection.count,
                source: .appleMusic,
                kind: kind,
                artwork: item.map { .library($0.persistentID) } ?? .none
            ))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func tracks(in collection: MusicCollection) -> [PlaylistTrack] {
        guard let found = collections[collection.id] else { return [] }
        return found.items.map(Self.track)
    }

    /// Free-text search across the whole library, as the Music app does.
    func search(_ text: String) -> [PlaylistTrack] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 1, isAuthorised else { return [] }
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(
            value: trimmed, forProperty: MPMediaItemPropertyTitle,
            comparisonType: .contains
        ))
        let byTitle = query.items ?? []

        let artistQuery = MPMediaQuery.songs()
        artistQuery.addFilterPredicate(MPMediaPropertyPredicate(
            value: trimmed, forProperty: MPMediaItemPropertyArtist,
            comparisonType: .contains
        ))
        let byArtist = artistQuery.items ?? []

        var seen = Set<MPMediaEntityPersistentID>()
        return (byTitle + byArtist)
            .filter { seen.insert($0.persistentID).inserted }
            .prefix(100)
            .map(Self.track)
    }

    private static func track(_ item: MPMediaItem) -> PlaylistTrack {
        PlaylistTrack(
            id: "\(item.persistentID)",
            title: item.title ?? "Unknown",
            artist: item.artist ?? item.albumArtist ?? "",
            duration: item.playbackDuration > 0 ? item.playbackDuration : nil,
            sourceName: "apple",
            album: item.albumTitle ?? "",
            artwork: .library(item.persistentID)
        )
    }
}
