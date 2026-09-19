@_spi(Internal) @testable import AdaApp
@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor
@testable import AdaPhysics

@MainActor
@Suite(.serialized)
struct Editor3DComponentCatalogTests {
    private var types: [String] {
        [
            EditorBuiltInComponentType.physicsBody3D,
            EditorBuiltInComponentType.directionalLight3D,
            EditorBuiltInComponentType.mesh3D,
            EditorBuiltInComponentType.environment3D,
        ]
    }

    @Test("Environment 3D uses explicit controls and decodes legacy empty payloads")
    func environment3DControlsAndDefaults() throws {
        EditorComponentRegistry.registerBuiltIns()
        let descriptor = try #require(EditorComponentRegistry.descriptor(named: EditorBuiltInComponentType.environment3D))
        #expect(descriptor.fields.first { $0.key == "skybox.texture" }?.kind == .assetReference)
        #expect(descriptor.fields.first { $0.key == "skybox.isEnabled" }?.kind == .bool)
        #expect(descriptor.fields.first { $0.key == "screenSpaceReflection.isEnabled" }?.kind == .bool)

        let legacy = try #require(EditorComponentRegistry.decode(typeName: EditorBuiltInComponentType.environment3D, payload: [:]) as? Environment3D)
        #expect(legacy.skybox.isEnabled)
        #expect(legacy.screenSpaceReflection.isEnabled)

        var payload = descriptor.makeDefaultPayload()
        let skyboxEnabled = try #require(descriptor.fields.first { $0.key == "skybox.isEnabled" })
        let reflectionEnabled = try #require(descriptor.fields.first { $0.key == "screenSpaceReflection.isEnabled" })
        skyboxEnabled.write("false", to: &payload)
        reflectionEnabled.write("false", to: &payload)
        let edited = try #require(EditorComponentRegistry.decode(typeName: EditorBuiltInComponentType.environment3D, payload: payload) as? Environment3D)
        #expect(!edited.skybox.isEnabled)
        #expect(!edited.screenSpaceReflection.isEnabled)

        var scene = EditorSceneModel.default(projectName: "Legacy Environment")
        let rootID = try #require(scene.rootEntityID)
        let rootIndex = try #require(scene.entities.firstIndex { $0.id == rootID })
        scene.entities[rootIndex].components[EditorBuiltInComponentType.environment3D] = [:]
        let result = EditorSceneFileLoader.load(model: scene, into: World(), loadsScriptableObjects: false)
        #expect(result.warnings.isEmpty, Comment(rawValue: result.warnings.joined(separator: "\n")))
    }

    @Test("3D components are available before scene plugins start")
    func catalogue() throws {
        EditorComponentRegistry.registerBuiltIns()
        let available = EditorComponentRegistry.addableDescriptors(for: nil)
        for type in types {
            let descriptor = try #require(available.first { $0.typeName == type })
            #expect(descriptor.category == "3D")
            #expect(!descriptor.makeDefaultPayload().isEmpty)
            #expect(RuntimeTypeRegistry.componentType(named: type) != nil)
        }
    }

    @Test("Search spans the dialog width and each 3D component can be added", arguments: [1024, 560])
    func dialogLayoutAndAdding(width: Int) async throws {
        prepareRenderer()
        var scene = EditorSceneModel.default(projectName: "3D catalogue")
        let entity = scene.addEntity(preset: .empty)
        let viewport = EditorSceneViewportModel()
        defer { viewport.disconnect() }
        let model = EditorInspectorSidebarViewModel()
        viewport.configure(sceneContent: try scene.encodedYAML(), onSelectionChanged: { model.selectEntity($0) }, onDocumentContentChanged: { _ in })
        model.addComponent = { scene.addComponent(typeName: $0, to: entity.id) }
        let container = UIContainerView(rootView: EditorAddComponentDialog(viewModel: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: Float(width), height: 900)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let dialog = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AddComponent.Dialog"))
        let search = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AddComponent.SearchBar"))
        #expect(abs(search.absoluteFrame.width - (dialog.absoluteFrame.width - 40)) < 0.1)
        #expect(abs(search.absoluteFrame.minX - dialog.absoluteFrame.minX - 20) < 0.1)
        model.componentSearchText = "3D"
        for _ in 0..<10 {
            await Task.yield()
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        let searched = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AddComponent.SearchBar"))
        #expect(searched.absoluteFrame.width == search.absoluteFrame.width)
        for type in types {
            #expect(model.addableComponents(matching: "3D").contains { $0.typeName == type })
            let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Inspector.AddComponent.\(type)")
            _ = try container.uiScrollToNode(matching: selector)
            _ = try container.uiTapNode(matching: selector)
            #expect(scene.entities.first { $0.id == entity.id }?.components[type] != nil)
        }
        let world = World()
        let result = EditorSceneFileLoader.load(content: try scene.encodedYAML(), into: world, loadsScriptableObjects: false)
        #expect(result.warnings.isEmpty)
        let runtimeID = try #require(result.entitiesByEditorID[entity.id])
        let live = try #require(world.getEntityByID(runtimeID))
        #expect(live.components[PhysicsBody3DComponent.self] != nil)
        #expect(live.components[DirectionalLightComponent.self] != nil)
        #expect(live.components[Mesh3DComponent.self] != nil)
    }

    @Test("Saved physics settings initialize a real 3D body and move it")
    func physicsRuntime() async throws {
        var payload = EditorComponentRegistry.physicsBody3DDescriptor.makeDefaultPayload()
        let fields = EditorComponentRegistry.physicsBody3DDescriptor.fields
        for (key, value) in [("gravityScale", "0"), ("linearVelocity", "2, 0, 0"), ("angularVelocity", "0, 0.5, 0")] {
            let field = try #require(fields.first { $0.key == key })
            field.write(value, to: &payload)
        }
        let component = try #require(EditorComponentRegistry.decode(typeName: EditorBuiltInComponentType.physicsBody3D, payload: payload) as? PhysicsBody3DComponent)
        let restored = try JSONDecoder().decode(PhysicsBody3DComponent.self, from: JSONEncoder().encode(component))
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(Physics3DPlugin()).addPlugin(TransformPlugin())
        try await app.build()
        let entity = app.main.spawn {
            restored
            Transform()
        }
        await app.main.runScheduler(.physicsSync)
        let body = try #require(entity.components[PhysicsBody3DComponent.self])
        #expect(body.runtimeBody != nil)
        #expect(body.gravityScale == 0 && body.linearVelocity == Vector3(2, 0, 0))
        #expect(body.angularVelocity == Vector3(0, 0.5, 0))
        let physics = try #require(app.main.physicsWorld3D)
        physics.updateSimulation(1.0 / 60.0)
        await app.main.runScheduler(.physicsWriteback)
        let transform = try #require(entity.components[Transform.self])
        #expect(transform.position.x > 0 && abs(transform.position.y) < 0.0001)
    }

    @Test("3D collision shapes and light settings survive serialization")
    func fieldsAndShapes() throws {
        for kind in EditorPhysicsShapeValue.kinds(is3D: true) {
            let shape = EditorPhysicsShapeValue.make(kind, is3D: true)
            let decoded = try JSONDecoder().decode(Shape3DResource.self, from: JSONEncoder().encode(shape))
            #expect(decoded == (kind == .sphere ? .generateSphere(radius: 0.5) : .generateBox()))
        }
        var payload = EditorComponentRegistry.directionalLight3DDescriptor.makeDefaultPayload()
        for (key, value) in [("radiance", "0.2, 0.4, 0.6"), ("intensity", "2"), ("castShadows", "false")] {
            let field = try #require(EditorComponentRegistry.directionalLight3DDescriptor.fields.first { $0.key == key })
            field.write(value, to: &payload)
        }
        let light = try #require(EditorComponentRegistry.decode(typeName: EditorBuiltInComponentType.directionalLight3D, payload: payload) as? DirectionalLightComponent)
        #expect(light.radiance == Vector3(0.2, 0.4, 0.6) && light.intensity == 2 && !light.castShadows)
    }

    private func prepareRenderer() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "3DCatalogueUI")))
        }
    }
}
