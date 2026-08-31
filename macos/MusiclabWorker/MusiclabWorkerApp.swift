import SwiftUI

@main
struct MusiclabWorkerApp: App {
    @State private var reader = StatusReader()
    @State private var worker = WorkerProcess()

    var body: some Scene {
        MenuBarExtra {
            WorkerPanel(reader: reader, worker: worker)
        } label: {
            // The menu bar carries the light: green idle, red busy, grey off.
            Image(systemName: symbol)
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.window)
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
