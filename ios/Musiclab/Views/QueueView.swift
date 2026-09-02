import SwiftUI

/// Songs being separated, and which machine has each one.
struct QueueView: View {
    @Environment(JobQueue.self) private var queue
    @Environment(StemsClient.self) private var client

    @State private var reviewing: JobStatus?
    @State private var pairing = false

    var body: some View {
        List {
            if queue.jobs.isEmpty {
                ContentUnavailableView(
                    "Nothing in the queue",
                    systemImage: "checkmark.circle",
                    description: Text("Songs you add appear here until they are separated.")
                )
                .listRowBackground(Color.clear)
            }

            if !needsReview.isEmpty {
                Section("Needs your call") {
                    ForEach(needsReview) { job in
                        Button { reviewing = job } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(job.title ?? "Unknown").font(.callout)
                                Text("Not sure which recording — tap to choose")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }

            if !running.isEmpty {
                Section("Being separated") {
                    ForEach(running) { job in row(job) }
                        .onDelete { offsets in
                            Task { await cancel(offsets.map { running[$0] }) }
                        }
                }
            }
        }
        .navigationTitle("Queue")
        // The machines that do this work belong beside the work, not in the
        // menu about signing in and out.
        .toolbar {
            Button {
                pairing = true
            } label: {
                Label("Macs", systemImage: "desktopcomputer")
            }
        }
        .sheet(isPresented: $pairing) { PairMacView() }
        .sheet(item: $reviewing) { job in
            MatchReviewView(job: job) { candidate in
                Task {
                    _ = try? await client.confirm(job: job.id, videoId: candidate.videoId)
                    await queue.refresh()
                }
            }
        }
        .refreshable { await queue.refresh() }
    }

    private var needsReview: [JobStatus] { queue.jobs.filter(\.needsConfirmation) }
    private var running: [JobStatus] { queue.jobs.filter { !$0.needsConfirmation } }

    private func row(_ job: JobStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if job.isFailed {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                } else {
                    ProgressView().controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title ?? "Unknown").font(.callout).lineLimit(1)
                    Text(detail(job))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            // The same bar the Mac is showing.
            if let fraction = job.progress, !job.isFailed {
                ProgressView(value: min(1, max(0, fraction)))
                    .progressViewStyle(.linear)
                HStack {
                    if let worker = job.workerName, !worker.isEmpty {
                        Label(worker, systemImage: "desktopcomputer")
                    } else {
                        Text("Waiting for a machine")
                    }
                    Spacer()
                    Text("\(Int(fraction * 100))%").monospacedDigit()
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Anything already separated is kept; this only takes the job out of
    /// the list. It is also the only way to clear one whose worker died
    /// holding it, since nothing reclaims a stale claim.
    private func cancel(_ targets: [JobStatus]) async {
        for job in targets {
            guard let url = client.baseURL?
                .appendingPathComponent("api/jobs/\(job.id)") else { continue }
            var request = client.request(url)
            request.httpMethod = "DELETE"
            _ = try? await URLSession.shared.data(for: request)
        }
        await queue.refresh()
    }

    private func detail(_ job: JobStatus) -> String {
        if job.isFailed { return job.error ?? "Failed" }
        if let step = job.detail, !step.isEmpty { return "\(job.phase) — \(step)" }
        return job.phase
    }
}
