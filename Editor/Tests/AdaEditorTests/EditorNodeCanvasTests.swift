@testable import AdaEditor
@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Testing

@MainActor @Suite("Node canvas geometry", .serialized) struct EditorNodeCanvasTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World()))
        }
    }

    @Test func renderedCanvasPicksAndPansAfterZoomAndAncestorRelayout() async throws {
        let state = EditorNodeCanvasState()
        let interaction = EditorNodeCanvasInteraction()
        var selected: Set<String> = []
        var moves = 0
        interaction.select = { selected = $0 }
        interaction.move = { _ in moves += 1 }
        let container = UIContainerView(rootView: HStack(spacing: 0) {
            Color.clear.frame(width: 180)
            VStack(spacing: 0) {
                Color.clear.frame(height: 72)
                EditorNodeCanvas(items: [node], wires: [], selection: [], state: state, interaction: interaction)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        })
        container.frame = Rect(x: 0, y: 0, width: 1000, height: 700)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        for zoom in [Float(0.5), 1.3, 2] {
            state.zoom(by: zoom / state.zoom, around: .zero)
            state.setPan([70, 45])
            for _ in 0..<10 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() }
            let frame = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.NodeCanvas")).absoluteFrame
            #expect(frame.minX == 180 && frame.minY == 72)
            let geometry = EditorNodeCanvasGeometry(nodes: [node], pan: state.pan, zoom: state.zoom)
            let bounds = geometry.bounds(node)
            let context = UIGraphicsContext()
            container.viewTree.rootNode.draw(with: context)
            let coversCanvas = context.getDrawCommands().contains { command in
                if case let .drawQuad(transform, _, color) = command {
                    return abs(transform.scale.x - frame.width) < 0.1
                        && abs(transform.scale.y - frame.height) < 0.1 && color == .white
                }
                return false
            }
            #expect(!coversCanvas)
            let headers = context.getDrawCommands().compactMap { command -> Transform3D? in
                if case let .drawQuad(transform, _, _) = command,
                    abs(transform.scale.x - 208 * zoom) < 0.1, abs(transform.scale.y - 34 * zoom) < 0.1 {
                    return transform
                }
                return nil
            }
            let header = try #require(headers.first)
            // Use the actually rendered header, not a second calculation of the picking geometry.
            let point = Point(header.origin.x, -header.origin.y)
            #expect(abs(point.x - frame.minX - bounds.midX) < 0.1)
            #expect(abs(point.y - frame.minY - bounds.minY - 17 * zoom) < 0.1)
            selected = []
            mouse(container, point, .left, .began)
            mouse(container, point, .left, .ended)
            #expect(selected == ["node"])
            let oldPan = state.pan
            let delta = Vector2(50, 30)
            // Middle drag starts over a node, so it must take priority over selection and moving nodes.
            mouse(container, point, .middle, .began)
            mouse(container, point + Point(50, 30), .middle, .changed)
            mouse(container, point + Point(50, 30), .middle, .ended)
            #expect(state.pan == oldPan + delta)
            #expect(selected == ["node"])
            #expect(moves == 0)
            container.frame.size.width -= 20
            container.bounds.size = container.frame.size
        }
    }

    private func mouse(_ view: UIView, _ point: Point, _ button: MouseButton, _ phase: MouseEvent.Phase) {
        view.onMouseEvent(.init(window: .empty, button: button, mousePosition: point, phase: phase, modifierKeys: [], time: 0))
    }

    @Test func wireDrawingUsesTheSameLocalEndpointsAsPicking() throws {
        var context = UIGraphicsContext()
        context.translateBy(x: 10, y: -20)
        EditorNodeCanvas.drawWire(context: &context, start: [40, 60], end: [100, 200], color: .white)
        let lines = context.getDrawCommands().compactMap { command -> (Vector3, Vector3)? in
            if case let .drawLine(start, end, _, _) = command { return (start, end) }
            return nil
        }
        #expect(lines.count == 24)
        #expect(lines.first?.0 == [50, -80, 0])
        #expect(lines.last?.1 == [110, -220, 0])
    }

    private var node: EditorNodeCanvasItem {
        .init(id: "node", title: "Node", position: [100, 80], inputs: [.init(id: "a", title: "A", type: "float")], outputs: [.init(id: "value", title: "Value", type: "float")])
    }

    @Test func portsAndNodePickingShareTheDisplayedScaleAndPan() throws {
        let geometry = EditorNodeCanvasGeometry(nodes: [node], pan: [60, -20], zoom: 0.5)
        let endpoint = EditorNodeCanvasEndpoint(node: "node", port: "value", isOutput: true)
        let point = try #require(geometry.port(endpoint))
        #expect(geometry.hitPort(point) == endpoint)
        #expect(geometry.hitNode(geometry.screen([140, 100])) == "node")
        #expect(geometry.world(geometry.screen([140, 100])) == [140, 100])
        #expect(geometry.hitNode([-200, -200]) == nil)
    }

    @Test func zoomKeepsItsAnchorAndFitKeepsNodesOnScreen() {
        let state = EditorNodeCanvasState()
        let anchor = Vector2(320, 240)
        let before = (anchor - state.pan) / state.zoom
        state.zoom(by: 1.5, around: anchor)
        #expect(((anchor - state.pan) / state.zoom - before).squaredLength < 0.001)
        state.fit([node], in: Size(width: 640, height: 480))
        let geometry = EditorNodeCanvasGeometry(nodes: [node], pan: state.pan, zoom: state.zoom)
        let bounds = geometry.bounds(node)
        #expect(bounds.minX >= 0 && bounds.maxX <= 640)
        #expect(bounds.minY >= 0 && bounds.maxY <= 480)
        #expect(geometry.selected(in: bounds) == ["node"])
    }

    @Test func dragGroupsMovementIntoOneTransactionAndCancellationRestoresIt() {
        let state = EditorNodeCanvasState()
        let geometry = EditorNodeCanvasGeometry(nodes: [node], pan: .zero, zoom: 0.5)
        let interaction = EditorNodeCanvasInteraction()
        var begins = 0, commits = 0, cancels = 0
        var positions: [String: Vector2] = [:]
        interaction.begin = { begins += 1 }
        interaction.commit = { commits += 1 }
        interaction.cancel = { cancels += 1 }
        interaction.move = { positions = $0 }
        interaction.drag(from: [70, 45], to: [80, 55], geometry: geometry, wires: [], selection: [], state: state)
        interaction.drag(from: [70, 45], to: [90, 65], geometry: geometry, wires: [], selection: ["node"], state: state)
        #expect(positions["node"] == [140, 120])
        interaction.end(at: [90, 65], geometry: geometry)
        #expect(begins == 1 && commits == 1 && cancels == 0)
        interaction.drag(from: [70, 45], to: [80, 55], geometry: geometry, wires: [], selection: [], state: state)
        interaction.abort()
        #expect(begins == 2 && commits == 1 && cancels == 1)
    }

    @Test func wireCaptureUsesPortsAtCurrentZoomAndEmptyDropDoesNotConnect() throws {
        var other = node
        other.id = "other"
        other.position = [450, 100]
        let state = EditorNodeCanvasState()
        let geometry = EditorNodeCanvasGeometry(nodes: [node, other], pan: [30, -5], zoom: 0.75)
        let source = EditorNodeCanvasEndpoint(node: "node", port: "value", isOutput: true)
        let target = EditorNodeCanvasEndpoint(node: "other", port: "a", isOutput: false)
        let start = try #require(geometry.port(source)), end = try #require(geometry.port(target))
        let interaction = EditorNodeCanvasInteraction()
        var pairs: [EditorNodeCanvasWire] = []
        interaction.connect = { pairs.append(.init(source: $0, target: $1, type: "float")) }
        interaction.drag(from: start, to: end, geometry: geometry, wires: [], selection: [], state: state)
        interaction.end(at: end, geometry: geometry)
        #expect(pairs == [.init(source: source, target: target, type: "float")])
        interaction.drag(from: start, to: .zero, geometry: geometry, wires: [], selection: [], state: state)
        interaction.end(at: .zero, geometry: geometry)
        #expect(pairs.count == 1)
    }

    @Test func retainedCanvasRequestsAFrameForWireMotionAndRelease() throws {
        let interaction = EditorNodeCanvasInteraction()
        let state = EditorNodeCanvasState()
        let root = UIContainerView(rootView: EditorNodeCanvas(items: [node], wires: [], selection: [], state: state, interaction: interaction))
        root.frame = Rect(x: 0, y: 0, width: 800, height: 600)
        root.bounds.size = root.frame.size
        root.layoutIfNeeded()
        root.update(1 / 60)
        _ = root.consumeNeedsDisplay()
        let geometry = EditorNodeCanvasGeometry(nodes: [node], pan: state.pan, zoom: state.zoom)
        let source = try #require(geometry.port(.init(node: "node", port: "value", isOutput: true)))
        mouse(root, Point(source.x, source.y), .left, .began)
        root.update(1 / 60)
        #expect(root.consumeNeedsDisplay())
        mouse(root, Point(600, 300), .left, .changed)
        root.update(1 / 60)
        #expect(root.consumeNeedsDisplay())
        #expect(interaction.anchor != nil)
        mouse(root, Point(600, 300), .left, .ended)
        root.update(1 / 60)
        #expect(root.consumeNeedsDisplay())
        #expect(interaction.anchor == nil)
    }

    @Test func wiresCanBePickedAlongTheirRenderedCurveAtDifferentZooms() throws {
        var other = node
        other.id = "other"
        other.position = [500, 300]
        let wire = EditorNodeCanvasWire(source: .init(node: "node", port: "value", isOutput: true), target: .init(node: "other", port: "a", isOutput: false), type: "float")
        for zoom in [Float(0.25), 1, 2.5] {
            let geometry = EditorNodeCanvasGeometry(nodes: [node, other], pan: [60, 30], zoom: zoom)
            let start = try #require(geometry.port(wire.source)), end = try #require(geometry.port(wire.target))
            for t in [Float(0.25), 0.5, 0.75] {
                let point = EditorNodeCanvasGeometry.wirePoint(from: start, to: end, t: t)
                #expect(geometry.hitWire(point + Vector2(0, 4), wires: [wire]) == wire)
            }
            #expect(geometry.hitWire([-100, -100], wires: [wire]) == nil)
        }
    }
}
