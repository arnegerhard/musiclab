import Foundation
import Observation

/// The worker's state, as it last wrote it.
///
/// Read from a file rather than a socket: the worker and this app start and
/// stop independently, and a file is still there to read when one of them was
/// not running.
struct WorkerStatus: Codable, Equatable {
    /// What this machine is. The cases live in States.swift, shared with the
    /// phone and mirroring stems/states.py, so "busy" cannot mean one thing
    /// here and another there.
    var state: WorkerState = .offline
    /// What the song it holds is, when it holds one.
    var stage: Stage?
    var phase: String = ""
    var detail: String = ""
    var progress: Double?
    var song: String = ""
    var worker: String = ""
    var server: String = ""
    var songsDone: Int = 0
    var failure: Failure?
    var error: String = ""
    var updated: Double = 0

    enum CodingKeys: String, CodingKey {
        case state, stage, phase, detail, progress, song, worker, server
        case failure, error, updated
        case songsDone = "songs_done"
    }

    /// The worker writes on every change; if nothing has arrived for a while
    /// the process is gone, whatever the file last claimed.
    var isStale: Bool {
        Date().timeIntervalSince1970 - updated > 90
    }

    var isBusy: Bool { state == .busy || state == .downloadingModels }

    /// What to put under the title. The stage knows the words for every step,
    /// so this only has to choose which of them applies.
    var headline: String {
        if let failure { return failure.label }
        if state == .busy, let stage { return stage.label }
        return state.label
    }

    /// Whether to draw a filling bar or a moving one. A determinate stage
    /// with no fraction yet is still indeterminate -- the number has not
    /// arrived, and drawing zero would say the work has not started.
    var showsDeterminateBar: Bool {
        guard progress != nil else { return false }
        if let stage { return stage.determinate }
        // Fetching the models is the one bar with no song behind it, and it
        // is the one that most needs a real number: it is a gigabyte.
        return state == .downloadingModels
    }
}

@Observable
final class StatusReader {
    private(set) var status = WorkerStatus()
    private var timer: Timer?

    static var statusURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Musiclab/status.json")
    }

    func start() {
        read()
        // Polling rather than watching the file: the worker replaces it by
        // rename, which a file-descriptor watch stops seeing after the first
        // swap.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.read()
        }
        // .common, not the default mode. An open menu bar panel puts the run
        // loop into event tracking, where a default-mode timer does not fire
        // -- so the one moment this needs to be up to date is precisely the
        // moment it would stop refreshing, leaving whatever it read at launch
        // frozen on screen.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Read now, without waiting for the next tick.
    func refresh() { read() }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func read() {
        guard let data = try? Data(contentsOf: Self.statusURL),
              var decoded = try? JSONDecoder().decode(WorkerStatus.self, from: data)
        else {
            status = WorkerStatus()
            return
        }
        // A file that has not been touched in a minute and a half describes a
        // process that is gone. Showing its last phase would leave "Separating"
        // on screen forever.
        if decoded.isStale {
            decoded.state = .offline
            decoded.stage = nil
            decoded.progress = nil
            decoded.phase = WorkerState.offline.label
        }
        status = decoded
    }
}
