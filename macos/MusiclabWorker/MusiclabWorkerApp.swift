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
        if WorkerProcess.isPackaged, worker.isPaired {
            worker.start()
        } else {
            pairing.start {
                worker.adoptPairing()
                pairing.stop()
            }
        }
    }

    private var symbol: String {
        switch reader.status.state {
        case .working, .downloadingModels: return "circle.fill"
        case .idle: return "circle"
        case .error: return "exclamationmark.circle"
        default: return "circle.dotted"
        }
    }
}
