import SwiftUI

@main
struct MusiclabApp: App {
    @State private var client = StemsClient()
    @State private var discovery = ServerDiscovery()
    @State private var account: Account

    init() {
        let client = StemsClient()
        _client = State(initialValue: client)
        _account = State(initialValue: Account(client: client))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(client)
                .environment(discovery)
                .environment(account)
                .preferredColorScheme(.dark)
        }
    }
}
