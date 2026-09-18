@_spi(Internal) @testable import AdaApp
@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor
@testable import AdaPhysics

@MainActor
@Suite(.serialized)
struct EditorPhysicsInspectorTests {
    private let typeName = EditorBuiltInComponentType.physicsBody2D

    @Test("New physics components have decodable defaults and editable fields")
    func defaultsAndLegacyPayload() throws {
        EditorComponentRegistry.registerBuiltIns()
        let descriptor = try #require(EditorComponentRegistry.descriptor(named: typeName))
        let payload = descriptor.makeDefaultPayload()
        let body = try #require(EditorComponentRegistry.decode(typeName: typeName, payload: payload) as? PhysicsBody2DComponent)
        #expect(body.mode == .dynamic)
        #expect(body.shapes.count == 1)
        #expect(body.filter.collisionBitMask == .all)
        #expect(!descriptor.fields.contains { $0.key == "runtimeBody" })
        #expect(descriptor.fields.allSatisfy(\.isEditable))
        #expect(descriptor.fields.first { $0.key == "mode" }?.displayValue(in: payload) == "dynamic")

        let legacy = payload.filter { !["fixedRotation", "gravityScale", "linearVelocity", "angularVelocity", "debugColor"].contains($0.key) }
        let decoded = try JSONDecoder().decode(PhysicsBody2DComponent.self, from: JSONEncoder().encode(legacy))
        #expect(!decoded.fixedRotation)
        #expect(decoded.gravityScale == 1)
        #expect(decoded.linearVelocity == .zero)
        #expect(decoded.angularVelocity == 0)
        #expect(try EditorComponentRegistry.decode(typeName: typeName, payload: [:]) is PhysicsBody2DComponent)
    }

    @Test("Inspector edits survive YAML, disk, and runtime component decoding")
    func editAndReload() throws {
        var scene = EditorSceneModel.default(projectName: "Physics")
        let entity = scene.addEntity(preset: .empty)
        scene.addComponent(typeName: typeName, to: entity.id)
        let descriptor = EditorComponentRegistry.physicsBody2DDescriptor
        for (key, value) in [
            ("mode", "kinematic"), ("isTrigger", "true"), ("fixedRotation", "true"),
            ("gravityScale", "0.25"), ("linearVelocity", "2, 3"), ("angularVelocity", "0.75"),
            ("material.friction", "0.3"), ("material.restitution", "0.4"), ("material.density", "2"),
            ("massProperties.mass", "5"), ("massProperties.inertia.z", "3"),
            ("filter.categoryBitMask", "9223372036854775808"), ("filter.collisionBitMask", "18446744073709551615"),
            ("debugColor", "0.2, 0.4, 0.6, 1"),
        ] {
            let field = try #require(descriptor.fields.first { $0.key == key })
            scene.updateField(typeName: typeName, field: field, value: value, in: entity.id)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("physics-\(UUID().uuidString).ascn")
        defer { try? FileManager.default.removeItem(at: url) }
        try scene.encodedYAML().write(to: url, atomically: true, encoding: .utf8)
        let restored = try EditorSceneModel.decode(from: String(contentsOf: url, encoding: .utf8))
        let payload = try #require(restored.entities.first { $0.id == entity.id }?.components[typeName])
        let body = try #require(EditorComponentRegistry.decode(typeName: typeName, payload: payload) as? PhysicsBody2DComponent)
        #expect(body.mode == .kinematic)
        #expect(body.isTrigger && body.fixedRotation)
        #expect(body.gravityScale == 0.25)
        #expect(body.linearVelocity == Vector2(2, 3))
        #expect(body.angularVelocity == 0.75)
        #expect(body.material.friction == 0.3 && body.material.restitution == 0.4 && body.material.density == 2)
        #expect(body.massProperties.mass == 5 && body.massProperties.inertia == Vector3(0, 0, 3))
        #expect(body.filter.categoryBitMask.rawValue == 1 << 63)
        #expect(body.filter.collisionBitMask == .all)
        #expect(body.debugColor == Color(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        let roundTrip = try JSONDecoder().decode(PhysicsBody2DComponent.self, from: JSONEncoder().encode(body))
        #expect(roundTrip.fixedRotation && roundTrip.gravityScale == 0.25)
        #expect(roundTrip.linearVelocity == Vector2(2, 3) && roundTrip.angularVelocity == 0.75)
    }

    @Test("Saved motion settings reach an actual Box2D body")
    func settingsReachSimulation() async throws {
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(Physics2DPlugin()).addPlugin(TransformPlugin())
        try await app.build()
        var body = PhysicsBody2DComponent(shapes: [.generateBox()], mass: 1)
        body.gravityScale = 0
        body.linearVelocity = Vector2(2, 0)
        body.angularVelocity = 0.5
        body.massProperties.inertia.z = 3
        let saved = try JSONEncoder().encode(body)
        let restored = try JSONDecoder().decode(PhysicsBody2DComponent.self, from: saved)
        let entity = app.main.spawn {
            restored
            Transform()
        }
        await app.main.runScheduler(.physicsSync)
        let live = try #require(entity.components[PhysicsBody2DComponent.self])
        #expect(live.runtimeBody != nil)
        #expect(live.gravityScale == 0 && live.linearVelocity == Vector2(2, 0) && live.angularVelocity == 0.5)
        #expect(live.runtimeBody?.massData.rotationalInertia == 3)
        let world = try #require(app.main.physicsWorld2D)
        world.updateSimulation(1.0 / 60.0)
        await app.main.runScheduler(.physicsWriteback)
        #expect(try #require(entity.components[Transform.self]).position.x > 0)
        #expect(abs(try #require(entity.components[Transform.self]).position.y) < 0.0001)
    }

    @Test("Real inspector controls change mode, fixed rotation, and the shape list")
    func liveControls() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "PhysicsInspector")))
        }
        var scene = EditorSceneModel.default(projectName: "Physics UI")
        let entity = scene.addEntity(preset: .empty)
        scene.addComponent(typeName: typeName, to: entity.id)
        let viewport = EditorSceneViewportModel()
        defer { viewport.disconnect() }
        let inspector = EditorInspectorSidebarViewModel()
        let result = viewport.configure(sceneContent: try scene.encodedYAML(), onSelectionChanged: { inspector.selectEntity($0) }, onDocumentContentChanged: { _ in })
        #expect(result?.warnings.isEmpty != false)
        inspector.updateComponentField = { type, field, value in scene.updateField(typeName: type, field: field, value: value, in: entity.id) }
        let container = UIContainerView(rootView: EditorInspectorSidebar(viewModel: inspector))
        container.frame = Rect(x: 0, y: 0, width: 380, height: 900)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        var menu: ContextMenuPresentation?
        let previous = ContextMenuPresentationCenter.present
        ContextMenuPresentationCenter.present = { menu = $0 }
        defer { ContextMenuPresentationCenter.present = previous }
        let mode = UINodeSelector.accessibilityIdentifier("AdaEditor.Inspector.Enum.\(typeName).mode")
        _ = try container.uiScrollToNode(matching: mode)
        let modeRect = try container.uiNode(matching: mode).absoluteFrame
        container.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: Point(modeRect.midX, modeRect.midY), phase: .began, modifierKeys: [], time: 0))
        container.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: Point(modeRect.midX, modeRect.midY), phase: .ended, modifierKeys: [], time: 0.1))
        let chooseMode = try #require(menu?.items.first { $0.title == "kinematic" }?.action)
        chooseMode()
        let toggle = UINodeSelector.accessibilityIdentifier("AdaEditor.Inspector.Bool.\(typeName).fixedRotation")
        _ = try container.uiScrollToNode(matching: toggle)
        _ = try container.uiTapNode(matching: toggle)
        let add = UINodeSelector.accessibilityIdentifier("AdaEditor.Physics.Shapes.Add")
        _ = try container.uiScrollToNode(matching: add)
        _ = try container.uiTapNode(matching: add)
        let addCircle = try #require(menu?.items.first { $0.title == "Circle" }?.action)
        addCircle()
        for _ in 0..<10 {
            await Task.yield()
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        let remove = UINodeSelector.accessibilityIdentifier("AdaEditor.Physics.Shapes.Remove.0")
        _ = try container.uiScrollToNode(matching: remove)
        _ = try container.uiTapNode(matching: remove)
        for _ in 0..<10 {
            await Task.yield()
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        try enterOffset(in: container)
        let payload = try #require(scene.entities.first { $0.id == entity.id }?.components[typeName])
        let body = try #require(EditorComponentRegistry.decode(typeName: typeName, payload: payload) as? PhysicsBody2DComponent)
        #expect(body.mode == .kinematic && body.fixedRotation)
        #expect(body.shapes == [.generateCircle(radius: 1).offsetBy(x: -0.5, y: 0)])
    }

    private func enterOffset<Content: View>(in container: UIContainerView<Content>) throws {
        let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Physics.Shapes.0.offset.x")
        _ = try container.uiScrollToNode(matching: selector)
        _ = try container.uiTapNode(matching: selector)
        #expect(container.uiPerformTextEditingCommand(.selectAll))
        for character in ["-", "0", ".", "5"] {
            container.onTextInputEvent(TextInputEvent(window: RID(), text: character, action: .insert, time: 0))
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
    }
}
