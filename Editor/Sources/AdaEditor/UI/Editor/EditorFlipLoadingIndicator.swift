@_spi(AdaEngine) import AdaEngine
import Foundation
import Math

#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

/// A compact square that flips around its vertical axis, then its horizontal axis.
struct EditorFlipLoadingIndicator: View {
    var size: Float = 14
    var color: Color

    var body: some View {
        if Self.reduceMotion {
            RoundedRectangleShape(cornerRadius: size * 0.08)
                .fill(color)
                .frame(width: size, height: size)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let phase = Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8)
                EditorFlipLoadingShape(phase: phase)
                    .fill(color)
                    .frame(width: size, height: size)
            }
            .frame(width: size, height: size)
        }
    }

    private static var reduceMotion: Bool {
        #if os(macOS)
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #elseif canImport(UIKit)
            UIAccessibility.isReduceMotionEnabled
        #else
            false
        #endif
    }
}

private struct EditorFlipLoadingShape: Shape {
    typealias AnimatableData = EmptyAnimatableData

    let phase: Float

    func path(in rect: Rect) -> Path {
        let turningVertically = phase < 0.5
        let halfPhase = turningVertically ? phase * 2 : (phase - 0.5) * 2
        let progress = min(1, halfPhase / 0.9)
        let eased = progress * progress * (3 - 2 * progress)
        let angle = Float.pi * eased
        let flatScale = abs(Math.cos(angle))
        let depth = Math.sin(angle)
        let halfWidth = rect.width / 2
        let halfHeight = rect.height / 2
        let perspective = max(rect.width, rect.height) * 3

        func project(_ x: Float, _ y: Float) -> Point {
            let z = (turningVertically ? x : y) * depth
            let factor = perspective / (perspective + z)
            return Point(
                rect.midX + (turningVertically ? x * flatScale : x) * factor,
                rect.midY + (turningVertically ? y : y * flatScale) * factor
            )
        }

        let corners = [
            project(-halfWidth, -halfHeight),
            project(halfWidth, -halfHeight),
            project(halfWidth, halfHeight),
            project(-halfWidth, halfHeight),
        ]
        let radius: Float = 0.08
        func between(_ first: Point, _ second: Point, fraction: Float) -> Point {
            first + (second - first) * fraction
        }

        var path = Path()
        path.move(to: between(corners[0], corners[1], fraction: radius))
        for index in 1...4 {
            let corner = corners[index % 4]
            let previous = corners[(index + 3) % 4]
            let next = corners[(index + 1) % 4]
            path.addLine(to: between(previous, corner, fraction: 1 - radius))
            path.addQuadCurve(to: between(corner, next, fraction: radius), control: corner)
        }
        path.closeSubpath()
        return path
    }
}
