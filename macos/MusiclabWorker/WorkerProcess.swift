import Foundation
import Observation

/// Runs the bundled Python worker and keeps it running.
@Observable
final class WorkerProcess {
    private(set) var isRunning = false
    private(set) var lastError: String?
    /// Whether this Mac has a credential. Observed, so the panel actually
    /// redraws when it changes -- reading the file inside `body` did not,
    /// because deleting a file invalidates no SwiftUI state.
    /// A pairing is a server to talk to *and* a credential to talk with.
    ///
    /// This used to be the configuration alone, which made a Mac holding a
    /// config whose token it cannot read look paired: bootstrap called
    /// start(), start() found no token and returned, and the app sat there
    /// having neither run a worker nor offered to pair, saying nothing. That
    /// is the state an Xcode build lands in, because a keychain item written
    /// by the signed app is not readable by an ad-hoc one.
    private(set) var isPaired =
        WorkerProcess.loadConfiguration() != nil && Keychain.read() != nil

    private var process: Process?
    /// Whether the worker is meant to be running. A process that dies while
    /// this is true has crashed and should come back; one that dies while it
    /// is false was asked to stop and must stay stopped.
    ///
    /// The flag it replaces was set and cleared inside stop(), synchronously,
    /// while the termination it was guarding arrives later -- so it always
    /// read "not a deliberate stop" and Pause restarted itself after twenty
    /// seconds.
    private var wantsToRun = false

    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Musiclab")
    }

    static var configURL: URL { support.appendingPathComponent("worker.json") }
    static var logURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Musiclab/worker.log")
    }

    /// The interpreter shipped inside this bundle.
    private static var bundledPython: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/python/bin/python3.12")
    }

    /// The interpreter to run the worker with.
    ///
    /// An Xcode build has no bundled Python -- the packaging script is what
    /// puts one there -- so running from Xcode used to start no worker at
    /// all, silently, and advertise for pairing instead. MUSICLAB_PYTHON
    /// points at a checkout's own venv, which makes Run in Xcode a way to
    /// exercise a change without repackaging 1.1 GB to see it.
    static var python: URL {
        for candidate in [
            // An explicit override, for pointing at any interpreter.
            ProcessInfo.processInfo.environment["MUSICLAB_PYTHON"],
            // Filled in by Debug builds from the checkout's path; empty in a
            // packaged one, which must only ever use its own.
            Bundle.main.object(forInfoDictionaryKey: "MusiclabDevelopmentPython")
                as? String,
        ] {
            if let path = candidate, !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return bundledPython
    }

    /// Whether there is an interpreter to run at all, wherever it came from.
    static var isPackaged: Bool {
        FileManager.default.fileExists(atPath: python.path)
    }

    /// Whether the worker is borrowing a checkout's interpreter rather than
    /// one of its own. Worth saying on screen: it is the difference between
    /// testing this build and testing the one on disk.
    static var isUsingDevelopmentPython: Bool {
        python != bundledPython
    }

    struct Configuration: Codable {
        let server: String
        /// What this Mac calls itself in the owner's app.
        var label: String?
        /// Only written by builds that signed in with an email. Kept so an
        /// existing worker.json still decodes after the move to pairing.
        var email: String?
    }

    static func loadConfiguration() -> Configuration? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONDecoder().decode(Configuration.self, from: data)
    }

    static func save(configuration: Configuration) throws {
        try FileManager.default.createDirectory(
            at: support, withIntermediateDirectories: true
        )
        try JSONEncoder().encode(configuration).write(to: configURL)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        guard let config = Self.loadConfiguration() else {
            lastError = "This Mac has not been paired yet."
            return
        }
        guard let token = Keychain.read() else {
            // Not a silent return: something is wrong that a person can act
            // on, by pairing this build once.
            lastError = "This Mac is paired, but its credential cannot be "
                      + "read. Pair it again."
            isPaired = false
            return
        }

        try? FileManager.default.createDirectory(
            at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: Self.logURL.path) {
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        }

        let task = Process()
        task.executableURL = Self.python
        task.arguments = [
            "-c",
            """
            import os
            from stems.agent import Worker
            Worker(os.environ["MUSICLAB_SERVER"], os.environ["MUSICLAB_TOKEN"]).run()
            """,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["MUSICLAB_SERVER"] = config.server
        environment["MUSICLAB_TOKEN"] = token
        // Run from a directory that is not the bundle, so nothing on the
        // working directory can shadow the packaged modules.
        task.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        task.environment = environment

        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            handle.seekToEndOfFile()
            task.standardOutput = handle
            task.standardError = handle
        }

        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isRunning = false
                // The machine may have slept or the network gone away; come back.
                if self?.wantsToRun == true { self?.scheduleRestart() }
            }
        }

        do {
            try task.run()
            process = task
            isRunning = true
            wantsToRun = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Give up this Mac's credential and everything that describes the work
    /// it was doing.
    func signOut() {
        stop()
        // Hand the credential back before forgetting it. Without this the
        // session lives on for its full year, invisible to this Mac and
        // indistinguishable in the owner's list from the one that replaces
        // it -- so every sign-out and re-pair left another ghost behind.
        if let config = Self.loadConfiguration(),
           let token = Keychain.read(),
           let url = URL(string: config.server)?.appendingPathComponent("api/auth/logout") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            // Nothing waits on this: signing out must work with the server
            // unreachable. A session that outlives an offline sign-out is a
            // stale row, not a security hole -- it can still be revoked from
            // the phone.
            URLSession.shared.dataTask(with: request).resume()
        }
        Keychain.clear()
        try? FileManager.default.removeItem(at: Self.configURL)
        // The status file outlives the process that wrote it, so without this
        // the panel goes on reporting "waiting for a song" from a worker that
        // no longer exists.
        try? FileManager.default.removeItem(at: Self.statusURL)
        isPaired = false
    }

    /// Called once a pairing succeeds.
    func adoptPairing() {
        isPaired = Self.loadConfiguration() != nil
        start()
    }

    static var statusURL: URL { support.appendingPathComponent("status.json") }

    func stop() {
        wantsToRun = false
        process?.terminate()
        process = nil
        isRunning = false
    }

    private func scheduleRestart() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            // Twenty seconds is long enough for someone to have paused or
            // signed out in the meantime.
            guard self?.wantsToRun == true else { return }
            self?.start()
        }
    }
}

/// The session token, in the login keychain rather than on disk.
enum Keychain {
    private static let account = "musiclab-worker"
    private static let service = "musiclab"

    static func write(_ token: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
        SecItemDelete(base as CFDictionary)
        var insert = base
        insert[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ] as CFDictionary)
    }
}
