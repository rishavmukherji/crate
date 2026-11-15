import SwiftUI

extension Animation {
    /// How the flow glides onto a cover.
    static var coverFlowSettle: Animation { .spring(response: 0.45, dampingFraction: 0.86) }
    /// How the flow coasts after a flick: it starts at the finger's speed (covers per second) and slows
    /// onto `target`, taking a little longer for longer coasts.
    static func coverFlowCoast(from start: Double, to target: Double, velocity: Double) -> Animation {
        let distance = target - start
        guard abs(distance) > 0.001 else { return .coverFlowSettle }
        let duration = 0.45 + min(abs(distance) * 0.035, 0.75)
        // initialVelocity is a fraction of the whole change per second
        return .interpolatingSpring(duration: duration, bounce: 0, initialVelocity: velocity / distance)
    }
    /// How the centered cover flips over to its back and returns.
    static var coverFlowFlip: Animation { .spring(response: 0.55, dampingFraction: 0.82) }
    /// How side covers fold in behind the centered cover before the flow changes to another list.
    static var coverFlowFold: Animation { .easeIn(duration: 0.25) }
    /// How a new list's covers fan out from behind its centered cover.
    static var coverFlowFan: Animation { .spring(response: 0.5, dampingFraction: 0.86) }
}

/// Layout constants for one Cover Flow stage, derived from the space it has.
struct CoverFlowMetrics: Equatable {
    var coverSize: CGFloat
    /// Distance from the center cover to the first cover of each side stack.
    var centerGap: CGFloat
    /// Distance between neighbouring covers inside a side stack.
    var sideSpacing: CGFloat
    /// How far side covers are turned toward the center, in degrees.
    var sideAngle: Double
    /// How far side covers sit behind the centered one.
    var sideDepth: CGFloat
    /// Distance from the camera to the centered cover; smaller means stronger perspective.
    var cameraDistance: CGFloat
    var reflectionRatio: CGFloat
    /// Space between a cover and its reflection.
    var reflectionGap: CGFloat
    var visibleSideCount: Int
    /// How much the centered cover grows when flipped, while staying inside the stage.
    var flippedScale: CGFloat
    /// Moves the flipped cover down to the stage's center (unflipped, it sits above its reflection).
    var flippedDrop: CGFloat

    init(fitting size: CGSize, showsReflection: Bool) {
        // Short stages (a phone in landscape) keep a shallower reflection so the cover can be taller.
        reflectionRatio = showsReflection ? (size.height < 320 ? 0.22 : 0.35) : 0
        reflectionGap = showsReflection ? 2 : 0
        let byHeight = size.height / (1 + reflectionRatio) * 0.92
        // Narrow stages (a phone in portrait) give the center cover most of the width;
        // wide ones keep more room for the side stacks.
        let aspect = size.width / max(size.height, 1)
        let widthShare = 0.7 - 0.18 * min(max(aspect - 1, 0), 1)
        coverSize = max(1, min(size.width * widthShare, byHeight))
        centerGap = coverSize * 0.62
        sideSpacing = coverSize * 0.24
        sideAngle = 70
        sideDepth = coverSize * 0.8
        cameraDistance = coverSize * 3
        // Side stacks sit back from the camera, so on screen they're compressed toward the center.
        let onScreenSpacing = sideSpacing * cameraDistance / (cameraDistance + sideDepth)
        let room = max(0, size.width / 2 - centerGap)
        visibleSideCount = Int((room / onScreenSpacing).rounded(.up)) + 3
        flippedScale = max(1, min(1.4, size.height * 0.96 / coverSize, size.width * 0.9 / coverSize))
        // Tiles are centered on cover + gap + reflection; the cover's own center sits half of the rest above.
        flippedDrop = (coverSize * reflectionRatio + reflectionGap) / 2 * flippedScale
    }

    /// Horizontal drag distance that moves the flow by one cover: how far the centered cover travels on
    /// screen to become the first side cover, so it stays under the finger as in Apple's Cover Flow.
    var dragDistancePerCover: CGFloat { centerGap * cameraDistance / (cameraDistance + sideDepth) }
}

/// A Cover Flow carousel. `position` is continuous (2.4 sits between covers 2 and 3);
/// whenever it stops changing on a fractional value the flow settles on the nearest cover.
struct CoverFlowView<Item: Identifiable, Cover: View, Back: View>: View {
    let items: [Item]
    @Binding var position: Double
    @Binding var isFlipped: Bool
    var showsReflection = true
    /// 1 lays the covers out normally; toward 0 they fold in behind the centered cover, which pushes
    /// forward slightly. Animate it to 0, swap `items`, and animate back to 1 to show a list change.
    var spread: Double = 1
    @ViewBuilder let cover: (Item) -> Cover
    @ViewBuilder let back: (Item) -> Back
    /// Called when the centered cover is tapped.
    let onActivate: (Item) -> Void

    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let metrics = CoverFlowMetrics(fitting: geo.size, showsReflection: showsReflection)
            // Behind the covers: clicking empty space puts a flipped cover back.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { unflip() }
            CoverFlowStage(
                items: items,
                position: position,
                spread: spread,
                isFlipped: isFlipped,
                metrics: metrics,
                cover: cover,
                back: back,
                onTap: handleTap
            )
            .frame(width: geo.size.width, height: geo.size.height)
            .gesture(dragGesture(metrics), including: isFlipped ? .subviews : .all)
        }
        .task(id: position) {
            // Crown and scroll-wheel input leave fractional positions; settle once input pauses.
            guard dragStart == nil, position != position.rounded() else { return }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            withAnimation(.coverFlowSettle) { position = clamped(position.rounded()) }
        }
    }

    private func handleTap(_ index: Int) {
        guard items.indices.contains(index) else { return }
        if isFlipped {
            unflip()
        } else if index == Int(position.rounded()) && abs(position - Double(index)) < 0.05 {
            onActivate(items[index])
        } else {
            withAnimation(.coverFlowSettle) { position = Double(index) }
        }
    }

    private func unflip() {
        guard isFlipped else { return }
        withAnimation(.coverFlowFlip) { isFlipped = false }
    }

    private func dragGesture(_ metrics: CoverFlowMetrics) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let start = dragStart ?? position
                if dragStart == nil { dragStart = start }
                position = clamped(start - value.translation.width / metrics.dragDistancePerCover)
            }
            .onEnded { value in
                let start = dragStart ?? position
                dragStart = nil
                // A flick carries on at the finger's speed and slows onto the cover it would coast to.
                let projected = start - value.predictedEndTranslation.width / metrics.dragDistancePerCover
                let target = clamped(projected.rounded())
                let velocity = -value.velocity.width / metrics.dragDistancePerCover  // covers per second
                withAnimation(.coverFlowCoast(from: position, to: target, velocity: velocity)) { position = target }
            }
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), Double(max(items.count - 1, 0)))
    }
}

/// Animatable so that every frame of a position animation re-lays out the covers,
/// including covers that scroll into or out of the visible window mid-animation.
private struct CoverFlowStage<Item: Identifiable, Cover: View, Back: View>: View, Animatable {
    let items: [Item]
    var position: Double
    var spread: Double
    let isFlipped: Bool
    let metrics: CoverFlowMetrics
    let cover: (Item) -> Cover
    let back: (Item) -> Back
    let onTap: (Int) -> Void

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(position, spread) }
        set { (position, spread) = (newValue.first, newValue.second) }
    }

    var body: some View {
        let centerIndex = Int(position.rounded())
        let lower = max(0, centerIndex - metrics.visibleSideCount)
        let upper = min(items.count - 1, centerIndex + metrics.visibleSideCount)
        ZStack {
            if lower <= upper {
                ForEach(lower...upper, id: \.self) { index in
                    tile(at: index, isCenter: index == centerIndex)
                }
            }
        }
    }

    private func tile(at index: Int, isCenter: Bool) -> some View {
        let offset = Double(index) - position
        let distance = abs(offset)
        let tilt = min(max(offset, -1), 1)
        let direction: Double = offset < 0 ? -1 : 1
        let laidOutX = distance <= 1
            ? offset * metrics.centerGap
            : direction * (metrics.centerGap + (distance - 1) * metrics.sideSpacing)
        let folded = 1 - spread
        let sideness = min(distance, 1)
        let flipped = isCenter && isFlipped
        return CoverTile(
            front: cover(items[index]),
            back: back(items[index]),
            flipAngle: flipped ? 180 : 0,
            size: metrics.coverSize,
            reflectionRatio: metrics.reflectionRatio,
            reflectionGap: metrics.reflectionGap
        )
        .scaleEffect(flipped ? metrics.flippedScale : 1)
        .scaleEffect(1 + 0.08 * folded * (1 - sideness))
        // Side covers turn to face the center (outer edges toward the viewer) and sit back from it.
        .projectionEffect(CoverFlowCamera.projection(
            anchor: CGPoint(x: metrics.coverSize / 2, y: metrics.coverSize / 2),
            angle: tilt * metrics.sideAngle,
            x: laidOutX * spread,
            z: -metrics.sideDepth * sideness,
            distance: metrics.cameraDistance
        ))
        .opacity(1 - folded * sideness)
        .offset(y: flipped ? metrics.flippedDrop : 0)
        .zIndex(flipped ? 1_000 : -distance)
        // A flipped cover's back handles its own taps.
        .gesture(TapGesture().onEnded { onTap(index) }, including: flipped ? .subviews : .all)
    }
}

/// One camera for the whole stage, as in Apple's Cover Flow: every cover is seen from the same
/// point, so the side stacks recede toward a single vanishing point at the stage's center
/// (per-view 3D effects would give each cover its own vanishing point instead).
enum CoverFlowCamera {
    /// Projects a view turned `angle` degrees about the vertical line through `anchor` (positive brings
    /// its right edge toward the viewer), then moved `x` to the right and `z` toward the viewer, as seen
    /// by a camera `distance` in front of `anchor`. Coordinates are the view's own.
    static func projection(anchor: CGPoint, angle: Double, x: CGFloat, z: CGFloat, distance d: CGFloat) -> ProjectionTransform {
        let radians = angle * .pi / 180
        let (c, s) = (CGFloat(cos(radians)), CGFloat(sin(radians)))
        let (ax, ay) = (anchor.x, anchor.y)
        // depth scale w = 1 - Z/d, where Z = (px - ax)·s + z
        let depth = 1 - z / d
        var t = ProjectionTransform()
        t.m11 = c - ax * s / d
        t.m12 = -ay * s / d
        t.m13 = -s / d
        t.m21 = 0
        t.m22 = 1
        t.m23 = 0
        t.m31 = -ax * (c - ax * s / d) + ax * depth + x
        t.m32 = ay * depth - ay + ax * ay * s / d
        t.m33 = depth + ax * s / d
        return t
    }
}

/// One cover with its floor reflection; flips over to show `back`.
private struct CoverTile<Front: View, Back: View>: View, Animatable {
    let front: Front
    let back: Back
    var flipAngle: Double
    let size: CGFloat
    let reflectionRatio: CGFloat
    let reflectionGap: CGFloat

    var animatableData: Double {
        get { flipAngle }
        set { flipAngle = newValue }
    }

    /// Fully flipped: the back is drawn flat, because controls under 3D rotations don't receive clicks reliably.
    private var isSettledOnBack: Bool { abs(flipAngle - 180) < 0.5 }

    var body: some View {
        VStack(spacing: reflectionGap) {
            Group {
                if isSettledOnBack {
                    back
                } else if flipAngle > 90 {
                    back.rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                } else {
                    front
                }
            }
            .frame(width: size, height: size)
            .rotation3DEffect(.degrees(isSettledOnBack ? 0 : flipAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)

            if reflectionRatio > 0 {
                front
                    .frame(width: size, height: size)
                    .scaleEffect(x: 1, y: -1)
                    .frame(width: size, height: size * reflectionRatio, alignment: .top)
                    .clipped()
                    .mask(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
                    .opacity(1 - min(flipAngle / 90, 1))
            }
        }
    }
}
