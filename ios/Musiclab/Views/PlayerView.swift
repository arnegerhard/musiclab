import SwiftUI

struct PlayerView: View {
    let entry: LibraryEntry

    @Environment(StemsClient.self) private var client
    @Environment(NowPlaying.self) private var nowPlaying
    @Environment(SpatialEngine.self) private var engine
    @Environment(HeadTracker.self) private var head
    @State private var route = AudioRoute()
    @State private var track: Track?
    @State private var scene = SpatialScene()
    @State private var status = "Loading…"
    @State private var failed: String?
    @State private var elapsed: TimeInterval = 0
    @State private var scrubbing = false

    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private var stems: [Stem] { track?.leafStems ?? [] }

    var body: some View {
        Group {
            if let failed {
                ContentUnavailableView("Could not load", systemImage: "exclamationmark.triangle", description: Text(failed))
            } else if track == nil {
                VStack(spacing: 14) {
                    ProgressView(value: client.downloadProgress)
                        .progressViewStyle(.linear).frame(maxWidth: 220)
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                content
            }
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        // The drag indicator says it can be swiped away; this says it for
        // anyone who does not read drag indicators.
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    nowPlaying.collapse()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .accessibilityLabel("Collapse")
            }
        }
        .task { await load() }
        .onDisappear {
            // The music carries on. Only the scene is settled up here; the
            // engine and the head tracker belong to the app now, and tearing
            // them down on the way out is what used to cut the song off
            // halfway through the moment you looked at the library.
            Task { await client.saveScene(scene, slug: entry.slug) }
        }
        .onReceive(ticker) { _ in
            if engine.isPlaying, !scrubbing { elapsed = engine.currentTime }
            engine.updateListener(yaw: head.yaw, pitch: head.pitch, roll: head.roll)
        }
        .onChange(of: scene) { _, new in engine.apply(new) }
        .onChange(of: route.isHeadphones) { _, on in engine.matchOutput(headphones: on) }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                StageView(
                    scene: $scene,
                    stems: stems,
                    headYaw: head.yaw,
                    audibleLevel: level(for:)
                )
                .padding(.horizontal)

                outputSection
                transport
                roomControls
                stemList
            }
            .padding(.vertical)
        }
    }

    // MARK: - Sections

    /// Which device is playing, and what that device can do for the mix.
    /// The picker itself is the system one — the list of paired Bluetooth
    /// devices is not something an app is allowed to read.
    private var outputSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: route.icon)
                    .font(.title3)
                    .foregroundStyle(route.isHeadphones ? .green : .orange)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(route.name)
                        .font(.caption).fontWeight(.medium).lineLimit(1)
                    Text(route.isHeadphones
                         ? "Spatial mix — the room is around you."
                         : "Speaker: the room collapses. Pick headphones.")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }

                Spacer()

                // AVRoutePickerView draws and sizes its own AirPlay glyph.
                RoutePicker()
                    .frame(width: 34, height: 34)
                    .accessibilityLabel("Choose playback device")
            }

            Divider().opacity(0.25)

            HStack(spacing: 10) {
                Image(systemName: head.isTracking ? "arrow.trianglehead.2.clockwise.rotate.90" : "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(head.isTracking ? .green : .secondary)
                    .frame(width: 26)
                Text(head.isTracking
                     ? "Head tracking on — turn your head, the band stays put."
                     : "No head tracking. Drag the slider below to turn.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Recenter") { head.recenter() }
                    .font(.caption2).buttonStyle(.bordered)
                    .disabled(!head.isTracking)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var transport: some View {
        VStack(spacing: 8) {
            if !head.isTracking {
                // Off-device and on plain headphones this is the only way to
                // turn, so it is a real control rather than a debug affordance.
                HStack {
                    Image(systemName: "arrow.clockwise").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(head.manualYaw) },
                        set: { head.manualYaw = Float($0) }
                    ), in: -180...180)
                    Text("\(Int(head.manualYaw))°")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }

            HStack(spacing: 16) {
                Button {
                    engine.isPlaying ? engine.pause() : engine.play()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 42))
                }
                VStack(spacing: 2) {
                    Slider(
                        value: $elapsed,
                        in: 0...max(1, engine.duration),
                        onEditingChanged: { editing in
                            scrubbing = editing
                            if !editing { engine.seek(to: elapsed) }
                        }
                    )
                    HStack {
                        Text(clock(elapsed)); Spacer(); Text(clock(engine.duration))
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
    }

    private var roomControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Room", selection: $scene.room) {
                ForEach(RoomPreset.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Layout.allCases) { layout in
                        Button(layout.label) {
                            withAnimation(.easeOut(duration: 0.35)) {
                                scene.placements = layout.positions(for: stems)
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private var stemList: some View {
        VStack(spacing: 0) {
            ForEach(stems) { stem in
                let placement = scene.placement(for: stem.name)
                HStack(spacing: 10) {
                    Text(stem.label).font(.callout).lineLimit(1)
                    if stem.silent {
                        Text("silent").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.1f m", placement.distance))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    toggle("M", on: placement.mute) { scene.placements[stem.name]?.mute.toggle() }
                    toggle("S", on: placement.solo) { scene.placements[stem.name]?.solo.toggle() }
                }
                .padding(.vertical, 7)
                .opacity(scene.isAudible(stem.name) ? 1 : 0.4)
                Divider().opacity(0.25)
            }
        }
        .padding(.horizontal)
    }

    private func toggle(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(text, action: action)
            .font(.caption2.weight(.bold))
            .frame(width: 26, height: 24)
            .background(on ? Color.accentColor : Color.gray.opacity(0.2),
                        in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(on ? Color.black : Color.primary)
            .buttonStyle(.plain)
    }

    // MARK: - Loading

    private func load() async {
        do {
            try engine.configureSession()
            // Only now does the session know what it is playing through.
            route.refresh()
            engine.matchOutput(headphones: route.isHeadphones)
            let track = try await client.track(slug: entry.slug)
            self.track = track

            // Already the song in the engine: this is somebody coming back to
            // watch it, not asking for it again. Reloading would stop it and
            // start it over from silence.
            if engine.loadedSlug == entry.slug {
                scene = await client.scene(slug: entry.slug) ?? scene
                if scene.placements.isEmpty {
                    scene.placements = Layout.stage.positions(for: track.leafStems)
                }
                elapsed = engine.currentTime
                head.start()
                return
            }

            status = "Fetching stems…"
            let urls = client.isDownloaded(slug: entry.slug, stems: track.leafStems)
                ? client.localURLs(slug: entry.slug, stems: track.leafStems)
                : try await client.download(slug: entry.slug, stems: track.leafStems)

            var scene = await client.scene(slug: entry.slug) ?? SpatialScene()
            if scene.placements.isEmpty {
                scene.placements = Layout.stage.positions(for: track.leafStems)
            }
            self.scene = scene

            try engine.load(slug: entry.slug, stems: track.leafStems, urls: urls)
            engine.apply(scene)
            head.start()
        } catch {
            failed = error.localizedDescription
        }
    }

    /// Static loudness from the manifest, used to size the pucks. Live metering
    /// would mean fourteen taps for a purely cosmetic wobble.
    private func level(for name: String) -> Double {
        guard let rms = stems.first(where: { $0.name == name })?.rmsDb else { return 0 }
        return max(0, min(1, (rms + 80) / 60))
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.isFinite ? seconds : 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
