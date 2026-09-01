import Foundation
import Observation

/// The worker's state, as it last wrote it.
///
/// Read from a file rather than a socket: the worker and this app start and
/// stop independently, and a file is still there to read when one of them was
/// not running.
struct WorkerStatus: Codable, Equatable {
    enum State: String, Codable {
        case starting, idle, working, downloadingModels = "downloading_models"
        case error, stopped
    }

    var state: State = .stopped
    var phase: String = ""
    var detail: String = ""
    var progress: Double?
    var song: String = ""
    var worker: String = ""
    var server: String = ""
    var songsDone: Int = 0
    var error: String = ""
    var updated: Double = 0

    enum CodingKeys: String, CodingKey {
        case state, phase, detail, progress, song, worker, server, error, updated
        case songsDone = "songs_done"
    }

    /// The worker writes on every change; if nothing has arrived for a while
    /// the process is gone, whatever the file last claimed.
    var isStale: Bool {
        Date().timeIntervalSince1970 - updated > 90
    }

    var isBusy: Bool { state == .working || state == .downloadingModels }
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
        if decoded.isStale { decoded.state = .stopped; decoded.phase = "Not running" }
        status = decoded
    }
}
