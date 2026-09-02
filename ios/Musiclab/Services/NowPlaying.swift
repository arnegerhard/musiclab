import Foundation
import Observation

/// The song the app is currently on, and whether its full screen is showing.
///
/// Kept outside any one screen because the controls have to survive leaving
/// the player: a song keeps playing while you browse the library, queue
/// another, or pair a Mac, and the bar above the tabs is how it stays
/// reachable from all of them.
@Observable
@MainActor
final class NowPlaying {
    private(set) var entry: LibraryEntry?
    /// Whether the full player is up. Collapsing leaves the song playing and
    /// the bar behind; only choosing another song replaces it.
    var isExpanded = false

    func open(_ entry: LibraryEntry) {
        self.entry = entry
        isExpanded = true
    }

    func collapse() { isExpanded = false }

    /// Nothing is playing any more -- the song was deleted, or the engine was
    /// torn down.
    func clear() {
        entry = nil
        isExpanded = false
    }
}
