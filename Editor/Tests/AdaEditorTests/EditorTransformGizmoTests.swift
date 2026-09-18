@_spi(AdaEngine) import AdaEngine
import AdaInput
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite("Transform gizmo interaction", .serialized)
struct EditorTransformGizmoTests {
    @Test("move only captures visible handles and respects zoom")
    func moveAxis() throws {
        let fixture = try Fixture()
        fixture.viewport.twoDZoom = 2
        let gizmo = try #require(fixture.viewport.transformGizmo())
        let x = try #require(gizmo.shapes.first { $0.handle == .x })
        #expect(!fixture.viewport.beginTransformDragIfNeeded(at: gizmo.screenOrigin + Vector2(40, 40), button: .left))
        let start = try #require(x.points.last)
        try fixture.drag(from: start, to: start + Vector2(40, -30))
        let transform = try fixture.transform()
        #expect(abs(transform.position.x - 20) < 0.02)
        #expect(transform.position.y == 0)
        #expect(try fixture.runtimeTransform().position == transform.position)
        #expect(fixture.selection?.editorID == "selected")
        #expect(fixture.content.contains("Unrelated.Component"))
    }

    @Test("uniform move uses parent coordinates without shifting the gizmo origin")
    func parentedMove() throws {
        let parent = Transform(rotation: Quat(axis: Vector3(0, 0, 1), angle: .pi / 2), scale: Vector3(2, 2, 2), position: Vector3(50, 20, 0))
        let fixture = try Fixture(parent: parent)
        let gizmo = try #require(fixture.viewport.transformGizmo())
        #expect(abs(gizmo.screenOrigin.x - 450) < 0.01)
        #expect(abs(gizmo.screenOrigin.y - 280) < 0.01)
        try fixture.drag(from: gizmo.screenOrigin, to: gizmo.screenOrigin + Vector2(40, 0))
        let transform = try fixture.transform()
        #expect(abs(transform.position.x) < 0.02)
        #expect(abs(transform.position.y + 20) < 0.02)
        let worldPosition = try #require(fixture.viewport.gizmoWorldMatrix(for: "selected")).origin
        #expect(abs(worldPosition.x - 90) < 0.02)
        #expect(abs(worldPosition.y - 20) < 0.02)
    }

    @Test("scale axis preserves other axes and negative scales")
    func scaleAxis() throws {
        let fixture = try Fixture(transform: Transform(scale: Vector3(-2, 3, 4)))
        fixture.viewport.setActiveTool(.scale)
        let gizmo = try #require(fixture.viewport.transformGizmo())
        let start = try #require(gizmo.shapes.first { $0.handle == .x }?.points.last)
        try fixture.drag(from: start, to: start + Vector2(40, 0))
        let value = try fixture.transform().scale
        #expect(abs(value.x + 3) < 0.01)
        #expect(value.y == 3 && value.z == 4)
    }

    @Test("rotation composes with the starting orientation")
    func rotationRing() throws {
        let fixture = try Fixture(transform: Transform(rotation: Quat(axis: Vector3(0, 0, 1), angle: .pi / 2)))
        fixture.viewport.setActiveTool(.rotate)
        let gizmo = try #require(fixture.viewport.transformGizmo())
        let ring = try #require(gizmo.shapes.first)
        try fixture.drag(from: ring.points[0], to: ring.points[16])
        let rotation = try fixture.transform().rotation
        #expect(abs(abs(rotation.z) - 1) < 0.002)
        #expect(abs(rotation.w) < 0.002)
        #expect(try fixture.runtimeTransform().rotation == rotation)
    }

    @Test("3D move supports every world axis", arguments: [EditorTransformGizmo.Handle.x, .y, .z])
    func moveIn3D(axis: EditorTransformGizmo.Handle) throws {
        let fixture = try Fixture()
        fixture.viewport.setDisplayMode(.threeD)
        fixture.viewport.threeDPosition = Vector3(6, 5, -9)
        fixture.viewport.threeDYaw = -0.59
        fixture.viewport.threeDPitch = -0.43
        _ = fixture.viewport.update(deltaTime: 1)
        let gizmo = try #require(fixture.viewport.transformGizmo())
        let start = try #require(gizmo.shapes.first { $0.handle == axis }?.points.last)
        let end = try #require(fixture.viewport.project(gizmo.origin + axis.axis * gizmo.worldLength * 1.5, size: fixture.viewport.viewportSize))
        try fixture.drag(from: start, to: end)
        let value = try fixture.transform().position
        for index in 0..<3 {
            let expected: Float = index == axis.rawValue ? gizmo.worldLength * 0.5 : 0
            #expect(abs(value[index] - expected) < 0.01)
        }
    }

    @Test("3D rotation and scale operate on each local axis", arguments: [EditorSceneViewportTool.rotate, .scale], [EditorTransformGizmo.Handle.x, .y, .z])
    func localAxesIn3D(tool: EditorSceneViewportTool, axis: EditorTransformGizmo.Handle) throws {
        let fixture = try Fixture()
        fixture.viewport.setDisplayMode(.threeD)
        fixture.viewport.threeDPosition = Vector3(6, 5, -9)
        fixture.viewport.threeDYaw = -0.59
        fixture.viewport.threeDPitch = -0.43
        _ = fixture.viewport.update(deltaTime: 1)
        fixture.viewport.setActiveTool(tool)
        let gizmo = try #require(fixture.viewport.transformGizmo())
        let shape = try #require(gizmo.shapes.first { $0.handle == axis })
        if tool == .rotate {
            let index = try #require((0..<48).first { gizmo.hitTest(shape.points[$0]) == axis })
            try fixture.drag(from: shape.points[index], to: shape.points[index + 16])
            let rotation = try fixture.transform().rotation
            let values = [rotation.x, rotation.y, rotation.z]
            #expect(abs(abs(values[axis.rawValue]) - sqrt(0.5)) < 0.003)
            #expect(abs(abs(rotation.w) - sqrt(0.5)) < 0.003)
        } else {
            let start = try #require(shape.points.last)
            let end = try #require(fixture.viewport.project(gizmo.origin + axis.axis * gizmo.worldLength * 1.5, size: fixture.viewport.viewportSize))
            try fixture.drag(from: start, to: end)
            let scale = try fixture.transform().scale
            for index in 0..<3 { #expect(abs(scale[index] - (index == axis.rawValue ? 1.5 : 1)) < 0.01) }
        }
    }

    @Test("canvas draws handles and a click without movement leaves the document untouched")
    func drawingAndNoOp() throws {
        let fixture = try Fixture()
        var counts: [Int] = []
        for tool in [EditorSceneViewportTool.select, .translate, .rotate, .scale] {
            fixture.viewport.setActiveTool(tool)
            var context = UIGraphicsContext()
            fixture.viewport.drawGizmos(in: &context, size: fixture.viewport.viewportSize, theme: .adaEditor)
            counts.append(context.getDrawCommands().count)
        }
        #expect(counts.dropFirst().allSatisfy { $0 > counts[0] })
        let before = fixture.content
        let origin = try #require(fixture.viewport.transformGizmo()).screenOrigin
        try fixture.drag(from: origin, to: origin)
        #expect(fixture.content == before)
    }

    @Test("escape and cancelled pointer input restore the original transform")
    func cancelDrag() throws {
        let fixture = try Fixture()
        let gizmo = try #require(fixture.viewport.transformGizmo())
        #expect(fixture.viewport.handleInput(mouse(gizmo.screenOrigin, .began)))
        #expect(fixture.viewport.handleInput(mouse(gizmo.screenOrigin + Vector2(30, 20), .changed)))
        #expect(try fixture.runtimeTransform().position != .zero)
        #expect(fixture.viewport.handleInput(KeyEvent(window: .empty, keyCode: .escape, modifiers: [], status: .down, time: 0, isRepeated: false)))
        #expect(try fixture.transform().position == .zero)
        #expect(try fixture.runtimeTransform().position == .zero)
        #expect(fixture.viewport.handleInput(mouse(gizmo.screenOrigin, .ended)))
        #expect(fixture.selection?.editorID == "selected")
        #expect(fixture.documentEdits == 0)
        #expect(fixture.viewport.handleInput(mouse(gizmo.screenOrigin, .began)))
        #expect(fixture.viewport.handleInput(mouse(gizmo.screenOrigin + Vector2(20, 10), .changed)))
        #expect(fixture.viewport.handleInput(mouse(gizmo.screenOrigin, .cancelled)))
        #expect(try fixture.transform().position == .zero)
    }

    @Test("a drag survives redraws and publishes one document edit")
    func singleEditOnRelease() throws {
        let fixture = try Fixture()
        let before = fixture.content
        let origin = try #require(fixture.viewport.transformGizmo()).screenOrigin
        #expect(fixture.viewport.handleInput(mouse(origin, .began)))
        #expect(fixture.viewport.handleInput(mouse(origin + Vector2(20, 0), .changed)))
        #expect(fixture.content == before)
        #expect(abs(try fixture.runtimeTransform().position.x - 20) < 0.02)
        fixture.viewport.configure(
            sceneContent: fixture.content,
            onSelectionChanged: { fixture.selection = $0 },
            onDocumentContentChanged: {
                fixture.content = $0
                fixture.documentEdits += 1
            }
        )
        #expect(fixture.viewport.handleInput(mouse(origin + Vector2(40, 0), .changed)))
        #expect(fixture.viewport.handleInput(mouse(origin + Vector2(40, 0), .ended)))
        #expect(abs(try fixture.transform().position.x - 40) < 0.02)
        #expect(fixture.documentEdits == 1)
    }

    @Test("touch manipulates handles while Space drag remains camera pan")
    func touchAndPan() throws {
        let fixture = try Fixture()
        let origin = try #require(fixture.viewport.transformGizmo()).screenOrigin
        for (phase, point) in [(TouchEvent.Phase.began, origin), (.moved, origin + Vector2(20, 0)), (.ended, origin + Vector2(20, 0))] {
            #expect(fixture.viewport.handleInput(TouchEvent(window: .empty, location: point, phase: phase, time: 0)))
        }
        #expect(abs(try fixture.transform().position.x - 20) < 0.02)
        _ = fixture.viewport.handleInput(KeyEvent(window: .empty, keyCode: .space, modifiers: [], status: .down, time: 0, isRepeated: false))
        let newOrigin = try #require(fixture.viewport.transformGizmo()).screenOrigin
        try fixture.drag(from: newOrigin, to: newOrigin + Vector2(40, 0))
        #expect(abs(try fixture.transform().position.x - 20) < 0.02)
        #expect(fixture.viewport.twoDCenter.x == -40)
    }

    @Test("Inspector waits one second after the latest transform while runtime and release stay immediate")
    func inspectorDebouncesLatestTransform() async throws {
        let fixture = try Fixture()
        defer { fixture.viewport.disconnect() }
        let before = fixture.selection
        let initialUpdates = fixture.selectionUpdates
        let origin = try #require(fixture.viewport.transformGizmo()).screenOrigin
        #expect(fixture.viewport.handleInput(mouse(origin, .began)))
        #expect(fixture.viewport.handleInput(mouse(origin + Vector2(20, 0), .changed)))
        #expect(abs(try fixture.runtimeTransform().position.x - 20) < 0.02)
        #expect(fixture.selection == before)
        try await Task.sleep(for: .milliseconds(600))
        #expect(fixture.viewport.handleInput(mouse(origin + Vector2(40, 0), .changed)))
        try await Task.sleep(for: .milliseconds(600))
        #expect(fixture.selectionUpdates == initialUpdates)
        #expect(fixture.documentEdits == 0)
        #expect(abs(try fixture.runtimeTransform().position.x - 40) < 0.02)
        #expect(fixture.viewport.handleInput(mouse(origin + Vector2(40, 0), .ended)))
        #expect(fixture.selection == before)
        #expect(fixture.documentEdits == 1)
        #expect(abs(try fixture.transform().position.x - 40) < 0.02)
        let deadline = ContinuousClock.now + .seconds(2)
        while fixture.selectionUpdates == initialUpdates, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.selectionUpdates == initialUpdates + 1)
        #expect(fixture.selection?.transformFields != before?.transformFields)
        let positionField = try #require(fixture.selection?.transformFields.first { $0.field.key == "position" })
        let payload = try #require(fixture.viewport.sceneModel?.entities.first { $0.id == "selected" }?.components[EditorBuiltInComponentType.transform])
        #expect(positionField.value == positionField.field.displayValue(in: payload))
        try await Task.sleep(for: .milliseconds(1100))
        #expect(fixture.selectionUpdates == initialUpdates + 1)
    }

    @Test("cancelled drag restores Inspector and cancels its pending refresh")
    func cancelledInspectorRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.viewport.disconnect() }
        let before = fixture.selection
        let origin = try #require(fixture.viewport.transformGizmo()).screenOrigin
        #expect(fixture.viewport.handleInput(mouse(origin, .began)))
        #expect(fixture.viewport.handleInput(mouse(origin + Vector2(20, 0), .changed)))
        fixture.viewport.endTransformDrag(cancelled: true)
        let updates = fixture.selectionUpdates
        try await Task.sleep(for: .milliseconds(1100))
        #expect(fixture.selectionUpdates == updates)
        #expect(fixture.selection == before)
        #expect(try fixture.runtimeTransform().position == .zero)
        #expect(fixture.documentEdits == 0)
    }

    @Test("disconnect and external scene replacement cancel pending Inspector refresh", arguments: [false, true])
    func invalidatedInspectorRefresh(disconnect: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.viewport.disconnect() }
        let origin = try #require(fixture.viewport.transformGizmo()).screenOrigin
        try fixture.drag(from: origin, to: origin + Vector2(20, 0))
        if disconnect {
            fixture.viewport.disconnect()
        } else {
            let replacement = try EditorSceneModel.default(projectName: "Replacement").encodedYAML()
            fixture.viewport.configure(
                sceneContent: replacement,
                onSelectionChanged: {
                    fixture.selection = $0
                    fixture.selectionUpdates += 1
                },
                onDocumentContentChanged: {
                    fixture.content = $0
                    fixture.documentEdits += 1
                }
            )
        }
        let selection = fixture.selection
        let updates = fixture.selectionUpdates
        try await Task.sleep(for: .milliseconds(1100))
        #expect(fixture.selectionUpdates == updates)
        #expect(fixture.selection == selection)
    }

    @Test("Select mode hides handles and zoom preserves their screen size")
    func visibleGeometry() throws {
        let fixture = try Fixture()
        for zoom: Float in [0.1, 1, 10] {
            fixture.viewport.twoDZoom = zoom
            let gizmo = try #require(fixture.viewport.transformGizmo())
            let end = try #require(gizmo.shapes.first { $0.handle == .x }?.points.last)
            #expect(abs(end.x - gizmo.screenOrigin.x - 80) < 0.03)
        }
        fixture.viewport.setActiveTool(.select)
        #expect(fixture.viewport.transformGizmo() == nil)
    }

    private func mouse(_ point: Point, _ phase: MouseEvent.Phase) -> MouseEvent {
        MouseEvent(window: .empty, button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0)
    }
}

@MainActor
private final class Fixture {
    let viewport = EditorSceneViewportModel()
    let world = World(name: "TransformGizmoTests")
    var content = ""
    var documentEdits = 0
    var runtimeID: Entity.ID?
    var selection: EditorInspectorSidebarViewModel.SelectedEntity?
    var selectionUpdates = 0

    init(transform: Transform = Transform(), parent: Transform? = nil) throws {
        var model = EditorSceneModel.default(projectName: "Gizmo")
        let root = try #require(model.rootEntityID)
        let selected = model.addEntity(name: "Selected", parentID: root)
        let index = try #require(model.entities.firstIndex(where: { $0.id == selected.id }))
        model.entities[index].id = "selected"
        model.entities[index].components["Unrelated.Component"] = ["value": .string("preserved")]
        model.selectEntity("selected")
        content = try model.encodedYAML()
        content = try EditorSceneYAMLDocument.upsertTransform(transform, entityID: "selected", in: content)
        if let parent {
            content = try EditorSceneYAMLDocument.upsertTransform(parent, entityID: root, in: content)
        }
        viewport.configure(
            sceneContent: content,
            onSelectionChanged: { [weak self] in
                self?.selection = $0
                self?.selectionUpdates += 1
            },
            onDocumentContentChanged: { [weak self] in
                self?.content = $0
                self?.documentEdits += 1
            }
        )
        let result = EditorSceneFileLoader.load(content: content, into: world)
        runtimeID = result.entitiesByEditorID["selected"]
        viewport.attachSceneWorld(world, loadResult: result)
        viewport.setViewportSize(Size(width: 800, height: 600))
    }

    func transform() throws -> Transform {
        let model = try EditorSceneModel.decode(from: content)
        let typed = try #require(model.entities.first { $0.id == "selected" }?.components[EditorBuiltInComponentType.transform])
        return try #require(EditorComponentPayloadDecoder.decode(Transform.self, payload: typed) as? Transform)
    }

    func runtimeTransform() throws -> Transform {
        let id = try #require(runtimeID)
        return try #require(world.get(Transform.self, from: id))
    }

    func drag(from start: Point, to end: Point) throws {
        for (phase, point) in [(MouseEvent.Phase.began, start), (.changed, end), (.ended, end)] {
            #expect(viewport.handleInput(MouseEvent(window: .empty, button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0)))
        }
    }
}
