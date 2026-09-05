import SwiftUI

@main
struct MusiclabWorkerApp: App {
    @State private var reader = StatusReader()
    @State private var worker = WorkerProcess()
    @State private var pairing = PairingHost()

    var body: some Scene {
        MenuBarExtra {
            WorkerPanel(reader: reader, worker: worker, pairing: pairing)
        } label: {
            // The menu bar carries the light: green idle, red busy, grey off.
            Image(systemName: symbol)
                .renderingMode(.template)
                // Everything starts from here rather than from the panel.
                // MenuBarExtra builds its panel the first time it is opened,
                // so anything started there waits for a click -- which for an
                // unpaired Mac means it never offers itself, and for a paired
                // one means it does no work until somebody looks at it.
                .task { bootstrap() }
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor
    private func bootstrap() {
        reader.start()
        WorkerProcess.note(
            "bootstrap: packaged=\(WorkerProcess.isPackaged) "
            + "paired=\(worker.isPaired)"
        )
        if WorkerProcess.isPackaged, worker.isPaired {
            worker.start()
        } else {
            pairing.start {
                worker.adoptPairing()
                pairing.stop()
            }
        }
    }

    /// The one glance a menu bar affords: filled while working, hollow while
    /// waiting, marked when something needs a person.
    private var symbol: String {
        switch reader.status.state {
        case .busy, .downloadingModels: return "circle.fill"
        case .idle: return "circle"
        case .failed: return "exclamationmark.circle"
        case .starting: return "circle.dashed"
        case .offline: return "circle.dotted"
        }
    }
}
