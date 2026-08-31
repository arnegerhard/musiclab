import Foundation
import Observation

/// How this build reached the device. It decides where to look for a server.
///
/// A build running from Xcode or the simulator is being developed against the
/// Mac, so it should find the Mac first. A build from TestFlight or the App
/// Store is on somebody's phone, possibly nowhere near the Mac and on a
/// network where Bonjour cannot help, so it goes straight to the public
/// hostname and never triggers a local-network permission prompt.
enum Distribution {
    case simulator, development, testFlight, appStore

    init?(name: String) {
        switch name.lowercased() {
        case "simulator": self = .simulator
        case "development": self = .development
        case "testflight": self = .testFlight
        case "appstore": self = .appStore
        default: return nil
        }
    }

    static var current: Distribution = {
        // A development build can be told to behave like a shipped one. This is
        // the only way to exercise the TestFlight / App Store routing before
        // actually shipping:
        //
        //   xcrun simctl launch <udid> info.jetsons.musiclab \
        //       --args -distribution appStore
        //
        if let forced = UserDefaults.standard.string(forKey: "distribution"),
           let value = Distribution(name: forced) {
            return value
        }
        #if targetEnvironment(simulator)
        return .simulator
        #else
        // TestFlight installs carry a sandbox receipt; App Store ones do not.
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            return .testFlight
        }
        // Only development and ad-hoc builds embed a provisioning profile.
        if Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil {
            return .development
        }
        return .appStore
        #endif
    }()

    /// Whether to look for a server on the local network before the cloud.
    var searchesLocalNetwork: Bool {
        switch self {
        case .simulator, .development: return true
        case .testFlight, .appStore: return false
        }
    }

    var label: String {
        switch self {
        case .simulator: return "Simulator"
        case .development: return "Xcode build"
        case .testFlight: return "TestFlight"
        case .appStore: return "App Store"
        }
    }
}

/// Picks a server: the Mac when it is reachable, the public host otherwise.
@Observable
final class ServerResolver {
    enum Source: Equatable {
        case local(name: String)
        case cloud
        case manual

        var label: String {
            switch self {
            case let .local(name): return name
            case .cloud: return "Cloud"
            case .manual: return "Manual"
            }
        }
    }

    /// How long to wait for a Bonjour answer before giving up on the Mac.
    private let localTimeout: Duration = .milliseconds(2500)

    private(set) var isResolving = false
    private(set) var source: Source?
    private(set) var lastError: String?

    /// Set at build time (see project.yml) so TestFlight and the App Store
    /// point at the deployed server without anybody typing an address.
    static var cloudURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "MusiclabCloudURL") as? String,
              !text.isEmpty
        else { return nil }
        return URL(string: text)
    }

    /// Local first where it makes sense, then the cloud. Returns nil only when
    /// neither answered.
    func resolve(using client: StemsClient, discovery: ServerDiscovery) async -> URL? {
        isResolving = true
        lastError = nil
        defer { isResolving = false }

        if Distribution.current.searchesLocalNetwork {
            if let found = await findLocal(using: client, discovery: discovery) {
                source = .local(name: found.name)
                return found.url
            }
        }

        if let cloud = Self.cloudURL, await client.probe(cloud) {
            source = .cloud
            return cloud
        }

        lastError = Self.cloudURL == nil
            ? "No server found, and no cloud address is configured for this build."
            : "No server answered — not on this network, and the cloud host did not reply."
        return nil
    }

    /// Browse for a moment, then probe whatever turned up.
    private func findLocal(
        using client: StemsClient, discovery: ServerDiscovery
    ) async -> ServerDiscovery.Found? {
        discovery.start()
        defer { discovery.stop() }

        let deadline = ContinuousClock.now + localTimeout
        var probed: Set<URL> = []
        while ContinuousClock.now < deadline {
            for candidate in discovery.servers where !probed.contains(candidate.url) {
                probed.insert(candidate.url)
                if await client.probe(candidate.url) { return candidate }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }
}
