import SwiftUI

/// Top-down plan of the room: you at the centre, the band around you.
///
/// A plan view rather than a 3D scene on purpose. Azimuth is the cue HRTF
/// renders convincingly; elevation is weak with a generic head model, so
/// height is a secondary control rather than a dimension you drag in.
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
    /// Content bounds in metres, recomputed only between drags. Refitting mid-
    /// drag would slide the floor around under the finger that is moving it.
    @State private var fit = Fit(centreX: 0, centreZ: -2, radius: 5)

    private let puckSize: CGFloat = 32

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
                y: centre.y - CGFloat(fit.centreZ) * scale
            )

            ZStack {
                rings(centre: origin, scale: scale)
                listener(centre: origin)
                ForEach(pucks, id: \.id) { puck in
                    view(for: puck, centre: origin, scale: scale)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .onAppear(perform: refit)
        .onChange(of: dragging) { _, now in if now == nil { refit() } }
        .onChange(of: scene.placements) { _, _ in if dragging == nil { refit() } }
        .onChange(of: collapsed) { _, _ in refit() }
        .aspectRatio(1, contentMode: .fit)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
    }

    // MARK: - Grouping

    private struct Puck {
        let id: String
        let label: String
        let family: Stem.Family
        let members: [String]
        let x: Float
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
            out.append(Puck(
                id: parent,
                label: parent.capitalized,
                family: members[0].family,
                members: members.map(\.name),
                x: places.map(\.x).reduce(0, +) / Float(places.count),
                z: places.map(\.z).reduce(0, +) / Float(places.count)
            ))
            handled.formUnion(members.map(\.name))
        }

        for stem in stems where !handled.contains(stem.name) {
            let placement = scene.placement(for: stem.name)
            out.append(Puck(
                id: stem.name, label: stem.label, family: stem.family,
                members: [stem.name], x: placement.x, z: placement.z
            ))
        }
        return out
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

    private func rings(centre: CGPoint, scale: CGFloat) -> some View {
        Canvas { context, _ in
            for metres in stride(from: 2.0, through: 30.0, by: 2.0) {
                let radius = CGFloat(metres) * scale
                guard radius < max(centre.x, centre.y) else { break }
                let rect = CGRect(
                    x: centre.x - radius, y: centre.y - radius,
                    width: radius * 2, height: radius * 2
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
        .position(centre)
        .allowsHitTesting(false)
    }

    private func view(for puck: Puck, centre: CGPoint, scale: CGFloat) -> some View {
        let position = CGPoint(
            x: centre.x + CGFloat(puck.x) * scale,
            y: centre.y + CGFloat(puck.z) * scale
        )
        let audible = puck.members.contains { scene.isAudible($0) }
        let level = puck.members.map(audibleLevel).max() ?? 0
        let active = dragging == puck.id

        return ZStack {
            Circle()
                .fill(colour(for: puck.family).opacity(audible ? 0.9 : 0.25))
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
                    dragging = puck.id
                    move(puck, to: value.location, centre: centre, scale: scale)
                }
                .onEnded { _ in dragging = nil }
        )
        .onTapGesture { toggle(puck) }
        .animation(.easeOut(duration: 0.18), value: level)
    }

    // MARK: - Interaction

    /// Moving a group translates every member, so the kit keeps its shape.
    private func move(_ puck: Puck, to point: CGPoint, centre: CGPoint, scale: CGFloat) {
        let limit = scene.room.extent
        let targetX = Float((point.x - centre.x) / scale)
        let targetZ = Float((point.y - centre.y) / scale)
        let deltaX = targetX - puck.x
        let deltaZ = targetZ - puck.z

        for member in puck.members {
            var placement = scene.placement(for: member)
            placement.x = min(limit, max(-limit, placement.x + deltaX))
            placement.z = min(limit, max(-limit, placement.z + deltaZ))
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
