import AuthenticationServices
import CryptoKit
import Foundation
import Observation

/// Reads playlists from Spotify's Web API.
///
/// Metadata only, and not by choice: Spotify never exposes decoded audio to
/// third-party apps. Playlists here are a way to *choose* a song; the audio is
/// matched separately on the Mac.
///
/// Authorisation Code with PKCE, because a phone app cannot keep a client
/// secret. You supply a client ID from your own Spotify developer dashboard.
@Observable
final class SpotifySource: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let redirectURI = "musiclab://spotify-callback"
    private static let scopes = "playlist-read-private playlist-read-collaborative"

    private(set) var playlists: [PlaylistSummary] = []
    private(set) var isConnected = false
    private(set) var error: String?

    private var accessToken: String?
    private var expiry: Date?
    private var session: ASWebAuthenticationSession?

    var clientID: String {
        get { UserDefaults.standard.string(forKey: "spotifyClientID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "spotifyClientID") }
    }

    override init() {
        super.init()
        isConnected = Keychain.read("spotifyRefreshToken") != nil
    }

    // MARK: - Authorisation

    func connect() async {
        // Clear last time's complaint, or a fixed client ID still shows the
        // failure it caused.
        error = nil
        guard !clientID.isEmpty else {
            error = "Add your Spotify client ID first."
            return
        }
        let verifier = Self.randomVerifier()
        let challenge = Self.challenge(for: verifier)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: Self.scopes),
        ]

        do {
            let callback = try await authorise(url: components.url!)
            guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value
            else {
                error = "Spotify did not return an authorisation code."
                return
            }
            try await exchange(code: code, verifier: verifier)
            isConnected = true
            error = nil
            await loadPlaylists()
        } catch {
            // A user cancelling the sheet is not a failure worth shouting about.
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                self.error = error.localizedDescription
            }
        }
    }

    func disconnect() {
        Keychain.delete("spotifyRefreshToken")
        accessToken = nil
        expiry = nil
        isConnected = false
        playlists = []
    }

    private func authorise(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: "musiclab"
            ) { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: error ?? URLError(.badServerResponse)) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }

    private func exchange(code: String, verifier: String) async throws {
        try await token(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
    }

    private func refresh() async throws {
        guard let refreshToken = Keychain.read("spotifyRefreshToken") else {
            throw URLError(.userAuthenticationRequired)
        }
        try await token(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
    }

    private func token(form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Spotify", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Spotify rejected the sign-in. Check the client ID and that \(Self.redirectURI) is a redirect URI on your Spotify app.",
            ])
        }
        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = payload.access_token
        expiry = Date().addingTimeInterval(TimeInterval(payload.expires_in - 60))
        if let refresh = payload.refresh_token {
            Keychain.write("spotifyRefreshToken", value: refresh)
        }
    }

    private func validToken() async throws -> String {
        if let accessToken, let expiry, expiry > Date() { return accessToken }
        try await refresh()
        guard let accessToken else { throw URLError(.userAuthenticationRequired) }
        return accessToken
    }

    // MARK: - Data

    func loadPlaylists() async {
        do {
            let token = try await validToken()
            let page: PlaylistPage = try await get("me/playlists?limit=50", token: token)
            playlists = page.items.map {
                MusicCollection(
                    id: $0.id,
                    name: $0.name,
                    subtitle: $0.owner?.display_name ?? "",
                    trackCount: $0.tracks.total,
                    source: .spotify,
                    kind: .playlist,
                    artwork: ($0.images?.first?.url).flatMap(URL.init).map(Artwork.remote) ?? .none
                )
            }
            isConnected = true
        } catch {
            self.error = "Could not load Spotify playlists."
        }
    }

    func tracks(in playlist: PlaylistSummary) async -> [PlaylistTrack] {
        do {
            let token = try await validToken()
            var collected: [PlaylistTrack] = []
            var next: String? = "playlists/\(playlist.id)/tracks?limit=100"
            // Spotify pages at 100; a long playlist would otherwise be truncated.
            while let path = next {
                let page: TrackPage = try await get(path, token: token)
                collected += page.items.compactMap { item in
                    guard let track = item.track else { return nil }
                    return Self.track(track)
                }
                next = page.next.flatMap { URL(string: $0)?.path.replacingOccurrences(of: "/v1/", with: "").appending("?\(URL(string: $0)?.query ?? "")") }
            }
            return collected
        } catch {
            self.error = "Could not load those tracks."
            return []
        }
    }

    /// Spotify's own catalogue search, so a song that is in no playlist is
    /// still reachable -- the same thing the Spotify app's search box does.
    func search(_ text: String) async -> [PlaylistTrack] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 1, isConnected else { return [] }
        guard let escaped = trimmed.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) else { return [] }
        do {
            let token = try await validToken()
            let result: SearchResult = try await get(
                "search?q=\(escaped)&type=track&limit=40", token: token
            )
            return result.tracks.items.map(Self.track)
        } catch {
            return []
        }
    }

    private static func track(_ track: TrackPage.Track) -> PlaylistTrack {
        PlaylistTrack(
            id: track.id ?? UUID().uuidString,
            title: track.name,
            artist: track.artists.first?.name ?? "",
            duration: Double(track.duration_ms) / 1000,
            sourceName: "spotify",
            album: track.album?.name ?? "",
            artwork: (track.album?.images?.first?.url).flatMap(URL.init).map(Artwork.remote) ?? .none
        )
    }

    private func get<T: Decodable>(_ path: String, token: String) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/\(path)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }

    // MARK: - PKCE

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    private static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    // MARK: - Wire types

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
    }
    struct Image: Decodable { let url: String }

    private struct PlaylistPage: Decodable {
        struct Item: Decodable {
            struct Tracks: Decodable { let total: Int }
            struct Owner: Decodable { let display_name: String? }
            let id: String; let name: String; let tracks: Tracks
            let images: [Image]?; let owner: Owner?
        }
        let items: [Item]
    }

    struct TrackPage: Decodable {
        struct Item: Decodable { let track: Track? }
        struct Album: Decodable { let name: String; let images: [Image]? }
        struct Track: Decodable {
            struct Artist: Decodable { let name: String }
            let id: String?; let name: String
            let artists: [Artist]; let duration_ms: Int
            let album: Album?
        }
        let items: [Item]; let next: String?
    }

    private struct SearchResult: Decodable {
        struct Tracks: Decodable { let items: [TrackPage.Track] }
        let tracks: Tracks
    }
}

extension Data {
    /// base64url per RFC 7636: no padding, URL-safe alphabet.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Refresh tokens are long-lived credentials, so they belong in the keychain
/// rather than UserDefaults.
enum Keychain {
    static func write(_ key: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ] as CFDictionary)
    }
}
