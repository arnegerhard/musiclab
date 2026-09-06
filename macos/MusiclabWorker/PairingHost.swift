import CryptoKit
import Foundation
import IOKit
import Network
import Observation

/// Offers this Mac to Musiclab on the local network, and waits to be asked.
///
/// Replaces a typed code. Nothing here trusts the network on its own: a phone
/// that finds this Mac cannot pair with it until a person clicks Allow, and
/// what finally crosses the wire is a single-use pairing code, not a
/// credential. The Mac redeems that code against the deployment over HTTPS, so
/// anything overheard on the network is already spent by the time it is heard.
@Observable
@MainActor
final class PairingHost {
    /// A phone that has connected and is asking. Nil when nobody is asking.
    struct Request: Identifiable {
        let id = UUID()
        let device: String
        /// Six digits derived from both sides' random numbers, so neither
        /// chooses it alone. Shown on both screens: matching numbers mean the
        /// two devices are talking to each other and not to something in
        /// between.
        let verification: String
    }

    private(set) var isAdvertising = false
    private(set) var request: Request?
    private(set) var lastError: String?

    private var listener: NWListener?
    private var connection: NWConnection?
    private var pending: (@Sendable (Bool) -> Void)?
    private var onPaired: (() -> Void)?

    static let serviceType = "_musiclab-pair._tcp"

    func start(onPaired: @escaping () -> Void) {
        guard listener == nil else { return }
        self.onPaired = onPaired
        do {
            let listener = try NWListener(using: .tcp)
            // The machine id rides along so a phone can recognise a Mac it
            // has already adopted, even when the network is still repeating
            // an advertisement this Mac has withdrawn.
            listener.service = NWListener.Service(
                name: Host.current().localizedName ?? "A Mac",
                type: Self.serviceType,
                txtRecord: NWTXTRecord(
                    ["machine": Self.machineID].merging(
                        Hardware.advertised, uniquingKeysWith: { a, _ in a }
                    )
                ).data
            )
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.isAdvertising = true
                    case let .failed(error):
                        self?.isAdvertising = false
                        self?.lastError = error.localizedDescription
                    case .cancelled: self?.isAdvertising = false
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        request = nil
        isAdvertising = false
    }

    // MARK: - The conversation

    private func accept(_ incoming: NWConnection) {
        // One at a time. A second phone asking while someone is deciding would
        // make the two prompts impossible to tell apart.
        guard connection == nil else { incoming.cancel(); return }
        connection = incoming
        incoming.start(queue: .main)
        Task { await converse(over: incoming) }
    }

    private func converse(over connection: NWConnection) async {
        defer { finish() }
        do {
            let hello = try await Line.read(from: connection)
            guard let device = hello["device"] as? String,
                  let theirs = hello["nonce"] as? String
            else { return }

            let mine = UUID().uuidString
            try await Line.write(
                ["name": Host.current().localizedName ?? "A Mac", "nonce": mine],
                to: connection
            )

            request = Request(
                device: device,
                verification: Self.verification(theirs, mine)
            )

            // Blocks here until somebody clicks. The phone is showing the same
            // number and waiting for its own answer.
            let allowed = await withCheckedContinuation { continuation in
                pending = { allow in continuation.resume(returning: allow) }
            }
            try await Line.write(["allowed": allowed], to: connection)
            guard allowed else { return }

            let handover = try await Line.read(from: connection)
            guard let code = handover["code"] as? String,
                  let server = handover["server"] as? String
            else { return }

            let token = try await claim(code: code, server: server)
            Keychain.write(token)
            try WorkerProcess.save(
                configuration: .init(server: server, label: Host.current().localizedName)
            )
            try? await Line.write(["paired": true], to: connection)
            onPaired?()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func answer(_ allow: Bool) {
        pending?(allow)
        pending = nil
        request = nil
    }

    private func finish() {
        connection?.cancel()
        connection = nil
        request = nil
        pending = nil
    }

    /// Trade the code for this machine's own token, over HTTPS to the
    /// deployment -- never over the local network.
    private func claim(code: String, server: String) async throws -> String {
        guard let url = URL(string: server)?.appendingPathComponent("api/auth/pair/claim")
        else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "code": code,
                "label": Host.current().localizedName ?? "A Mac",
                "machine": Self.machineID,
            ]
        )
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = payload["token"] as? String
        else { throw URLError(.userAuthenticationRequired) }
        return token
    }

    /// This Mac, across sign-outs.
    ///
    /// Kept in defaults rather than in the worker's configuration, which is
    /// deleted on sign out -- the whole point is to still be recognisable
    /// afterwards, so the same Mac replaces its own entry instead of adding a
    /// second one.
    static var machineID: String {
        let key = "machineID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    /// Both nonces, hashed together. Neither side can steer the result.
    ///
    /// Phone first, then Mac, on both sides -- see the note on the iOS copy.
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


/// What this Mac is, for a phone deciding whether to send it a song.
///
/// Read once and cached: a phone choosing between this Mac and a rented GPU
/// wants to know what it is choosing, and until it has paired there is no
/// other channel to tell it -- so the numbers ride in the pairing
/// advertisement's TXT record.
///
/// No clock rate. Apple Silicon does not publish one: `hw.cpufrequency` and
/// `hw.cpufrequency_max` are both empty, and `hw.tbfrequency` is the
/// timebase, not the processor. Anything shown as a clock speed here would
/// have to be made up, and the GPU core count is in any case the number that
/// decides how long a separation takes.
enum Hardware {
    /// Small enough for a TXT record, which has to stay well under a
    /// kilobyte in total.
    static let advertised: [String: String] = {
        var fields: [String: String] = [:]
        if let chip { fields["chip"] = chip }
        if let cores = gpuCores { fields["gpu_cores"] = String(cores) }
        if let gb = memoryGB { fields["memory_gb"] = String(format: "%.0f", gb) }
        return fields
    }()

    static let chip: String? = sysctlString("machdep.cpu.brand_string")

    static let memoryGB: Double? = {
        var bytes: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &bytes, &size, nil, 0) == 0, bytes > 0
        else { return nil }
        return Double(bytes) / 1_073_741_824
    }()

    /// From the graphics driver rather than from a table of chip names, so a
    /// Max or an Ultra is not quietly reported as the base part.
    static let gpuCores: Int? = {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AGXAccelerator")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(
            service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0
        )
        return (value?.takeRetainedValue() as? NSNumber)?.intValue
    }()

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(cString: buffer).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
