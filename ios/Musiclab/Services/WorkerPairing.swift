import CryptoKit
import Foundation
import Network
import Observation
import UIKit

/// Macs on this network offering to do separation work.
///
/// A Mac advertises only while it is unpaired, so anything listed here is
/// genuinely waiting to be adopted rather than already busy for somebody.
@Observable
@MainActor
final class WorkerBrowser {
    struct Found: Identifiable, Hashable {
        let id: String
        let name: String
        /// From the advertisement's TXT record. Empty for a Mac too old to
        /// send one, which simply means it cannot be filtered out.
        let machine: String
        let endpoint: NWEndpoint
    }

    /// Machines already paired to this account. A Mac stops advertising the
    /// moment it is adopted, but the network goes on repeating the withdrawn
    /// advertisement until it expires, so a Mac that is already working would
    /// otherwise sit in the list still offering to help.
    var alreadyPaired: Set<String> = [] {
        didSet { if alreadyPaired != oldValue { apply() } }
    }

    private(set) var macs: [Found] = []
    /// Everything the network is offering, before filtering.
    private var found: [Found] = []
    private var browser: NWBrowser?

    private func apply() {
        macs = found
            .filter { $0.machine.isEmpty || !alreadyPaired.contains($0.machine) }
            .sorted { $0.name < $1.name }
    }

    static let serviceType = "_musiclab-pair._tcp"

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        // WithTXTRecord, or the advertisement's metadata never arrives and
        // every Mac looks anonymous -- which is the whole basis for telling
        // an unpaired Mac from one that is already working.
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.found = results.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    var machine = ""
                    if case let .bonjour(txt) = result.metadata {
                        machine = txt["machine"] ?? ""
                    }
                    return Found(id: name, name: name, machine: machine,
                                 endpoint: result.endpoint)
                }
                self?.apply()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        found = []
        macs = []
    }
}

/// One attempt to pair with one Mac.
///
/// Neither side can do this alone: the Mac will not accept until somebody
/// clicks Allow on it, and this will not hand anything over until somebody
/// taps Pair here. The six digits shown on both are derived from random
/// numbers chosen by each, so a device in the middle cannot show both the
/// same number.
///
/// What is handed over is a single-use pairing code, never the session token.
/// The Mac redeems it against the deployment over HTTPS, so a code overheard
/// on the network is spent before anyone can use it.
@Observable
@MainActor
final class PairingSession {
    enum Step: Equatable {
        case connecting
        case confirm(String)     // six digits, waiting on this end
        case waitingForMac(String)
        case handingOver
        case paired
        case failed(String)
    }

    private(set) var step: Step = .connecting
    let macName: String

    private var connection: NWConnection?
    private var confirmed = false
    private var mintCode: () async throws -> (code: String, server: String)

    init(
        mac: WorkerBrowser.Found,
        mintCode: @escaping () async throws -> (code: String, server: String)
    ) {
        self.macName = mac.name
        self.mintCode = mintCode
        let connection = NWConnection(to: mac.endpoint, using: .tcp)
        self.connection = connection
        connection.start(queue: .main)
        Task { await handshake(over: connection) }
    }

    func confirm() {
        guard case let .confirm(number) = step else { return }
        confirmed = true
        step = .waitingForMac(number)
    }

    func cancel() {
        connection?.cancel()
        connection = nil
    }

    private func handshake(over connection: NWConnection) async {
        do {
            let mine = UUID().uuidString
            try await Line.write(
                ["device": UIDevice.current.name, "nonce": mine], to: connection
            )
            let hello = try await Line.read(from: connection)
            guard let theirs = hello["nonce"] as? String else {
                step = .failed("That Mac did not answer properly.")
                return
            }
            let number = Self.verification(mine, theirs)
            step = .confirm(number)

            // Wait for this end's tap, then for the Mac's click. Both, in
            // either order.
            while !confirmed {
                try await Task.sleep(for: .milliseconds(120))
            }
            let verdict = try await Line.read(from: connection)
            guard verdict["allowed"] as? Bool == true else {
                step = .failed("\(macName) declined.")
                return
            }

            step = .handingOver
            let minted = try await mintCode()
            try await Line.write(
                ["code": minted.code, "server": minted.server], to: connection
            )
            let done = try await Line.read(from: connection)
            step = done["paired"] as? Bool == true
                ? .paired
                : .failed("\(macName) could not complete pairing.")
        } catch {
            // NWError text is written for a network engineer. What matters
            // here is which Mac stopped answering.
            step = .failed("Lost contact with \(macName). Make sure it is "
                           + "awake and on this network.")
        }
        connection.cancel()
    }

    /// Both nonces, hashed together, exactly as the Mac computes it.
    ///
    /// The order is fixed as phone-then-Mac on both sides. Hashing them in
    /// whichever order each happens to hold gives two different numbers and a
    /// pairing that can never be confirmed.
    static func verification(_ phone: String, _ mac: String) -> String {
        let digest = SHA256.hash(data: Data((phone + mac).utf8))
        let number = digest.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", number % 1_000_000)
    }
}

/// Newline-delimited JSON, which is all this conversation needs.
enum Line {
    static func write(_ object: [String: Any], to connection: NWConnection) async throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    static func read(from connection: NWConnection) async throws -> [String: Any] {
        var buffer = Data()
        while true {
            let chunk: Data? = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
                    data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if complete && (data?.isEmpty ?? true) { continuation.resume(returning: nil) }
                    else { continuation.resume(returning: data ?? Data()) }
                }
            }
            guard let chunk else { throw URLError(.networkConnectionLost) }
            buffer.append(chunk)
            // A pairing message is small; anything huge is not one of ours.
            guard buffer.count < 64_000 else { throw URLError(.dataLengthExceedsMaximum) }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                return (try JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
            }
        }
    }
}
