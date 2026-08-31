import SwiftUI

@main
struct MusiclabApp: App {
    @State private var client = StemsClient()
    @State private var discovery = ServerDiscovery()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(client)
                .environment(discovery)
                .preferredColorScheme(.dark)
        }
    }
}
