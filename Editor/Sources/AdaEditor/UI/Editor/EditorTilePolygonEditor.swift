@_spi(AdaEngine) import AdaEngine
import Observation

@Observable @MainActor
final class EditorTilePolygonModel {
    var points: [Vector2] = []
    var referenceSize = Size(width: 16, height: 16)
    var texture: Texture2D?
    private(set) var selectedVertex: Int?
    @ObservationIgnored private var draggedVertex: Int?
    @ObservationIgnored private var dragOrigin: Point?

    func load(points: [Vector2], size: Size, texture: Texture2D? = nil) {
        self.points = points
        referenceSize = size
        self.texture = texture
        selectedVertex = nil
        endDrag()
    }

    func rectangle() {
        let x = referenceSize.width / 2, y = referenceSize.height / 2
        points = [[-x, -y], [x, -y], [x, y], [-x, y]]
        selectedVertex = nil
        endDrag()
    }

    func clear() { points = []; selectedVertex = nil; endDrag() }

    func removeSelected() {
        guard let index = selectedVertex, points.indices.contains(index) else {
            return
        }
        points.remove(at: index)
        selectedVertex = nil
        endDrag()
    }

    func screenPoint(_ point: Vector2, in size: Size) -> Vector2 {
        [size.width * (point.x / referenceSize.width + 0.5), size.height * (0.5 - point.y / referenceSize.height)]
    }

    func drag(at location: Point, from startLocation: Point? = nil, in size: Size) {
        guard size.width > 0, size.height > 0, location.x.isFinite, location.y.isFinite else {
            return
        }
        let start = startLocation ?? location
        if dragOrigin != start { draggedVertex = nil; dragOrigin = start }
        if draggedVertex == nil {
            let mouse = Vector2(start.x, start.y)
            if let nearest = points.indices.min(by: {
                (screenPoint(points[$0], in: size) - mouse).squaredLength < (screenPoint(points[$1], in: size) - mouse).squaredLength
            }), (screenPoint(points[nearest], in: size) - mouse).squaredLength <= 100 {
                draggedVertex = nearest
            } else if points.count < 256 {
                // Insert near an edge, otherwise append while drawing a new ring.
                var insertion = points.count
                var distance: Float = 100
                if points.count >= 3 {
                    for index in points.indices {
                        let a = screenPoint(points[index], in: size), b = screenPoint(points[(index + 1) % points.count], in: size)
                        let edge = b - a
                        let t = edge.squaredLength > 0 ? min(1, max(0, (mouse - a).dot(edge) / edge.squaredLength)) : 0
                        let candidate = (a + edge * t - mouse).squaredLength
                        if candidate < distance { distance = candidate; insertion = index + 1 }
                    }
                }
                points.insert(.zero, at: insertion)
                draggedVertex = insertion
            }
            selectedVertex = draggedVertex
        }
        guard let index = draggedVertex, points.indices.contains(index) else {
            return
        }
        points[index] = Vector2(
            (min(1, max(0, location.x / size.width)) - 0.5) * referenceSize.width,
            (0.5 - min(1, max(0, location.y / size.height))) * referenceSize.height
        )
    }

    func endDrag() { draggedVertex = nil; dragOrigin = nil }
}

struct EditorTilePolygonEditor: View {
    let model: EditorTilePolygonModel
    let identifier: String

    var body: some View {
        let points = model.points
        let selected = model.selectedVertex
        let texture = model.texture
        let referenceSize = model.referenceSize
        func screenPoint(_ point: Vector2, in size: Size) -> Vector2 {
            [size.width * (point.x / referenceSize.width + 0.5), size.height * (0.5 - point.y / referenceSize.height)]
        }
        return GeometryReader { geometry in
            Canvas { context, size in
                context.drawRect(Rect(origin: .zero, size: size), color: Color(red: 0.12, green: 0.14, blue: 0.17))
                if let texture { context.drawRect(Rect(origin: .zero, size: size), texture: texture, color: .white) }
                for index in points.indices {
                    let point = screenPoint(points[index], in: size)
                    if points.count > 1 {
                        context.drawLine(
                            start: point,
                            end: screenPoint(points[(index + 1) % points.count], in: size),
                            lineWidth: 2,
                            color: Color(red: 1, green: 0.75, blue: 0.2)
                        )
                    }
                    context.drawRect(Rect(x: point.x - 4, y: point.y - 4, width: 8, height: 8), color: index == selected ? .white : Color(red: 1, green: 0.75, blue: 0.2))
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let frame = geometry.frame(in: .global)
                    model.drag(
                        at: Point(value.location.x - frame.minX, value.location.y - frame.minY),
                        from: Point(value.startLocation.x - frame.minX, value.startLocation.y - frame.minY),
                        in: frame.size
                    )
                }
                .onEnded { value in
                    let frame = geometry.frame(in: .global)
                    model.drag(
                        at: Point(value.location.x - frame.minX, value.location.y - frame.minY),
                        from: Point(value.startLocation.x - frame.minX, value.startLocation.y - frame.minY),
                        in: frame.size
                    )
                    model.endDrag()
                })
        }
        .frame(height: 180)
        .accessibilityIdentifier(identifier)
    }
}
