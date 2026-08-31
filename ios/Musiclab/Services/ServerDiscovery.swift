import Foundation
import Network
import Observation

/// Finds the Mac running the separation server, so nobody has to type an IP.
///
/// NWBrowser hands back service endpoints rather than addresses, so each result
/// is resolved by opening a connection and reading back the path it settled on.
@Observable
final class ServerDiscovery {
    struct Found: Identifiable, Hashable {
        let name: String
        let url: URL
        var id: String { url.absoluteString }
    }

    private var browser: NWBrowser?
    private var resolving: [String: NWConnection] = [:]

    private(set) var servers: [Found] = []
    private(set) var isSearching = false

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false

        let browser = NWBrowser(
            for: .bonjour(type: "_stems._tcp", domain: nil), using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                self?.resolve(result)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.isSearching = true
            case .failed, .cancelled: self?.isSearching = false
            default: break
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolving.values.forEach { $0.cancel() }
        resolving.removeAll()
        isSearching = false
    }

    private func resolve(_ result: NWBrowser.Result) {
        guard case let .service(name, _, _, _) = result.endpoint else { return }
        guard resolving[name] == nil else { return }

        let connection = NWConnection(to: result.endpoint, using: .tcp)
        resolving[name] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let endpoint = connection.currentPath?.remoteEndpoint,
                   case let .hostPort(host, port) = endpoint {
                    self.add(name: name, host: host, port: port)
                }
                connection.cancel()
                self.resolving[name] = nil
            case .failed, .cancelled:
                self.resolving[name] = nil
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func add(name: String, host: NWEndpoint.Host, port: NWEndpoint.Port) {
        // Strip the IPv6 scope suffix ("fe80::1%en0") that will not parse in a URL.
        var text = "\(host)"
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        let bracketed = text.contains(":") ? "[\(text)]" : text
        guard let url = URL(string: "http://\(bracketed):\(port.rawValue)") else { return }

        let found = Found(name: name, url: url)
        if !servers.contains(where: { $0.url == found.url }) {
            servers.append(found)
        }
    }
}
