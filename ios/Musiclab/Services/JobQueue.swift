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
    private(set) var lastError: String?

    /// What the tab badge counts.
    var count: Int { jobs.count }

    private var client: StemsClient?
    private var task: Task<Void, Never>?

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
        let url = client.baseURL.appendingPathComponent("api/workers")
        guard let (data, response) = try? await URLSession.shared.data(
            for: client.request(url)
        ), (response as? HTTPURLResponse)?.statusCode == 200,
           let decoded = try? JSONDecoder().decode([Machine].self, from: data)
        else { return }
        machines = decoded
    }

    /// Whether anything could pick up a song needing a Mac right now.
    var hasLiveMachine: Bool {
        machines.contains { $0.state.isAvailable }
    }
}
