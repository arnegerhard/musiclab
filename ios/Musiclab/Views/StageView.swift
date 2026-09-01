import SwiftUI

/// Plan of the room: you at the centre, the band around you. Two fingers
/// dragged up tilt the floor away, the way a map does, which turns the plan
/// into an oblique view where height becomes visible and draggable.
///
/// Azimuth is the cue HRTF renders convincingly and elevation is the weak one
/// with a generic head model, so height stays a deliberate act -- you have to
/// tilt the floor before you can touch it -- rather than something you nudge
/// by accident while arranging the band.
struct StageView: View {
    @Binding var scene: SpatialScene
    let stems: [Stem]
    let headYaw: Float
    let audibleLevel: (String) -> Double

    /// Parents whose children ride as one puck. A six-piece kit drawn at true
    /// scale is a pile of overlapping circles nobody can grab, so the kit
    /// travels together until you ask for the pieces.
    @State private var collapsed: Set<String> = ["drums"]
    @State private var dragging: String?
    /// Placements as they were when the current drag began. Deltas measured
    /// against these rather than against the live value, so a slow drag cannot
    /// accumulate rounding into drift.
    @State private var dragStart: [String: Placement] = [:]
    /// Content bounds in metres, recomputed only between drags. Refitting mid-
    /// drag would slide the floor around under the finger that is moving it.
    @State private var fit = Fit(centreX: 0, centreZ: -2, radius: 5)
    /// Degrees the floor is tilted away from flat.
    @State private var tilt: Double = 0

    private let puckSize: CGFloat = 32
    /// Past about here the floor is edge-on: depth stops being readable and
    /// the arithmetic that turns finger movement back into metres blows up.
    private let maxTilt: Double = 70
    /// Below this the view is a plan and drags belong to the floor.
    private let heightThreshold: Double = 10
    private let maxHeight: Float = 4

    private var isTilted: Bool { tilt >= heightThreshold }
    /// How much the floor is foreshortened, and how far a metre of height
    /// lifts a puck up the screen. Together these are the whole projection.
    private var squash: CGFloat { CGFloat(cos(tilt * .pi / 180)) }
    private var rise: CGFloat { CGFloat(sin(tilt * .pi / 180)) }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let side = min(size.width, size.height)
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let scale = (side / 2 - puckSize / 2 - 8) / CGFloat(fit.radius)
            // Slide the view so the arrangement is centred rather than the
            // listener: with a band standing in front, half the floor is empty.
            let origin = CGPoint(
                x: centre.x - CGFloat(fit.centreX) * scale,
                y: centre.y - CGFloat(fit.centreZ) * scale * squash
            )

            ZStack {
                rings(centre: origin, scale: scale)
                listener(centre: origin)

                // Beneath the pucks, so a single finger still grabs a stem;
                // two fingers on open floor tilt instead.
                TwoFingerPan { delta in
                    // Fingers up tilts the floor away, as a map does.
                    tilt = min(maxTilt, max(0, tilt - Double(delta) * 0.35))
                }

                ForEach(pucks, id: \.id) { puck in
                    view(for: puck, centre: origin, scale: scale)
                }
            }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottomLeading) { tiltBadge }
        }
        .onAppear(perform: refit)
        .onChange(of: dragging) { _, now in if now == nil { refit() } }
        .onChange(of: scene.placements) { _, _ in if dragging == nil { refit() } }
        .onChange(of: collapsed) { _, _ in refit() }
        .aspectRatio(1, contentMode: .fit)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
    }

    // MARK: - Projection

    /// Room metres to screen points. An oblique projection rather than a true
    /// perspective one: it stays exactly invertible, so a finger dragged an
    /// inch moves a stem the same distance wherever it is on the floor.
    private func project(
        x: Float, y: Float, z: Float, centre: CGPoint, scale: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: centre.x + CGFloat(x) * scale,
            y: centre.y + CGFloat(z) * scale * squash - CGFloat(y) * scale * rise
        )
    }

    // MARK: - Grouping

    private struct Puck {
        let id: String
        let label: String
        let family: Stem.Family
        let members: [String]
        let x: Float
        let y: Float
        let z: Float
        var isGroup: Bool { members.count > 1 }
    }

    private var pucks: [Puck] {
        var out: [Puck] = []
        var handled: Set<String> = []

        for parent in collapsed.sorted() {
            let members = stems.filter { $0.parent == parent }
            guard members.count > 1 else { continue }
            let places = members.map { scene.placement(for: $0.name) }
            let count = Float(places.count)
            out.append(Puck(
                id: parent,
                label: parent.capitalized,
                family: members[0].family,
                members: members.map(\.name),
                x: places.map(\.x).reduce(0, +) / count,
                y: places.map(\.y).reduce(0, +) / count,
                z: places.map(\.z).reduce(0, +) / count
            ))
            handled.formUnion(members.map(\.name))
        }

        for stem in stems where !handled.contains(stem.name) {
            let placement = scene.placement(for: stem.name)
            out.append(Puck(
                id: stem.name, label: stem.label, family: stem.family,
                members: [stem.name], x: placement.x, y: placement.y, z: placement.z
            ))
        }
        // Far sources drawn first, so a nearer one overlaps it rather than the
        // other way round.
        return out.sorted { $0.z < $1.z }
    }

    struct Fit: Equatable {
        var centreX: Float
        var centreZ: Float
        var radius: Float
    }

    /// Fit the listener and every source into the square, with a little air.
    private func refit() {
        let places = stems.map { scene.placement(for: $0.name) }
        guard !places.isEmpty else { return }

        // The listener is part of the picture, so the origin is always included.
        let xs = places.map(\.x) + [0]
        let zs = places.map(\.z) + [0]
        let centreX = ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2
        let centreZ = ((zs.min() ?? 0) + (zs.max() ?? 0)) / 2

        // One radius for both axes keeps the plan square: a metre across must
        // be a metre deep, or the room shears.
        let spanX = max(abs((xs.max() ?? 0) - centreX), abs(centreX - (xs.min() ?? 0)))
        let spanZ = max(abs((zs.max() ?? 0) - centreZ), abs(centreZ - (zs.min() ?? 0)))
        let radius = max(2.5, max(spanX, spanZ) * 1.12)

        let next = Fit(centreX: centreX, centreZ: centreZ, radius: radius)
        if next != fit {
            withAnimation(.easeOut(duration: 0.25)) { fit = next }
        }
    }

    // MARK: - Pieces

    private var tiltBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: isTilted ? "arrow.up.and.down.and.arrow.left.and.right" : "hand.draw")
                .font(.system(size: 9))
            Text(isTilted
                 ? "\(Int(tilt))° — drag up and down for height"
                 : "Two fingers to tilt")
                .font(.system(size: 9))
            if tilt > 0 {
                Button("Flat") { withAnimation(.easeOut(duration: 0.25)) { tilt = 0 } }
                    .font(.system(size: 9, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        }
        .foregroundStyle(.white.opacity(0.45))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func rings(centre: CGPoint, scale: CGFloat) -> some View {
        // Squashing the rings into ellipses is what actually reads as a tilt;
        // the pucks alone would just look like they had moved.
        Canvas { context, _ in
            for metres in stride(from: 2.0, through: 30.0, by: 2.0) {
                let radius = CGFloat(metres) * scale
                guard radius < max(centre.x, centre.y) else { break }
                let rect = CGRect(
                    x: centre.x - radius, y: centre.y - radius * squash,
                    width: radius * 2, height: radius * 2 * squash
                )
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(.white.opacity(metres.truncatingRemainder(dividingBy: 6) == 0 ? 0.11 : 0.05)),
                    lineWidth: 1
                )
            }
        }
    }

    private func listener(centre: CGPoint) -> some View {
        // The room stays put and the head turns, which is the whole point of
        // head tracking, so the picture should say exactly that.
        ZStack {
            Circle().fill(.white.opacity(0.92)).frame(width: 20, height: 20)
            Triangle().fill(.white.opacity(0.92))
                .frame(width: 11, height: 9).offset(y: -16)
        }
        .rotationEffect(.degrees(-Double(headYaw)))
        .scaleEffect(x: 1, y: max(0.35, squash), anchor: .center)
        .position(centre)
        .allowsHitTesting(false)
    }

    private func view(for puck: Puck, centre: CGPoint, scale: CGFloat) -> some View {
        let floor = project(x: puck.x, y: 0, z: puck.z, centre: centre, scale: scale)
        let position = project(x: puck.x, y: puck.y, z: puck.z, centre: centre, scale: scale)
        let audible = puck.members.contains { scene.isAudible($0) }
        let level = puck.members.map(audibleLevel).max() ?? 0
        let active = dragging == puck.id
        let tint = colour(for: puck.family)

        return ZStack {
            // The stalk is what makes height legible: without a line back to
            // the floor a raised puck just looks like it is further away.
            if isTilted, abs(position.y - floor.y) > 1 {
                Path { path in
                    path.move(to: floor)
                    path.addLine(to: position)
                }
                .stroke(tint.opacity(audible ? 0.5 : 0.18), style: .init(lineWidth: 1.5, dash: [3, 2]))

                Ellipse()
                    .fill(.white.opacity(0.14))
                    .frame(width: puckSize * 0.5, height: puckSize * 0.5 * max(0.2, squash))
                    .position(floor)
            }

            ZStack {
                Circle()
                    .fill(tint.opacity(audible ? 0.9 : 0.25))
                    .frame(width: puckSize, height: puckSize)
                    .overlay(
                        Circle().strokeBorder(
                            .white.opacity(active ? 0.95 : 0.22), lineWidth: active ? 2 : 1
                        )
                    )
                    .scaleEffect(1 + 0.22 * level)
                Text(short(puck.label))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.85))
                if puck.isGroup {
                    Text("\(puck.members.count)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(.black.opacity(0.75)))
                        .offset(x: puckSize / 2 - 3, y: -puckSize / 2 + 3)
                }
            }
            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
            .position(position)
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if dragging != puck.id {
                            dragging = puck.id
                            dragStart = Dictionary(
                                uniqueKeysWithValues: puck.members.map {
                                    ($0, scene.placement(for: $0))
                                }
                            )
                        }
                        move(puck, by: value.translation, scale: scale)
                    }
                    .onEnded { _ in dragging = nil; dragStart = [:] }
            )
            .onTapGesture { toggle(puck) }
            .animation(.easeOut(duration: 0.18), value: level)
        }
    }

    // MARK: - Interaction

    /// Moving a group translates every member, so the kit keeps its shape.
    ///
    /// Which axis the vertical component drives is the whole point of the
    /// tilt: flat on, up the screen means further away; tilted, it means
    /// higher off the floor.
    private func move(_ puck: Puck, by translation: CGSize, scale: CGFloat) {
        let limit = scene.room.extent
        let deltaX = Float(translation.width / scale)

        for member in puck.members {
            guard var placement = dragStart[member] else { continue }
            placement.x = min(limit, max(-limit, placement.x + deltaX))

            if isTilted {
                // Up the screen is up in the room, hence the negation.
                let deltaY = Float(-translation.height / (scale * rise))
                placement.y = min(maxHeight, max(-maxHeight, placement.y + deltaY))
            } else {
                let deltaZ = Float(translation.height / (scale * max(0.2, squash)))
                placement.z = min(limit, max(-limit, placement.z + deltaZ))
            }
            scene.placements[member] = placement
        }
    }

    private func toggle(_ puck: Puck) {
        withAnimation(.easeOut(duration: 0.2)) {
            if puck.isGroup {
                collapsed.remove(puck.id)
            } else if let parent = stems.first(where: { $0.name == puck.id })?.parent,
                      stems.filter({ $0.parent == parent }).count > 1 {
                collapsed.insert(parent)
            }
        }
    }

    private func short(_ label: String) -> String {
        let words = label.split(separator: " ")
        if words.count > 1 { return words.map { $0.prefix(1) }.joined().uppercased() }
        return String(label.prefix(4))
    }

    private func colour(for family: Stem.Family) -> Color {
        switch family {
        case .voice: return Color(red: 0.42, green: 0.90, blue: 0.66)
        case .drums: return Color(red: 0.95, green: 0.70, blue: 0.32)
        case .strings: return Color(red: 0.53, green: 0.71, blue: 0.98)
        case .keys: return Color(red: 0.82, green: 0.62, blue: 0.96)
        case .other: return Color(red: 0.70, green: 0.74, blue: 0.80)
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
