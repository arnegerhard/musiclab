import SwiftUI

@main
struct MusiclabApp: App {
    @State private var client = StemsClient()
    @State private var discovery = ServerDiscovery()
    @State private var account: Account
    @State private var apple = AppleMusicSource()
    @State private var spotify = SpotifySource()
    @State private var queue = JobQueue()
    @State private var basket = Basket()
    // Playback outlives the player screen: leaving it should not stop
    // the music any more than leaving Music.app does.
    @State private var engine = SpatialEngine()
    @State private var head = HeadTracker()

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
                .environment(apple)
                .environment(spotify)
                .environment(queue)
                .environment(basket)
                .environment(engine)
                .environment(head)
                .onAppear {
                    // Keep the room anchored while the player is closed.
                    head.onUpdate = { yaw, pitch, roll in
                        engine.updateListener(yaw: yaw, pitch: pitch, roll: roll)
                    }
                }
                .preferredColorScheme(.dark)
        }
    }
}
