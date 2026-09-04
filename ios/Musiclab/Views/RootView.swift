import SwiftUI

struct RootView: View {
    @Environment(StemsClient.self) private var client
    @Environment(Account.self) private var account
    @Environment(JobQueue.self) private var queue
    @Environment(NowPlaying.self) private var nowPlaying
    @Environment(SpatialEngine.self) private var engine
    @State private var checkedSession = false
    @State private var showingWelcome = false

    var body: some View {
        Group {
            if !checkedSession {
                // One question, asked once: is the stored token still good?
                // There is no server to find any more, so this is the whole
                // of the app's start-up.
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Signing in…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .task {
                    await account.restore()
                    checkedSession = true
                }
            } else if !account.isSignedIn {
                NavigationStack { SignInView() }
            } else {
                // The bar is a row inside each tab, above that tab's own
                // content and below nothing but the tab bar.
                //
                // Not a safe area inset: an inset on the TabView lands under
                // the tabs and hides them, and an inset on a NavigationStack
                // is only a request that a List inside it does not honour --
                // the Add screen's buttons stayed sliced in half underneath
                // the bar. A stack row is arithmetic rather than a request.
                TabView {
                    VStack(spacing: 0) {
                        NavigationStack { LibraryView() }
                        MiniPlayerBar()
                    }
                    .tabItem { Label("Library", systemImage: "square.stack.3d.up") }

                    VStack(spacing: 0) {
                        NavigationStack { QueueView() }
                        MiniPlayerBar()
                    }
                    .tabItem { Label("Queue", systemImage: "clock.arrow.circlepath") }
                    // Only when there is something to say. A zero badge is a
                    // permanent little alarm about nothing.
                    .badge(queue.count == 0 ? 0 : queue.count)

                    VStack(spacing: 0) {
                        NavigationStack { AddSongView() }
                        MiniPlayerBar()
                    }
                    .tabItem { Label("Add", systemImage: "plus.circle.fill") }
                }
                // A sheet rather than a cover: swiping it down is the whole
                // point, and that is what a sheet does for free.
                .sheet(isPresented: Bindable(nowPlaying).isExpanded) {
                    if let entry = nowPlaying.entry {
                        NavigationStack { PlayerView(entry: entry) }
                            .presentationDetents([.large])
                            .presentationDragIndicator(.visible)
                    }
                }
                .task {
                    queue.begin(with: client)
                    nowPlaying.wireRemoteCommands(engine: engine, client: client)
                }
                // The system keeps its own clock from the rate and the
                // elapsed time, so this only has to speak when something
                // actually changes.
                .onChange(of: nowPlaying.entry?.slug) { _, _ in
                    nowPlaying.publish(engine: engine, client: client)
                }
                .onChange(of: engine.isPlaying) { _, _ in
                    nowPlaying.publish(engine: engine, client: client)
                }
                .onChange(of: engine.loadedSlug) { _, _ in
                    nowPlaying.publish(engine: engine, client: client)
                }
            }
        }
        .sheet(isPresented: $showingWelcome) {
            WelcomeView(onDone: finishWelcome)
        }
        // Signing in is the moment the account exists; before it there is no
        // one to have welcomed.
        .onChange(of: account.user?.id) { _, id in considerWelcome(id) }
    }

    /// Once per account, and only the first time. Everything that makes this
    /// app unusual -- that separating happens elsewhere, and that where is a
    /// choice -- is invisible from the library, and the Add screen offers the
    /// choice without ever explaining it.
    private func considerWelcome(_ id: String?) {
        guard let id, !UserDefaults.standard.bool(forKey: Self.welcomeKey(id))
        else { return }
        showingWelcome = true
    }

    private func finishWelcome() {
        if let id = account.user?.id {
            UserDefaults.standard.set(true, forKey: Self.welcomeKey(id))
        }
        showingWelcome = false
    }

    private static func welcomeKey(_ id: String) -> String { "welcomed-\(id)" }
}
