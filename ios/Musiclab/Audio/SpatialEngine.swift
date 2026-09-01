import AVFoundation
import Foundation
import Observation

/// Plays every stem at once as a positioned point source in a virtual room.
///
/// The graph is deliberately flat:
///
///     AVAudioPlayerNode (mono, per stem) -> AVAudioEnvironmentNode -> output
///
/// All the spatial work happens on the player nodes, which conform to
/// AVAudio3DMixing. Nothing may sit between a player and the environment node:
/// AVAudioUnitEQ does not conform to AVAudioMixing, so inserting one would
/// silently cost the source its 3D position.
@Observable
final class SpatialEngine {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private var players: [String: AVAudioPlayerNode] = [:]
    private var files: [String: AVAudioFile] = [:]
    private var clockStem: String?

    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    private(set) var loadedStems: [String] = []
    /// Which track is loaded. The engine outlives the screen that started it,
    /// so coming back has to be told apart from starting something new.
    private(set) var loadedSlug: String?
    private var seekOffset: TimeInterval = 0
    private var pausedAt: TimeInterval = 0

    /// How far a source can get before distance effects stop deepening.
    private let maxDistance: Float = 18

    // MARK: - Session

    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }

    var isUsingHeadphones: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains {
            [.headphones, .bluetoothA2DP, .bluetoothLE, .airPlay].contains($0.portType)
        }
    }

    /// Re-aim the renderer after someone picks a different device mid-song.
    /// Safe to call before anything is loaded.
    func matchOutput(headphones: Bool) {
        environment.outputType = headphones ? .headphones : .builtInSpeakers
    }

    // MARK: - Loading

    /// Attach one player per stem. `urls` are local files already downloaded.
    func load(slug: String, stems: [Stem], urls: [String: URL]) throws {
        teardown()

        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)

        // Binaural rendering assumes two ears close together. Sent to the
        // phone speaker it smears the mix instead of placing it, so follow
        // whatever the route picker selected.
        environment.outputType = isUsingHeadphones ? .headphones : .builtInSpeakers
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 1.0
        environment.distanceAttenuationParameters.maximumDistance = maxDistance
        environment.distanceAttenuationParameters.rolloffFactor = 1.1
        environment.reverbParameters.enable = true

        for stem in stems {
            guard let url = urls[stem.name] else { continue }
            let file = try AVAudioFile(forReading: url)
            let player = AVAudioPlayerNode()
            engine.attach(player)
            // Mono in: the environment node will not spatialise a stereo source.
            engine.connect(player, to: environment, format: file.processingFormat)

            player.renderingAlgorithm = .HRTFHQ
            player.sourceMode = .pointSource
            player.reverbBlend = 0.2

            players[stem.name] = player
            files[stem.name] = file
            duration = max(duration, Double(file.length) / file.processingFormat.sampleRate)
        }

        loadedSlug = slug
        loadedStems = stems.compactMap { players[$0.name] != nil ? $0.name : nil }
        clockStem = loadedStems.first

        engine.prepare()
        try engine.start()
    }

    func teardown() {
        stop()
        for player in players.values {
            engine.detach(player)
        }
        if engine.attachedNodes.contains(environment) {
            engine.detach(environment)
        }
        players.removeAll()
        files.removeAll()
        loadedStems.removeAll()
        loadedSlug = nil
        duration = 0
        seekOffset = 0
        pausedAt = 0
    }

    // MARK: - Scene

    func apply(_ scene: SpatialScene) {
        environment.reverbParameters.loadFactoryReverbPreset(scene.room.reverbPreset)
        environment.reverbParameters.level = scene.room.reverbLevel

        for name in loadedStems {
            guard let player = players[name] else { continue }
            let placement = scene.placement(for: name)
            player.position = placement.point
            player.volume = scene.isAudible(name) ? placement.gain : 0

            let distance = min(placement.distance, maxDistance)
            let far = (distance - 1) / (maxDistance - 1)   // 0 near, 1 far

            // Distance is heard as the ratio of dry to reverberant sound far
            // more than as loudness, so the send rises as a source retreats.
            player.reverbBlend = min(0.85, (0.08 + 0.7 * far) * scene.distanceReverb)

            // Air absorbs high frequencies with distance. `obstruction` filters
            // the direct path while leaving the reverb send alone, which is
            // exactly the "far away" timbre; `occlusion` would duck the
            // reverb too and fight the distance model's own attenuation.
            player.obstruction = -9 * far
        }
    }

    func updateListener(yaw: Float, pitch: Float, roll: Float) {
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(
            yaw: yaw, pitch: pitch, roll: roll
        )
    }

    // MARK: - Transport

    var currentTime: TimeInterval {
        guard isPlaying,
              let name = clockStem,
              let player = players[name],
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return pausedAt }
        return min(duration, seekOffset + Double(playerTime.sampleTime) / playerTime.sampleRate)
    }

    func play() {
        guard !players.isEmpty else { return }
        if !engine.isRunning { try? engine.start() }
        schedule(from: pausedAt)

        // One shared start instant for every player: this is what makes the
        // stems sample-locked instead of merely close, and it is the whole
        // reason a native engine beats fourteen <audio> elements.
        let lead = AVAudioTime.hostTime(forSeconds: 0.12)
        let when = AVAudioTime(hostTime: mach_absolute_time() + lead)
        for player in players.values {
            player.play(at: when)
        }
        seekOffset = pausedAt
        isPlaying = true
    }

    func pause() {
        pausedAt = currentTime
        for player in players.values { player.stop() }
        isPlaying = false
    }

    func stop() {
        for player in players.values { player.stop() }
        isPlaying = false
        pausedAt = 0
        seekOffset = 0
    }

    func seek(to time: TimeInterval) {
        let target = max(0, min(time, duration))
        let wasPlaying = isPlaying
        for player in players.values { player.stop() }
        pausedAt = target
        isPlaying = false
        if wasPlaying { play() }
    }

    private func schedule(from offset: TimeInterval) {
        for (name, file) in files {
            guard let player = players[name] else { continue }
            let rate = file.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(offset * rate)
            guard startFrame < file.length else { continue }
            let frames = AVAudioFrameCount(file.length - startFrame)
            player.scheduleSegment(
                file, startingFrame: startFrame, frameCount: frames, at: nil
            )
        }
    }
}
