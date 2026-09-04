import Foundation

// The Swift half of stems/states.py. Both apps compile this same file, and
// the server sends these exact strings, so a state cannot mean one thing on
// the Mac and another on the phone. The raw values are the contract; the
// labels are ours to reword.

/// Where one song is, from asked-for to listenable.
enum Stage: String, Codable, CaseIterable, Sendable {
    case queued
    case waitingForWorker = "waiting_for_worker"
    case fetching
    case decoding
    case loadingModels = "loading_models"
    case separating
    case packing
    case uploading
    case needsConfirmation = "needs_confirmation"
    case done
    case failed

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .waitingForWorker: return "Waiting for a Mac"
        case .fetching: return "Downloading the audio"
        case .decoding: return "Decoding the audio"
        case .loadingModels: return "Loading the models"
        case .separating: return "Separating"
        case .packing: return "Packing the stems"
        case .uploading: return "Sending the stems back"
        case .needsConfirmation: return "Waiting for you to confirm the match"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    var isTerminal: Bool { self == .done || self == .failed }

    /// Nothing is happening yet, and nothing this end can do about it.
    var isWaiting: Bool {
        self == .queued || self == .waitingForWorker || self == .needsConfirmation
    }

    /// Whether a fraction means anything here. Where it does not, a bar has to
    /// be indeterminate: a number would be invented, and an invented number
    /// that stops moving is indistinguishable from a hang.
    var determinate: Bool {
        switch self {
        case .fetching, .loadingModels, .separating, .packing, .uploading:
            return true
        default:
            return false
        }
    }

    /// What the old vocabulary called these. Jobs queued before the rename
    /// are still in the store, and a strict decode would leave them looking
    /// like a stage this app had never heard of -- which is to say, looking
    /// like they were still running.
    static func parse(_ raw: String?) -> Stage? {
        guard let raw, !raw.isEmpty else { return nil }
        if let stage = Stage(rawValue: raw) { return stage }
        switch raw {
        case "error": return .failed
        case "awaiting_fetch": return .waitingForWorker
        case "running", "claimed": return .separating
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .queued, .waitingForWorker: return "clock"
        case .fetching: return "arrow.down.circle"
        case .decoding: return "waveform"
        case .loadingModels: return "shippingbox"
        case .separating: return "square.stack.3d.up"
        case .packing: return "archivebox"
        case .uploading: return "arrow.up.circle"
        case .needsConfirmation: return "questionmark.circle"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

/// What a machine is, as distinct from what a song is.
enum WorkerState: String, Codable, CaseIterable, Sendable {
    case offline
    case starting
    case downloadingModels = "downloading_models"
    case idle
    case busy
    case failed

    var label: String {
        switch self {
        case .offline: return "Offline"
        case .starting: return "Starting up"
        case .downloadingModels: return "Downloading the models"
        case .idle: return "Idle, waiting for a song"
        case .busy: return "Working"
        case .failed: return "Stopped after an error"
        }
    }

    /// Whether this machine could take a song right now.
    var isAvailable: Bool { self == .idle || self == .busy }
}

/// Why a song stopped, in terms that suggest what to do about it.
enum Failure: String, Codable, CaseIterable, Sendable {
    case downloaderOutdated = "downloader_outdated"
    case sourceUnavailable = "source_unavailable"
    case noMatch = "no_match"
    case fetchFailed = "fetch_failed"
    case separationFailed = "separation_failed"
    case uploadFailed = "upload_failed"
    case cancelled
    case unknown

    var label: String {
        switch self {
        case .downloaderOutdated: return "The downloader is out of date"
        case .sourceUnavailable: return "The song could not be reached"
        case .noMatch: return "No recording matched"
        case .fetchFailed: return "The download did not finish"
        case .separationFailed: return "Separating did not finish"
        case .uploadFailed: return "The stems did not arrive"
        case .cancelled: return "Cancelled"
        case .unknown: return "Something went wrong"
        }
    }

    var remedy: String {
        switch self {
        case .downloaderOutdated:
            return "YouTube changed something yt-dlp no longer understands. "
                 + "Updating the Mac app fixes it; nothing is wrong with the song."
        case .sourceUnavailable:
            return "It may be private, removed, or blocked where the Mac is."
        case .noMatch:
            return "Nothing close enough was found. Try pasting a link instead."
        case .fetchFailed:
            return "Usually the network. Queue it again."
        case .separationFailed:
            return "The audio reached the separator and it stopped. Queue it again."
        case .uploadFailed:
            return "They were made, but the handover failed. Queue it again."
        case .cancelled:
            return "You stopped this one."
        case .unknown:
            return "Queue it again."
        }
    }

    /// The only failure here that a person fixes by doing something other than
    /// trying again, which is worth saying differently.
    var isFixable: Bool { self == .downloaderOutdated }
}
