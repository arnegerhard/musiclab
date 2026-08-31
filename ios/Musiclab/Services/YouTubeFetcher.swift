import Foundation
import YouTubeKit

/// Downloads a video's audio on the phone.
///
/// The server used to do this, until it moved to a datacenter and YouTube
/// began answering it with "sign in to confirm you're not a bot". A phone on a
/// home or carrier address is not challenged, so the fetching happens here and
/// only the audio is sent on.
enum YouTubeFetcher {
    struct Fetched {
        let file: URL
        let title: String
        let videoID: String
        let pageURL: String
        let fileExtension: String
    }

    enum FetchError: LocalizedError {
        case notAYouTubeLink
        case noAudioStream

        var errorDescription: String? {
            switch self {
            case .notAYouTubeLink:
                return "That does not look like a YouTube link."
            case .noAudioStream:
                return "YouTube offered no audio-only stream for that video."
            }
        }
    }

    /// Pull the video id out of any of the shapes YouTube links come in.
    static func videoID(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare id, which is what is left once a link is stripped down.
        if trimmed.count == 11, trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
            return trimmed
        }
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"),
              let host = url.host()?.lowercased()
        else { return nil }

        if host.contains("youtu.be") {
            return url.pathComponents.dropFirst().first
        }
        guard host.contains("youtube.com") else { return nil }
        if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value {
            return query
        }
        // /shorts/<id>, /embed/<id>, /live/<id>
        let parts = url.pathComponents.dropFirst()
        if let marker = parts.first, ["shorts", "embed", "live", "v"].contains(marker) {
            return parts.dropFirst().first
        }
        return nil
    }

    /// Resolve the best audio-only stream and download it to a temporary file.
    static func fetch(
        link: String, progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> Fetched {
        guard let id = videoID(from: link) else { throw FetchError.notAYouTubeLink }

        let video = YouTube(videoID: id)
        let streams = try await video.streams

        // Audio-only ("adaptive") streams avoid downloading a video track that
        // would only be thrown away. Highest bitrate, since separation quality
        // follows the source.
        let audio = streams
            .filter { $0.videoCodec == nil && $0.audioCodec != nil }
            .max { ($0.averageBitrate ?? $0.bitrate ?? 0) < ($1.averageBitrate ?? $1.bitrate ?? 0) }

        guard let stream = audio ?? streams.first(where: { $0.includesAudioTrack }) else {
            throw FetchError.noAudioStream
        }

        let title = (try? await video.metadata)??.title ?? "Unknown title"
        let file = try await download(stream.url, progress: progress)

        return Fetched(
            file: file,
            title: title,
            videoID: id,
            pageURL: "https://www.youtube.com/watch?v=\(id)",
            fileExtension: stream.fileExtension.rawValue
        )
    }

    private static func download(
        _ url: URL, progress: @escaping (Double) -> Void
    ) async throws -> URL {
        // URLSession writes the body to a file itself. Reading the response as
        // an AsyncSequence of UInt8 instead means one await per byte, which
        // for a few megabytes is slow enough that the CDN hangs up mid-stream.
        // googlevideo hangs up on requests that do not look like a browser,
        // and wants to be asked for a range rather than a whole file.
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        request.timeoutInterval = 120

        let reporter = DownloadProgress(onProgress: progress)
        let (temporary, response) = try await URLSession.shared.download(
            for: request, delegate: reporter
        )
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "Musiclab", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "YouTube refused the audio stream (HTTP \(http.statusCode)).",
            ])
        }

        // The temporary file is removed when this call returns, so move it.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(1)
        return destination
    }
}

/// Reports download progress; `URLSession.download` gives none on its own.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Required by the protocol; the async form returns the file itself.
    }
}
