import Foundation
import Observation

/// The separated songs, held once for the whole app and kept between launches.
///
/// This used to be state inside the Library screen, which meant it started
/// empty every launch and every time the view was rebuilt: a spinner, then
/// half a second of waiting on a server that walks a network volume and reads
/// every manifest on it, then the same list as last time. Now the last list is
/// on disk and goes up immediately, and the server is asked afterwards whether
/// it still stands.
@Observable
@MainActor
final class LibraryStore {
    private(set) var entries: [LibraryEntry] = []
    /// Whether there is anything to show at all -- from disk or from the
    /// server. Distinct from having asked: an empty library and a library
    /// nobody has looked up yet must not read the same.
    private(set) var hasLoaded = false
    private(set) var lastError: String?

    private var client: StemsClient?
    private var account = ""
    private var etag = ""
    private var loading = false

    private static let key = "library"

    /// Called once the account is known, which is the earliest the cache can
    /// be read: it is filed per account.
    func begin(with client: StemsClient, account: String) {
        self.client = client
        guard account != self.account else { return }
        self.account = account
        entries = []
        etag = ""
        hasLoaded = false
        if let stored = Cache.read(Self.key, account: account, as: [LibraryEntry].self) {
            entries = stored.value
            etag = stored.etag
            hasLoaded = true
        }
    }

    func forget() {
        Cache.forget(account: account)
        account = ""
        entries = []
        etag = ""
        hasLoaded = false
    }

    /// `quietly` for the automatic passes. An error banner for one dropped
    /// poll would be worse than the staleness it is reporting.
    func refresh(quietly: Bool = true) async {
        guard let client, !client.token.isEmpty, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            // 304 means the list on screen is already right, and the server
            // stopped before reading a single manifest to tell us so.
            if let fresh = try await client.library(ifNoneMatch: etag) {
                entries = fresh.entries
                etag = fresh.etag
                Cache.write(fresh.entries, etag: fresh.etag,
                            key: Self.key, account: account)
            }
            hasLoaded = true
            lastError = nil
        } catch {
            if !quietly { lastError = error.localizedDescription }
        }
    }

    /// After a delete, so the screen does not wait for a poll to agree.
    func drop(slug: String) {
        entries.removeAll { $0.slug == slug }
        // The etag is now wrong for what is held, and clearing it forces the
        // next refresh to fetch rather than be told nothing changed.
        etag = ""
        Cache.write(entries, etag: "", key: Self.key, account: account)
    }

    func clear() {
        entries = []
        etag = ""
        Cache.write(entries, etag: "", key: Self.key, account: account)
    }
}
