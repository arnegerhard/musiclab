import SwiftUI

/// The candidate list for a track the matcher was not confident about, where
/// an uncertain match is settled by a human before ten minutes are spent
/// separating the wrong song.
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
