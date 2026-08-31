import SwiftUI

/// What the menu bar opens: the light, what it is doing, and how far along.
struct WorkerPanel: View {
    @Bindable var reader: StatusReader
    @Bindable var worker: WorkerProcess

    @State private var showingSetup = false

    private var status: WorkerStatus { reader.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if status.state == .stopped && WorkerProcess.loadConfiguration() == nil {
                notSetUp
            } else {
                activity
            }

            Divider()
            controls
        }
        .padding(16)
        .frame(width: 320)
        .task {
            reader.start()
            if WorkerProcess.loadConfiguration() != nil { worker.start() }
        }
        .sheet(isPresented: $showingSetup) {
            SetupView { worker.start() }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(light)
                .frame(width: 12, height: 12)
                // A busy light pulses, so it reads as activity at a glance
                // rather than looking like a stuck red dot.
                .opacity(status.isBusy ? 0.55 : 1)
                .animation(
                    status.isBusy
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .default,
                    value: status.isBusy
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).font(.headline)
                if !status.worker.isEmpty {
                    Text(status.worker).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !status.song.isEmpty {
                Text(status.song)
                    .font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }

            Text(status.phase.isEmpty ? " " : status.phase)
                .font(.subheadline).foregroundStyle(.secondary)

            if status.isBusy {
                // Determinate where a fraction is known, indeterminate where
                // it is not, rather than inventing a number.
                if let fraction = status.progress {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }

            if !status.detail.isEmpty {
                Text(status.detail).font(.caption).foregroundStyle(.secondary)
            }
            if !status.error.isEmpty {
                Text(status.error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            if status.songsDone > 0 {
                Text("^[\(status.songsDone) song](inflect: true) separated this session")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var notSetUp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This Mac is not signed in yet.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Set up…") { showingSetup = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var controls: some View {
        HStack {
            if WorkerProcess.loadConfiguration() != nil {
                Button(worker.isRunning ? "Pause" : "Resume") {
                    worker.isRunning ? worker.stop() : worker.start()
                }
                Button("Sign out") {
                    worker.stop()
                    Keychain.clear()
                    try? FileManager.default.removeItem(at: WorkerProcess.configURL)
                }
            }
            Spacer()
            Button("Quit") {
                worker.stop()
                NSApplication.shared.terminate(nil)
            }
        }
        .font(.callout)
    }

    // MARK: - Presentation

    private var light: Color {
        switch status.state {
        case .idle: return .green
        case .working, .downloadingModels: return .red
        case .error: return .orange
        default: return .secondary
        }
    }

    private var headline: String {
        switch status.state {
        case .idle: return "Idle"
        case .working: return "Working"
        case .downloadingModels: return "Getting ready"
        case .error: return "Problem"
        case .starting: return "Starting"
        case .stopped: return worker.isRunning ? "Starting" : "Not running"
        }
    }
}
