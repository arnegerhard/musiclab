import SwiftUI

/// Progress for a queued playlist selection, and where uncertain matches get
/// settled by a human before ten minutes are spent on the wrong song.
struct BatchView: View {
    let batchID: String

    @Environment(StemsClient.self) private var client
    @State private var jobs: [JobStatus] = []
    @State private var reviewing: JobStatus?

    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
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

            Section("\(done.count) of \(jobs.count) done") {
                ForEach(jobs) { job in
                    HStack(spacing: 10) {
                        icon(for: job)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.title ?? "Unknown").font(.callout).lineLimit(1)
                            Text(detail(for: job))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
        .navigationTitle("Separating")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $reviewing) { job in
            MatchReviewView(job: job) { candidate in
                Task {
                    try? await client.confirm(job: job.id, videoId: candidate.videoId)
                    await reload()
                }
            }
        }
        .onReceive(ticker) { _ in Task { await reload() } }
        .task { await reload() }
    }

    private var needsReview: [JobStatus] { jobs.filter(\.needsConfirmation) }
    private var done: [JobStatus] { jobs.filter(\.isFinished) }

    private func icon(for job: JobStatus) -> some View {
        Group {
            if job.isFinished {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if job.isFailed {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            } else if job.needsConfirmation {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
            } else if job.status == "running" {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "clock").foregroundStyle(.secondary)
            }
        }
        .frame(width: 22)
    }

    private func detail(for job: JobStatus) -> String {
        if job.isFailed { return job.error ?? "Failed" }
        if job.isFinished, let match = job.match { return "Matched \(match.channel)" }
        return job.phase
    }

    private func reload() async {
        if let updated = try? await client.batch(id: batchID) { jobs = updated }
    }
}

/// The candidate list for a track the matcher was not confident about.
struct MatchReviewView: View {
    let job: JobStatus
    let onPick: (MatchCandidate) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Which recording is \(job.title ?? "this")?")
                        .font(.callout)
                } footer: {
                    Text("The duration is the best clue: a cover or a live cut is "
                         + "rarely within a couple of seconds of the album version.")
                }

                ForEach(job.candidates ?? []) { candidate in
                    Button {
                        onPick(candidate)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.title).font(.callout).lineLimit(2)
                            HStack(spacing: 6) {
                                Text(candidate.channel)
                                if let duration = candidate.duration {
                                    Text("· \(Int(duration) / 60):\(String(format: "%02d", Int(duration) % 60))")
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            if !candidate.reasons.isEmpty {
                                Text(candidate.reasons.joined(separator: ", "))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pick the recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                }
            }
        }
    }
}
