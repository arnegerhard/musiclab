import Foundation
import Observation

/// Songs chosen but not yet handed over.
///
/// Shared, because choosing happens in several places -- a pasted link, a file
/// from the document picker, a selection out of an Apple Music or Spotify
/// playlist -- and the decision about where to separate them belongs to all of
/// it at once rather than to whichever screen the choosing happened on.
@Observable
@MainActor
final class Basket {
    enum Item: Identifiable, Equatable {
        case link(String)
        case file(URL)
        case track(PlaylistTrack)

        var id: String {
            switch self {
            case let .link(url): return "link:\(url)"
            case let .file(url): return "file:\(url.absoluteString)"
            case let .track(track): return "track:\(track.id)"
            }
        }

        var title: String {
            switch self {
            case let .link(url): return url
            case let .file(url): return url.deletingPathExtension().lastPathComponent
            case let .track(track): return track.title
            }
        }

        var subtitle: String {
            switch self {
            case .link: return "Link"
            case let .file(url): return url.pathExtension.uppercased()
            case let .track(track):
                return track.artist.isEmpty ? track.sourceName : track.artist
            }
        }

        var icon: String {
            switch self {
            case .link: return "link"
            case .file: return "waveform"
            case .track: return "music.note"
            }
        }
    }

    private(set) var items: [Item] = []

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    /// Adding the same thing twice is a slip, not a request for two copies.
    func add(_ item: Item) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
    }

    func add(tracks: [PlaylistTrack]) {
        for track in tracks { add(.track(track)) }
    }

    func remove(atOffsets offsets: IndexSet) {
        for case let .file(url) in offsets.map({ items[$0] }) {
            url.stopAccessingSecurityScopedResource()
        }
        items.remove(atOffsets: offsets)
    }

    func remove(_ item: Item) {
        if case let .file(url) = item { url.stopAccessingSecurityScopedResource() }
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        releaseFiles()
        items.removeAll()
    }

    /// Files come from the document picker, which hands over a URL that is
    /// only readable inside a security scope. Held open for as long as the
    /// file sits here waiting to be sent.
    func releaseFiles() {
        for case let .file(url) in items { url.stopAccessingSecurityScopedResource() }
    }

    var tracks: [PlaylistTrack] {
        items.compactMap { if case let .track(t) = $0 { return t } else { return nil } }
    }
    var links: [String] {
        items.compactMap { if case let .link(l) = $0 { return l } else { return nil } }
    }
    var files: [URL] {
        items.compactMap { if case let .file(u) = $0 { return u } else { return nil } }
    }

    /// A link has to be downloaded by a Mac; nothing else here does.
    var needsAMac: Bool { !links.isEmpty }
}
