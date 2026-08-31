import Foundation
import Observation

/// Talks to the stems server on the Mac and caches stems on the device.
///
/// Stems are downloaded rather than streamed: AVAudioFile needs a local file,
/// and having every stem on disk is what allows all fourteen players to be
/// scheduled against one shared start time.
@Observable
final class StemsClient {
    enum ClientError: LocalizedError {
        case notConnected
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to a stems server."
            case let .badResponse(code): return "The server replied with \(code)."
            }
        }
    }

    var baseURL: URL? {
        didSet { UserDefaults.standard.set(baseURL?.absoluteString, forKey: "baseURL") }
    }

    private(set) var downloadProgress: Double = 0

    /// Sent as a bearer token when the server asks for one. A token typed in
    /// by hand wins over the one baked into the build.
    var token: String {
        get {
            Keychain.read("serverToken")
                ?? (Bundle.main.object(forInfoDictionaryKey: "MusiclabCloudToken") as? String ?? "")
        }
        set {
            newValue.isEmpty ? Keychain.delete("serverToken")
                             : Keychain.write("serverToken", value: newValue)
        }
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "baseURL") {
            baseURL = URL(string: saved)
        }
    }

    /// Every outgoing request goes through here so none forgets the token.
    func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        let token = self.token
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private var decoder: JSONDecoder { JSONDecoder() }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let baseURL else { throw ClientError.notConnected }
        let (data, response) = try await URLSession.shared.data(
            for: request(baseURL.appendingPathComponent(path))
        )
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClientError.badResponse(http.statusCode)
        }
        return try decoder.decode(T.self, from: data)
    }

    /// Confirms a host really is a stems server before we adopt it.
    func probe(_ url: URL) async -> Bool {
        var request = self.request(url.appendingPathComponent("api/health"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["service"] as? String == "stems"
    }

    func library() async throws -> [LibraryEntry] {
        try await get("api/library")
    }

    func track(slug: String) async throws -> Track {
        try await get("api/library/\(slug)")
    }

    // MARK: - Local cache

    private var cacheRoot: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("tracks", isDirectory: true)
    }

    func localDirectory(for slug: String) -> URL {
        cacheRoot.appendingPathComponent(slug, isDirectory: true)
    }

    func isDownloaded(slug: String, stems: [Stem]) -> Bool {
        let directory = localDirectory(for: slug)
        let wanted = stems.filter { $0.spatial != nil }
        guard !wanted.isEmpty else { return false }
        return wanted.allSatisfy {
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("\($0.name).m4a").path
            )
        }
    }

    /// Fetch every stem's mono asset, returning stem name -> local file URL.
    @discardableResult
    func download(slug: String, stems: [Stem]) async throws -> [String: URL] {
        guard let baseURL else { throw ClientError.notConnected }
        let directory = localDirectory(for: slug)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        var result: [String: URL] = [:]
        let targets = stems.compactMap { stem -> (Stem, String)? in
            guard let spatial = stem.spatial else { return nil }
            return (stem, spatial)
        }

        downloadProgress = 0
        for (index, (stem, spatial)) in targets.enumerated() {
            let destination = directory.appendingPathComponent("\(stem.name).m4a")
            if !FileManager.default.fileExists(atPath: destination.path) {
                let remote = baseURL.appendingPathComponent("files/\(slug)/\(spatial)")
                let (temp, response) = try await URLSession.shared.download(for: request(remote))
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw ClientError.badResponse(http.statusCode)
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temp, to: destination)
            }
            result[stem.name] = destination
            downloadProgress = Double(index + 1) / Double(targets.count)
        }
        return result
    }

    func localURLs(slug: String, stems: [Stem]) -> [String: URL] {
        let directory = localDirectory(for: slug)
        var result: [String: URL] = [:]
        for stem in stems where stem.spatial != nil {
            let url = directory.appendingPathComponent("\(stem.name).m4a")
            if FileManager.default.fileExists(atPath: url.path) { result[stem.name] = url }
        }
        return result
    }
}

// MARK: - Scenes

extension StemsClient {
    /// Scenes are a convenience, so both directions fail quietly.
    func scene(slug: String) async -> SpatialScene? {
        guard let baseURL else { return nil }
        let url = baseURL.appendingPathComponent("api/library/\(slug)/scene")
        guard let (data, _) = try? await URLSession.shared.data(for: request(url)) else { return nil }
        return try? JSONDecoder().decode(SpatialScene.self, from: data)
    }

    func saveScene(_ scene: SpatialScene, slug: String) async {
        guard let baseURL, let body = try? JSONEncoder().encode(scene) else { return }
        var request = self.request(
            baseURL.appendingPathComponent("api/library/\(slug)/scene")
        )
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)
    }
}

// MARK: - Playlist tracks -> separation jobs

extension StemsClient {
    private func post<Body: Encodable, Reply: Decodable>(
        _ path: String, body: Body
    ) async throws -> Reply {
        guard let baseURL else { throw ClientError.notConnected }
        var request = self.request(baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClientError.badResponse(http.statusCode)
        }
        return try JSONDecoder().decode(Reply.self, from: data)
    }

    struct BatchBody: Encodable {
        let tracks: [PlaylistTrack]
        let audio_format: String
        let require_confident: Bool
    }
    struct BatchReply: Decodable { let id: String; let jobs: [String] }
    struct BatchStatus: Decodable { let id: String; let jobs: [JobStatus] }
    struct MatchReply: Decodable { let candidates: [MatchCandidate] }
    struct ConfirmBody: Encodable { let video_id: String }
    struct OK: Decodable { let ok: Bool }

    /// What would this track be matched to? Used to preview before committing.
    func preview(track: PlaylistTrack) async throws -> [MatchCandidate] {
        let reply: MatchReply = try await post("api/match", body: track)
        return reply.candidates
    }

    func separate(
        tracks: [PlaylistTrack], format: String = "flac", requireConfident: Bool = true
    ) async throws -> BatchReply {
        try await post(
            "api/batch",
            body: BatchBody(
                tracks: tracks, audio_format: format, require_confident: requireConfident
            )
        )
    }

    func batch(id: String) async throws -> [JobStatus] {
        guard let baseURL else { throw ClientError.notConnected }
        let (data, _) = try await URLSession.shared.data(
            for: request(baseURL.appendingPathComponent("api/batch/\(id)"))
        )
        return try JSONDecoder().decode(BatchStatus.self, from: data).jobs
    }

    @discardableResult
    func confirm(job: String, videoId: String) async throws -> Bool {
        let reply: OK = try await post(
            "api/jobs/\(job)/confirm", body: ConfirmBody(video_id: videoId)
        )
        return reply.ok
    }
}
