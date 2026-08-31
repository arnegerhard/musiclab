import MediaPlayer
import SwiftUI

/// Album art for a row, from wherever that source keeps it.
struct ArtworkView: View {
    let artwork: Artwork
    var size: CGFloat = 48
    var corner: CGFloat = 6

    @State private var libraryImage: UIImage?

    var body: some View {
        Group {
            switch artwork {
            case let .remote(url):
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            case .library:
                if let libraryImage {
                    Image(uiImage: libraryImage).resizable().scaledToFill()
                } else {
                    placeholder
                }
            case .none:
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .task(id: artwork) { await loadFromLibrary() }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner).fill(.quaternary)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.4))
                .foregroundStyle(.secondary)
        }
    }

    /// Library art lives in-process, so it is looked up by id and cached --
    /// a query per row per redraw would make scrolling stutter.
    private func loadFromLibrary() async {
        guard case let .library(persistentID) = artwork else { return }
        if let cached = ArtworkCache.shared.image(for: persistentID) {
            libraryImage = cached
            return
        }
        let target = CGSize(width: size * 3, height: size * 3)
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(MPMediaPropertyPredicate(
                value: NSNumber(value: persistentID),
                forProperty: MPMediaItemPropertyPersistentID
            ))
            return query.items?.first?.artwork?.image(at: target)
        }.value
        if let image { ArtworkCache.shared.store(image, for: persistentID) }
        libraryImage = image
    }
}

final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSNumber, UIImage>()

    func image(for id: UInt64) -> UIImage? { cache.object(forKey: NSNumber(value: id)) }
    func store(_ image: UIImage, for id: UInt64) {
        cache.setObject(image, forKey: NSNumber(value: id))
    }
}
