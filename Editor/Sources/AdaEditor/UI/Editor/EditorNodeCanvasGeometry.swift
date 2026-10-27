@_spi(AdaEngine) import AdaEngine
import Observation

struct EditorNodeCanvasPort: Identifiable, Equatable {
    var id: String
    var title: String
    var type: String
}

struct EditorNodeCanvasItem: Identifiable, Equatable {
    var id: String
    var title: String
    var position: Vector2
    var inputs: [EditorNodeCanvasPort]
    var outputs: [EditorNodeCanvasPort]
    var subtitle: String?
    var hasError = false

    var height: Float { 42 + Float(max(1, max(inputs.count, outputs.count))) * 24 + (subtitle == nil ? 0 : 18) }
}

struct EditorNodeCanvasEndpoint: Hashable {
    var node: String
    var port: String
    var isOutput: Bool
}

struct EditorNodeCanvasWire: Equatable {
    var source: EditorNodeCanvasEndpoint
    var target: EditorNodeCanvasEndpoint
    var type: String
}

struct EditorNodeCanvasDecoration: Identifiable {
    var id: String
    var title: String
    var bounds: Rect
    var isNote = false
}

struct EditorNodeCanvasGeometry {
    static let nodeWidth: Float = 208
    let nodes: [EditorNodeCanvasItem]
    let pan: Vector2
    let zoom: Float
    private let nodeByID: [String: EditorNodeCanvasItem]

    init(nodes: [EditorNodeCanvasItem], pan: Vector2, zoom: Float) {
        self.nodes = nodes
        self.pan = pan
        self.zoom = zoom
        self.nodeByID = nodes.reduce(into: [:]) { $0[$1.id] = $1 }
    }

    func screen(_ point: Vector2) -> Vector2 { point * zoom + pan }
    func world(_ point: Vector2) -> Vector2 { (point - pan) / max(0.01, zoom) }

    func origin(_ node: EditorNodeCanvasItem) -> Vector2 {
        Vector2(node.position.x.isFinite ? min(1e6, max(-1e6, node.position.x)) : 0, node.position.y.isFinite ? min(1e6, max(-1e6, node.position.y)) : 0)
    }

    func bounds(_ node: EditorNodeCanvasItem) -> Rect {
        let point = screen(origin(node))
        return Rect(x: point.x, y: point.y, width: Self.nodeWidth * zoom, height: node.height * zoom)
    }

    func port(_ endpoint: EditorNodeCanvasEndpoint) -> Vector2? {
        guard let node = nodeByID[endpoint.node], let row = (endpoint.isOutput ? node.outputs : node.inputs).firstIndex(where: { $0.id == endpoint.port }) else {
            return nil
        }
        return screen(origin(node) + Vector2(endpoint.isOutput ? Self.nodeWidth - 13 : 13, 46 + Float(row) * 24))
    }

    func hitPort(_ point: Vector2, outputsOnly: Bool? = nil) -> EditorNodeCanvasEndpoint? {
        for node in nodes.reversed() {
            for output in [true, false] where outputsOnly == nil || outputsOnly == output {
                for item in output ? node.outputs : node.inputs {
                    let endpoint = EditorNodeCanvasEndpoint(node: node.id, port: item.id, isOutput: output)
                    if let position = port(endpoint), (position - point).squaredLength <= max(8, zoom * 8) * max(8, zoom * 8) {
                        return endpoint
                    }
                }
            }
        }
        return nil
    }

    func hitNode(_ point: Vector2) -> String? { nodes.reversed().first { bounds($0).contains(point: Point(point.x, point.y)) }?.id }

    /// Pick the same curve segments that are drawn, with a screen-space tolerance at every zoom.
    func hitWire(_ point: Vector2, wires: [EditorNodeCanvasWire]) -> EditorNodeCanvasWire? {
        wires.reversed().first { wire in
            guard let start = port(wire.source), let end = port(wire.target) else { return false }
            var previous = start
            for index in 1...24 {
                let next = Self.wirePoint(from: start, to: end, t: Float(index) / 24)
                let segment = next - previous
                let offset = point - previous
                let projection = min(1, max(0, (offset.x * segment.x + offset.y * segment.y) / max(0.001, segment.squaredLength)))
                if (point - previous - segment * projection).squaredLength <= 49 { return true }
                previous = next
            }
            return false
        }
    }

    static func wirePoint(from start: Vector2, to end: Vector2, t: Float) -> Vector2 {
        let bend = max(50, abs(end.x - start.x) * 0.5)
        let a = start + Vector2(bend, 0), b = end - Vector2(bend, 0), u = 1 - t
        return start * (u * u * u) + a * (3 * u * u * t) + b * (3 * u * t * t) + end * (t * t * t)
    }

    func selected(in rect: Rect) -> Set<String> { Set(nodes.filter { rect.intersects(bounds($0)) }.map(\.id)) }
}

@Observable @MainActor final class EditorNodeCanvasState {
    private(set) var pan: Vector2 = [24, 24]
    private(set) var zoom: Float = 1
    private(set) var revision: UInt64 = 0
    var panMode = false

    func setPan(_ value: Vector2) {
        guard value.x.isFinite, value.y.isFinite else {
            return
        }
        pan = value
        revision &+= 1
    }

    func zoom(by factor: Float, around anchor: Vector2) {
        guard factor.isFinite, factor > 0 else {
            return
        }
        let world = (anchor - pan) / zoom
        zoom = min(2.5, max(0.25, zoom * factor))
        pan = anchor - world * zoom
        revision &+= 1
    }

    func fit(_ nodes: [EditorNodeCanvasItem], in size: Size) {
        guard !nodes.isEmpty, size.width > 0, size.height > 0 else {
            return
        }
        let geometry = EditorNodeCanvasGeometry(nodes: nodes, pan: .zero, zoom: 1)
        let left = nodes.map { geometry.origin($0).x }.min() ?? 0
        let top = nodes.map { geometry.origin($0).y }.min() ?? 0
        let right = nodes.map { geometry.origin($0).x + EditorNodeCanvasGeometry.nodeWidth }.max() ?? 0
        let bottom = nodes.map { geometry.origin($0).y + $0.height }.max() ?? 0
        zoom = min(1.3, max(0.25, min(size.width / max(1, right - left + 80), size.height / max(1, bottom - top + 80))))
        pan = Vector2(size.width, size.height) * 0.5 - Vector2((left + right) * 0.5, (top + bottom) * 0.5) * zoom
        revision &+= 1
    }
}
