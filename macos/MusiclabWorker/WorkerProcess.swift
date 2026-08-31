import Foundation
import Observation

/// Runs the bundled Python worker and keeps it running.
@Observable
final class WorkerProcess {
    private(set) var isRunning = false
    private(set) var lastError: String?

    private var process: Process?
    private var restarting = false

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
    private static var python: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/venv/bin/python")
    }

    static var isPackaged: Bool {
        FileManager.default.fileExists(atPath: python.path)
    }

    struct Configuration: Codable {
        let server: String
        let email: String
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
        guard !isRunning, let config = Self.loadConfiguration(),
              let token = Keychain.read()
        else { return }

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
                if self?.restarting == false { self?.scheduleRestart() }
            }
        }

        do {
            try task.run()
            process = task
            isRunning = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        restarting = true
        process?.terminate()
        process = nil
        isRunning = false
        restarting = false
    }

    private func scheduleRestart() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
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
