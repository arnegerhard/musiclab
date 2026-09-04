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

            machinesSection
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

    /// Every Mac, whether or not it is switched on. This is the answer to
    /// "why is nothing happening": a queue with no live machine behind it is
    /// not slow, it is stuck, and that used to be invisible from here.
    @ViewBuilder
    private var machinesSection: some View {
        Section {
            if queue.machines.isEmpty {
                Button { pairing = true } label: {
                    Label("Pair a Mac", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
            ForEach(queue.machines) { machine in
                machineRow(machine)
            }
        } header: {
            Text("Macs")
        } footer: {
            Text(queue.hasLiveMachine
                 ? "A link, Apple Music or Spotify needs one of these running."
                 : "Nothing is running. Songs needing a Mac will wait here "
                   + "until one is.")
        }
    }

    private func machineRow(_ machine: Machine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(machine.indicator)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.name).font(.callout).lineLimit(1)
                    Text(machine.headline)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if machine.state == .busy, let stage = machine.stage {
                    Image(systemName: stage.symbol)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if machine.state == .busy || machine.state == .downloadingModels {
                if machine.showsDeterminateBar, let fraction = machine.progress {
                    ProgressView(value: min(1, max(0, fraction)))
                        .progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if let song = machine.song, !song.isEmpty {
                    Text(song).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Red for stopped, grey for not started, tint for under way. Written out
    /// rather than nested in the view: a ternary chain of three Color-ish
    /// literals is more than the type checker will sit through.
    private func stageColour(_ job: JobStatus) -> Color {
        if job.isFailed { return .red }
        if job.isWaiting { return .secondary }
        return .accentColor
    }

    private var needsReview: [JobStatus] { queue.jobs.filter(\.needsConfirmation) }
    private var running: [JobStatus] { queue.jobs.filter { !$0.needsConfirmation } }

    private func row(_ job: JobStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // The stage says which of these a song is at, so the icon can
                // be the step rather than a spinner that means "something".
                if let stage = job.stage {
                    Image(systemName: stage.symbol)
                        .foregroundStyle(stageColour(job))
                        .frame(width: 20)
                } else {
                    ProgressView().controlSize(.small).frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title ?? "Unknown").font(.callout).lineLimit(1)
                    Text(job.headline)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            // A bar for work in progress, and none for work that has not
            // started: a stalled bar at zero says the opposite of "waiting".
            if !job.isFailed && !job.isWaiting && job.stage != .done {
                if job.showsDeterminateBar, let fraction = job.progress {
                    ProgressView(value: min(1, max(0, fraction)))
                        .progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }

            HStack {
                if let worker = job.workerName, !worker.isEmpty {
                    Label(worker, systemImage: "desktopcomputer")
                } else if job.isWaiting {
                    Text(job.stage == .waitingForWorker
                         ? "No Mac has picked this up yet" : "Queued")
                }
                Spacer()
                if job.showsDeterminateBar, let fraction = job.progress {
                    Text("\(Int(fraction * 100))%").monospacedDigit()
                }
            }
            .font(.caption2).foregroundStyle(.tertiary)

            // The one failure a person can do something about says what.
            if let failure = job.failure {
                Text(failure.remedy)
                    .font(.caption)
                    .foregroundStyle(failure.isFixable ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let detail = job.detail, !detail.isEmpty, !job.isFailed {
                Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    /// Anything already separated is kept; this only takes the job out of
    /// the list. It is also the only way to clear one whose worker died
    /// holding it, since nothing reclaims a stale claim.
    private func cancel(_ targets: [JobStatus]) async {
        for job in targets {
            let url = client.baseURL
                .appendingPathComponent("api/jobs/\(job.id)")
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
