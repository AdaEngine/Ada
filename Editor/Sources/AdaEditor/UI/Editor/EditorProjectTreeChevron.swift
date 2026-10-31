@_spi(AdaEngine) import AdaEngine
import Math

struct EditorProjectTreeLocateIcon: Shape {
    typealias AnimatableData = EmptyAnimatableData

    func path(in rect: Rect) -> Path {
        let radius = min(rect.width, rect.height) * 0.28
        var path = CircleShape().path(in: Rect(x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2))
        let inset = radius * 0.65
        path.move(to: Point(rect.midX, rect.minY))
        path.addLine(to: Point(rect.midX, rect.midY - inset))
        path.move(to: Point(rect.midX, rect.maxY))
        path.addLine(to: Point(rect.midX, rect.midY + inset))
        path.move(to: Point(rect.minX, rect.midY))
        path.addLine(to: Point(rect.midX - inset, rect.midY))
        path.move(to: Point(rect.maxX, rect.midY))
        path.addLine(to: Point(rect.midX + inset, rect.midY))
        return path
    }
}

struct EditorProjectTreeChevron: Shape {
    var expansion: Float
    var animatableData: Float {
        get { expansion }
        set { expansion = newValue }
    }

    func path(in rect: Rect) -> Path {
        let angle = expansion * Float.pi / 2
        let cosine = Math.cos(angle)
        let sine = Math.sin(angle)
        func point(_ x: Float, _ y: Float) -> Point {
            Point(rect.midX + x * cosine - y * sine, rect.midY + x * sine + y * cosine)
        }
        var path = Path()
        path.move(to: point(-2, -4))
        path.addLine(to: point(2, 0))
        path.addLine(to: point(-2, 4))
        return path
    }
}
