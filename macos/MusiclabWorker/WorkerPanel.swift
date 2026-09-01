import SwiftUI

/// What the menu bar opens: the light, what it is doing, and how far along.
struct WorkerPanel: View {
    @Bindable var reader: StatusReader
    @Bindable var worker: WorkerProcess
    @Bindable var pairing: PairingHost


    private var status: WorkerStatus { reader.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let asking = pairing.request {
                consent(to: asking)
            } else if !WorkerProcess.isPackaged {
                noEngine
            } else if !worker.isPaired {
                notSetUp
            } else {
                activity
            }

            if let failure = worker.lastError {
                Text(failure)
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            controls
        }
        .padding(16)
        .frame(width: 320)

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

    /// Running straight from Xcode gives the Swift app without the Python that
    /// does the work: the separation engine is injected by
    /// packaging/build_worker_app.sh, not by the Xcode target. Everything here
    /// would otherwise look normal while nothing could ever run.
    private var noEngine: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No separation engine in this build.")
                .font(.callout).foregroundStyle(.orange)
            Text("This is the interface on its own. Build the full app with "
                 + "packaging/build_worker_app.sh and open it from dist/.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notSetUp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This Mac is not paired yet.")
                .font(.callout).foregroundStyle(.secondary)
            Text(pairing.isAdvertising
                 ? "Open Musiclab on your phone, on this network, and it will "
                   + "offer to pair. You will be asked here too."
                 : "Waiting for the local network…")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure = pairing.lastError {
                Text(failure).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Half of the agreement. The phone is showing the same six digits and
    /// waiting for its own answer; neither side proceeds alone.
    private func consent(to request: PairingHost.Request) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(request.device) wants to pair")
                .font(.callout).fontWeight(.medium)
            Text(request.verification)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity)
            Text("Allow only if your phone is showing these same six digits.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Don't allow") { pairing.answer(false) }
                Spacer()
                Button("Allow") { pairing.answer(true) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Only an unpaired Mac announces itself, and it stops the moment it is
    /// spoken for.
    private func offerThisMac() {
        pairing.start {
            worker.adoptPairing()
            pairing.stop()
        }
    }

    private var controls: some View {
        HStack {
            if WorkerProcess.isPackaged, worker.isPaired {
                Button(worker.isRunning ? "Pause" : "Resume") {
                    worker.isRunning ? worker.stop() : worker.start()
                }
                Button("Sign out") {
                    worker.signOut()
                    offerThisMac()
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
