import Foundation
import Observation

/// Everything this account is waiting on, wherever it is being worked.
///
/// Shared rather than owned by one screen: the tab bar shows how many are
/// outstanding, and a song submitted from the Add screen has to keep being
/// watched after that screen has been left.
@Observable
@MainActor
final class JobQueue {
    private(set) var jobs: [JobStatus] = []
    /// Every Mac this account has adopted, and what each is doing. Polled
    /// alongside the jobs because they are two halves of one question: what
    /// is happening, and what is able to happen.
    private(set) var machines: [Machine] = []
    /// Whether the machine list has ever been answered. An empty list before
    /// the first reply means "not asked yet", which is a different thing from
    /// "no Macs" and must not be shown as one.
    private(set) var hasLoadedMachines = false
    /// Whether the server has confirmed the machine list during this launch.
    ///
    /// The names and specifications come back from disk instantly, which is
    /// what makes the Add screen know there is a Mac without waiting -- but
    /// what a Mac was *doing* when the app last closed is not news, it is a
    /// guess about the present. Screens that show state dim it until this
    /// turns true, rather than asserting a Mac is idle when it may be off.
    private(set) var machinesAreLive = false
    private(set) var lastError: String?

    /// What the tab badge counts.
    var count: Int { jobs.count }

    private var client: StemsClient?
    private var task: Task<Void, Never>?
    private var account = ""
    private var machinesEtag = ""

    private static let key = "machines"

    /// The account is needed before the cache can be read: it is filed per
    /// account, so one person's Macs are never shown to another.
    func adopt(account: String) {
        guard account != self.account else { return }
        self.account = account
        machines = []
        machinesEtag = ""
        machinesAreLive = false
        hasLoadedMachines = false
        if let stored = Cache.read(Self.key, account: account, as: [Machine].self) {
            machines = stored.value
            machinesEtag = stored.etag
            hasLoadedMachines = true
        }
    }

    func forget() {
        Cache.forget(account: account)
        account = ""
        machines = []
        jobs = []
        machinesEtag = ""
        machinesAreLive = false
        hasLoadedMachines = false
    }

    func begin(with client: StemsClient) {
        self.client = client
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                // Separation runs for minutes; this only has to be quick
                // enough that a finished song does not linger.
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func refresh() async {
        guard let client, !client.token.isEmpty else { return }
        await refreshJobs(client)
        await refreshMachines(client)
    }

    private func refreshJobs(_ client: StemsClient) async {
        let url = client.baseURL.appendingPathComponent("api/jobs")
        do {
            let (data, response) = try await URLSession.shared.data(for: client.request(url))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            jobs = try JSONDecoder().decode([JobStatus].self, from: data)
            lastError = nil
        } catch {
            // A dropped poll says nothing; the next one is three seconds away.
            lastError = nil
        }
    }

    private func refreshMachines(_ client: StemsClient) async {
        var request = client.request(
            client.baseURL.appendingPathComponent("api/workers")
        )
        // Polled every three seconds, and an idle Mac says the same thing
        // every time. The server compares this and answers 304 rather than
        // sending the list again.
        if !machinesEtag.isEmpty {
            request.setValue(machinesEtag, forHTTPHeaderField: "If-None-Match")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return }
        if http.statusCode == 304 {
            // Unchanged is still an answer: what is held is now confirmed.
            machinesAreLive = true
            hasLoadedMachines = true
            return
        }
        guard http.statusCode == 200,
              let decoded = try? JSONDecoder().decode([Machine].self, from: data)
        else { return }
        machines = decoded
        machinesEtag = http.value(forHTTPHeaderField: "ETag") ?? ""
        machinesAreLive = true
        hasLoadedMachines = true
        Cache.write(decoded, etag: machinesEtag, key: Self.key, account: account)
    }

    /// Whether anything could pick up a song needing a Mac right now.
    ///
    /// "Right now" is the whole of it, so a remembered state does not count:
    /// a Mac that was idle when the app last closed says nothing about
    /// whether it is switched on.
    var hasLiveMachine: Bool {
        machinesAreLive && machines.contains { $0.state.isAvailable }
    }
}
