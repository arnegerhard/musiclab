import SwiftUI

/// The line above the tabs: what is playing, and enough control not to have to
/// open the player for the ordinary things.
struct MiniPlayerBar: View {
    @Environment(NowPlaying.self) private var nowPlaying
    @Environment(SpatialEngine.self) private var engine

    /// Only the transport needs to tick; the stage is not on screen.
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var elapsed: TimeInterval = 0

    var body: some View {
        if let entry = nowPlaying.entry {
            VStack(spacing: 0) {
                // A hairline of progress, the way a mini player usually shows
                // it: enough to see the song moving, too thin to fiddle with.
                ProgressView(value: engine.duration > 0 ? elapsed / engine.duration : 0)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(height: 2)

                HStack(spacing: 12) {
                    // The same picture the lock screen is showing.
                    Group {
                        if let cover = nowPlaying.artwork {
                            Image(uiImage: cover).resizable().scaledToFill()
                        } else {
                            Image(systemName: "music.note")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color.secondary.opacity(0.15))
                        }
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).font(.callout).lineLimit(1)
                        Text(engine.isPlaying ? clock(elapsed) : "Paused")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The whole strip opens the player, not just a button.
                    .contentShape(Rectangle())
                    .onTapGesture { nowPlaying.isExpanded = true }

                    Button {
                        engine.isPlaying ? engine.pause() : engine.play()
                    } label: {
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")

                    Button {
                        engine.seek(to: min(engine.duration, engine.currentTime + 15))
                        elapsed = engine.currentTime
                    } label: {
                        Image(systemName: "goforward.15")
                            .font(.title3).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip forward 15 seconds")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(.bar)
            .onReceive(ticker) { _ in
                if engine.isPlaying { elapsed = engine.currentTime }
            }
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.isFinite ? seconds : 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
