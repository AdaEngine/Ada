@_spi(AdaEngine) import AdaEngine
import Observation

/// One pointer capture owns a complete operation, even while the view is recomputed.
@Observable @MainActor final class EditorNodeCanvasInteraction {
    private(set) var cursor = Vector2.zero
    private(set) var anchor: EditorNodeCanvasEndpoint?
    private(set) var marquee: Rect?
    private(set) var revision: UInt64 = 0
    private(set) var replacedInput: EditorNodeCanvasEndpoint?
    @ObservationIgnored var select: (Set<String>) -> Void = { _ in }
    @ObservationIgnored var selectWire: (EditorNodeCanvasWire) -> Void = { _ in }
    @ObservationIgnored var move: ([String: Vector2]) -> Void = { _ in }
    @ObservationIgnored var begin: () -> Void = {}
    @ObservationIgnored var commit: () -> Void = {}
    @ObservationIgnored var cancel: () -> Void = {}
    @ObservationIgnored var connect: (EditorNodeCanvasEndpoint, EditorNodeCanvasEndpoint) -> Void = { _, _ in }
    @ObservationIgnored var emptyDrop: (EditorNodeCanvasEndpoint, Vector2) -> Void = { _, _ in }
    @ObservationIgnored private var operation: Operation?
    @ObservationIgnored private var origin = Vector2.zero
    @ObservationIgnored private var didMove = false

    private enum Operation {
        case wire(EditorNodeCanvasEndpoint)
        case nodes([String: Vector2])
        case pan(Vector2)
        case marquee
        case selectedWire
    }

    func drag(
        from start: Vector2, to point: Vector2, geometry: EditorNodeCanvasGeometry,
        wires: [EditorNodeCanvasWire], selection: Set<String>, state: EditorNodeCanvasState, panning: Bool = false
    ) {
        if operation == nil {
            origin = start
            if panning || state.panMode {
                operation = .pan(state.pan)
            } else if let port = geometry.hitPort(start) {
                select([])
                let fixed = !port.isOutput ? (wires.first { $0.target == port }?.source ?? port) : port
                replacedInput = !port.isOutput && fixed != port ? port : nil
                anchor = fixed
                operation = .wire(fixed)
            } else if let node = geometry.hitNode(start) {
                let selected = selection.contains(node) ? selection : [node]
                select(selected)
                operation = .nodes(Dictionary(uniqueKeysWithValues: geometry.nodes.filter { selected.contains($0.id) }.map { ($0.id, geometry.origin($0)) }))
            } else if let wire = geometry.hitWire(start, wires: wires) {
                select([])
                selectWire(wire)
                operation = .selectedWire
            } else {
                select([])
                operation = .marquee
            }
        }
        cursor = point
        switch operation {
        case .nodes(let positions):
            let delta = (point - origin) / geometry.zoom
            if delta.squaredLength > 0 {
                if !didMove {
                    begin()
                    didMove = true
                }
                move(positions.mapValues { $0 + delta })
            }
        case .pan(let pan): state.setPan(pan + point - origin)
        case .marquee:
            let rect = Rect(x: min(origin.x, point.x), y: min(origin.y, point.y), width: abs(point.x - origin.x), height: abs(point.y - origin.y))
            marquee = rect
            select(geometry.selected(in: rect))
        default: break
        }
        revision &+= 1
    }

    func end(at point: Vector2, geometry: EditorNodeCanvasGeometry) {
        if case .wire(let fixed) = operation {
            if let endpoint = geometry.hitPort(point, outputsOnly: !fixed.isOutput) {
                connect(fixed.isOutput ? fixed : endpoint, fixed.isOutput ? endpoint : fixed)
            } else if geometry.hitNode(point) == nil {
                emptyDrop(fixed, geometry.world(point))
            }
        }
        if didMove { commit() }
        reset()
    }

    func abort() {
        if didMove { cancel() }
        reset()
    }

    private func reset() {
        operation = nil
        anchor = nil
        replacedInput = nil
        marquee = nil
        didMove = false
        revision &+= 1
    }
}
