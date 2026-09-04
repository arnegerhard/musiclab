import Foundation
import UIKit
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

    /// The session token from signing in. Lives in the keychain, never in
    /// UserDefaults, and is sent as a bearer token on every request.
    var token: String {
        get { Keychain.read("sessionToken") ?? "" }
        set {
            newValue.isEmpty ? Keychain.delete("sessionToken")
                             : Keychain.write("sessionToken", value: newValue)
        }
    }

    /// Who is signed in, or nil. Set by Account after a successful call.
    var user: Account.User?

    init() {
        if let saved = UserDefaults.standard.string(forKey: "baseURL") {
            baseURL = URL(string: saved)
        }
    }

    /// Every outgoing request goes through here so none forgets the token.
    /// Mint a single-use code for adopting a Mac. Both the pairing screen and
    /// the welcome sheet need one, and it is spent by the Mac within seconds.
    func mintPairingCode() async throws -> (code: String, server: String) {
        guard let baseURL else { throw ClientError.notConnected }
        var request = self.request(baseURL.appendingPathComponent("api/auth/pair"))
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = payload["code"] as? String
        else { throw ClientError.badResponse(status) }
        return (code, baseURL.absoluteString)
    }

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
    ///
    /// The timeout is a parameter because the two candidates behave nothing
    /// alike: a Mac on the same network answers immediately or not at all,
    /// while a serverless host has to start a container first.
    func probe(_ url: URL, timeout: TimeInterval = 3) async -> Bool {
        var request = self.request(url.appendingPathComponent("api/health"))
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["service"] as? String == "stems"
    }

    /// Delete a track and every stem of it, on the server and on this device.
    ///
    /// The device copy matters as much as the server's: stems are downloaded
    /// rather than streamed, so a deleted song leaves a few hundred megabytes
    /// behind in the cache if only the server is told.
    func delete(slug: String) async throws {
        guard let baseURL else { throw ClientError.notConnected }
        var request = self.request(baseURL.appendingPathComponent("api/library/\(slug)"))
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 404 means it is already gone, which is what was wanted.
        guard code == 200 || code == 404 else { throw ClientError.badResponse(code) }
        try? FileManager.default.removeItem(at: localDirectory(for: slug))
    }

    /// The cover for a track, cached beside its stems.
    ///
    /// Wanted by the lock screen and the bar above the tabs, so it is fetched
    /// once and kept rather than pulled down every time a song starts.
    func artwork(for entry: LibraryEntry) async -> UIImage? {
        guard let relative = entry.artwork, let baseURL else { return nil }
        let cached = localDirectory(for: entry.slug).appendingPathComponent("cover.jpg")
        if let data = try? Data(contentsOf: cached), let image = UIImage(data: data) {
            return image
        }
        let remote = baseURL.appendingPathComponent("files/\(entry.slug)/\(relative)")
        guard let (data, response) = try? await URLSession.shared.data(for: request(remote)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data)
        else { return nil }
        try? FileManager.default.createDirectory(
            at: localDirectory(for: entry.slug), withIntermediateDirectories: true
        )
        try? data.write(to: cached)
        return image
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

    /// Throw away every downloaded stem. Used when the account they belong
    /// to is deleted -- otherwise a few hundred megabytes of a library that no
    /// longer exists stays on the device.
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheRoot)
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
    /// Fetch every stem's mono asset, returning stem name -> local file URL.
    ///
    /// All at once rather than one after another. The files are small -- a
    /// three-minute song is about eleven megabytes across seven of them --
    /// but each request costs several seconds of its own regardless of size,
    /// so fetching them in turn spent thirty-five seconds waiting and almost
    /// none of it transferring. Together they take about as long as the
    /// slowest one.
    func download(slug: String, stems: [Stem]) async throws -> [String: URL] {
        guard let baseURL else { throw ClientError.notConnected }
        let directory = localDirectory(for: slug)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        let targets = stems.compactMap { stem -> (name: String, spatial: String)? in
            guard let spatial = stem.spatial else { return nil }
            return (stem.name, spatial)
        }
        guard !targets.isEmpty else { return [:] }

        downloadProgress = 0
        var result: [String: URL] = [:]
        var finished = 0

        try await withThrowingTaskGroup(of: (String, URL).self) { group in
            for target in targets {
                let destination = directory.appendingPathComponent("\(target.name).m4a")
                let remote = baseURL.appendingPathComponent("files/\(slug)/\(target.spatial)")
                let request = self.request(remote)

                group.addTask {
                    // Already here from a previous, possibly interrupted, run.
                    if FileManager.default.fileExists(atPath: destination.path) {
                        return (target.name, destination)
                    }
                    let (temp, response) = try await URLSession.shared.download(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw ClientError.badResponse(http.statusCode)
                    }
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temp, to: destination)
                    return (target.name, destination)
                }
            }

            for try await (name, url) in group {
                result[name] = url
                finished += 1
                downloadProgress = Double(finished) / Double(targets.count)
            }
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
        let destination: String
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
        tracks: [PlaylistTrack],
        format: String = "flac",
        requireConfident: Bool = true,
        destination: String = "mac"
    ) async throws -> BatchReply {
        try await post(
            "api/batch",
            body: BatchBody(
                tracks: tracks, audio_format: format,
                require_confident: requireConfident, destination: destination
            )
        )
    }

    struct LinkBody: Encodable {
        let url: String
        let audio_format: String
        let destination: String
    }
    struct JobReply: Decodable { let id: String }

    /// A pasted link becomes a one-song batch, so progress and match
    /// confirmation look the same however the song was chosen. The single-job
    /// endpoint returns a job rather than a batch, so it is tagged and unpacked
    /// again in `batch(id:)`.
    func separate(
        link: String, format: String = "flac", destination: String = "mac"
    ) async throws -> String {
        let reply: JobReply = try await post(
            "api/jobs",
            body: LinkBody(url: link, audio_format: format, destination: destination)
        )
        return "job:" + reply.id
    }

    func batch(id: String) async throws -> [JobStatus] {
        if id.hasPrefix("job:") {
            guard let baseURL else { throw ClientError.notConnected }
            let jobID = String(id.dropFirst(4))
            let (data, _) = try await URLSession.shared.data(
                for: request(baseURL.appendingPathComponent("api/jobs/\(jobID)"))
            )
            return [try JSONDecoder().decode(JobStatus.self, from: data)]
        }
        return try await batchList(id: id)
    }

    private func batchList(id: String) async throws -> [JobStatus] {
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

// MARK: - Uploading audio the app fetched itself

extension StemsClient {
    /// Send downloaded audio to the server, which separates it without ever
    /// touching YouTube.
    func upload(
        file: URL,
        title: String,
        uploader: String = "",
        videoID: String = "",
        pageURL: String = "",
        format: String = "flac",
        destination: String = "cloud",
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> String {
        guard let baseURL else { throw ClientError.notConnected }

        let boundary = "musiclab.\(UUID().uuidString)"
        var request = self.request(baseURL.appendingPathComponent("api/upload"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        // Written to a file rather than held in memory: an hour-long upload
        // would otherwise be an hour-long allocation.
        let body = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(boundary).body")
        FileManager.default.createFile(atPath: body.path, contents: nil)
        let handle = try FileHandle(forWritingTo: body)

        func field(_ name: String, _ value: String) throws {
            try handle.write(contentsOf: Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8
            ))
        }
        try field("title", title)
        try field("uploader", uploader)
        try field("duration", "0")          // the server measures it from the audio
        try field("url", pageURL)
        try field("video_id", videoID)
        try field("audio_format", format)
        try field("destination", destination)

        let filename = "audio.\(file.pathExtension.isEmpty ? "m4a" : file.pathExtension)"
        let fileHeader = "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n"
        try handle.write(contentsOf: Data(fileHeader.utf8))
        let source = try FileHandle(forReadingFrom: file)
        while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }
        try source.close()
        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: body) }

        progress(0.05)
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: body)
        progress(1)

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.badResponse(0)
        }
        if http.statusCode != 200 {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"]
            throw NSError(domain: "Musiclab", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: detail ?? "The upload was rejected.",
            ])
        }
        return "job:" + (try JSONDecoder().decode(JobReply.self, from: data)).id
    }
}
