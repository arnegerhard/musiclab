import Foundation
import MediaPlayer
import Observation
import UIKit

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

    /// The cover, once it has been fetched. Shown in the bar and handed to
    /// the lock screen.
    private(set) var artwork: UIImage?

    private var commandsWired = false

    func open(_ entry: LibraryEntry) {
        if entry.slug != self.entry?.slug { artwork = nil }
        self.entry = entry
        isExpanded = true
    }

    func collapse() { isExpanded = false }

    /// Nothing is playing any more -- the song was deleted, or the engine was
    /// torn down.
    func clear() {
        entry = nil
        artwork = nil
        isExpanded = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - The world outside the app

    /// Tell the system what is playing.
    ///
    /// This is what the lock screen, Control Centre, CarPlay and the Watch
    /// read. Elapsed time and rate are enough for all of them -- the system
    /// runs the clock itself from there, so this only has to be called when
    /// something actually changes rather than every tick.
    func publish(engine: SpatialEngine, client: StemsClient) {
        guard let entry else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: entry.title,
            MPMediaItemPropertyArtist: entry.uploader,
            MPMediaItemPropertyPlaybackDuration: engine.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: engine.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: engine.isPlaying ? 1.0 : 0.0,
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: artwork.size
            ) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if artwork == nil {
            Task { [entry] in
                let image = await client.artwork(for: entry)
                guard self.entry?.slug == entry.slug, let image else { return }
                self.artwork = image
                self.publish(engine: engine, client: client)
            }
        }
    }

    /// Wire the buttons that live outside the app: the lock screen, the
    /// AirPods stem, the steering wheel.
    ///
    /// Without these the transport is unreachable the moment the phone is
    /// locked, and a squeeze of an AirPod does nothing at all.
    func wireRemoteCommands(engine: SpatialEngine, client: StemsClient) {
        guard !commandsWired else { return }
        commandsWired = true
        let centre = MPRemoteCommandCenter.shared()

        centre.playCommand.addTarget { [weak self] _ in
            engine.play()
            self?.publish(engine: engine, client: client)
            return .success
        }
        centre.pauseCommand.addTarget { [weak self] _ in
            engine.pause()
            self?.publish(engine: engine, client: client)
            return .success
        }
        centre.togglePlayPauseCommand.addTarget { [weak self] _ in
            engine.isPlaying ? engine.pause() : engine.play()
            self?.publish(engine: engine, client: client)
            return .success
        }

        // The same fifteen seconds the bar offers, so the two agree.
        centre.skipForwardCommand.preferredIntervals = [15]
        centre.skipForwardCommand.addTarget { [weak self] event in
            let step = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            engine.seek(to: min(engine.duration, engine.currentTime + step))
            self?.publish(engine: engine, client: client)
            return .success
        }
        centre.skipBackwardCommand.preferredIntervals = [15]
        centre.skipBackwardCommand.addTarget { [weak self] event in
            let step = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            engine.seek(to: max(0, engine.currentTime - step))
            self?.publish(engine: engine, client: client)
            return .success
        }

        // Scrubbing on the lock screen.
        centre.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            else { return .commandFailed }
            engine.seek(to: position)
            self?.publish(engine: engine, client: client)
            return .success
        }
    }
}
