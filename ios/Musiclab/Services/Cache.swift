import Foundation

/// What the app already knew, kept between launches.
///
/// The library and the list of Macs are answers the server takes between half
/// a second and a couple of seconds to give, and almost every time it is the
/// same answer as last time. Written down, the app can draw the screen it drew
/// before rather than a spinner, and correct it a moment later if the server
/// disagrees.
///
/// The ETag travels with the value, so the next request can ask "still this?"
/// and be told 304 without either side building or parsing the answer again.
enum Cache {
    struct Stored<T: Codable>: Codable {
        var etag: String
        var value: T
    }

    private static var directory: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let folder = base.appendingPathComponent("Musiclab/cache", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )
        return folder
    }

    /// Per account. Signing into a different one must never show the last
    /// one's songs, and an empty account id is not a namespace -- it is the
    /// absence of one, so nothing is read or written under it.
    private static func file(_ key: String, account: String) -> URL? {
        guard !account.isEmpty, let directory else { return nil }
        let safe = account.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !safe.isEmpty else { return nil }
        return directory.appendingPathComponent("\(safe)-\(key).json")
    }

    static func read<T: Codable>(
        _ key: String, account: String, as type: T.Type
    ) -> Stored<T>? {
        guard let file = file(key, account: account),
              let data = try? Data(contentsOf: file)
        else { return nil }
        // A cache written by an older build may not decode any more. That is
        // not an error, it is simply nothing to start from.
        return try? JSONDecoder().decode(Stored<T>.self, from: data)
    }

    static func write<T: Codable>(_ value: T, etag: String, key: String, account: String) {
        guard let file = file(key, account: account),
              let data = try? JSONEncoder().encode(Stored(etag: etag, value: value))
        else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// On sign-out, so the next person to use this phone starts blank.
    static func forget(account: String) {
        guard let directory, !account.isEmpty else { return }
        let safe = account.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !safe.isEmpty else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for file in files where file.lastPathComponent.hasPrefix("\(safe)-") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
