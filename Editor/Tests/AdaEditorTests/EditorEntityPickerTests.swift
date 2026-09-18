@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Testing

@testable import AdaEditor

@MainActor
@Suite(.serialized)
struct EditorEntityPickerTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "EntityPickerTests")))
        }
        EditorComponentRegistry.registerBuiltIns()
    }

    @Test("entity templates create useful component bundles")
    func templatesCreateComponentBundles() throws {
        var model = EditorSceneModel.default(projectName: "Templates")
        let rootID = try #require(model.rootEntityID)

        let scriptable = model.addEntity(template: .scriptable, parentID: rootID)
        let camera2D = model.addEntity(template: .camera2D, parentID: rootID)
        let camera3D = model.addEntity(template: .camera3D, parentID: rootID)
        let tileMap = model.addEntity(template: .tileMap, parentID: rootID)
        let model3D = model.addEntity(template: .model3D, parentID: rootID)
        let pointLight = model.addEntity(template: .pointLight3D, parentID: rootID)
        let spotLight = model.addEntity(template: .spotLight3D, parentID: rootID)

        #expect(scriptable.components[EditorBuiltInComponentType.scriptableComponents]?["scripts"] == .array([]))
        #expect(camera2D.components[EditorBuiltInComponentType.camera]?["projection"] == .string("orthographic"))
        #expect(camera3D.components[EditorBuiltInComponentType.camera]?["projection"] == .string("perspective"))
        #expect(camera3D.components[EditorBuiltInComponentType.transform]?["position"] == .array([.double(0), .double(0), .double(5)]))
        #expect(camera3D.components[EditorBuiltInComponentType.visibility] != nil)
        #expect(tileMap.components[EditorBuiltInComponentType.tileMap]?["tileDisplaySize"] == .array([.double(16), .double(16)]))
        #expect(model3D.components[EditorBuiltInComponentType.mesh3D] != nil)
        #expect(model3D.components[EditorBuiltInComponentType.visibility] != nil)
        #expect(pointLight.components[EditorBuiltInComponentType.pointLight3D] != nil)
        #expect(spotLight.components[EditorBuiltInComponentType.spotLight3D] != nil)
        #expect([scriptable, camera2D, camera3D, tileMap, model3D, pointLight, spotLight].allSatisfy { $0.parent == rootID })

        let world = World(name: "EntityTemplateRuntime")
        let result = EditorSceneFileLoader.load(model: model, into: world, loadsScriptableObjects: false)
        #expect(result.warnings.isEmpty, Comment(rawValue: result.warnings.joined(separator: "\n")))
        let cameraID = try #require(result.entitiesByEditorID[camera3D.id])
        let runtimeCamera = try #require(world.get(Camera.self, from: cameraID))
        guard case .perspective = runtimeCamera.projection else {
            Issue.record("Camera 3D did not use a perspective projection")
            return
        }
        #expect(world.get(CameraRenderGraph.self, from: cameraID) != nil)
        #expect(world.get(VisibleEntities.self, from: cameraID) != nil)
        #expect(world.get(GlobalViewUniform.self, from: cameraID) != nil)
        #expect(world.get(Environment3D.self, from: cameraID) != nil)
        let tileMapID = try #require(result.entitiesByEditorID[tileMap.id])
        #expect(world.get(TileMapComponent.self, from: tileMapID)?.tileDisplaySize == Size(width: 16, height: 16))
    }

    @Test("hierarchy picker filters bundles and creates the selected child")
    func pickerFiltersAndCreatesChild() throws {
        let model = EditorSceneModel.default(projectName: "Picker")
        let rootID = try #require(model.rootEntityID)
        let content = try model.encodedYAML()
        let document = EditorSceneDocument(
            id: "scene:picker",
            title: "Picker.ascn",
            relativePath: "Assets/Scenes/Picker.ascn",
            absolutePath: nil,
            content: content,
            lastSavedContent: content,
            isReadOnly: false,
            sceneModel: model,
            errorMessage: nil,
            isDirty: false,
            statusMessage: nil,
            loadSummary: EditorSceneFileLoader.summary(from: content)
        )
        let workbench = EditorWorkbenchViewModel(openDocuments: [.scene(document)], activeDocumentID: document.id)
        let request = EditorEntityPickerRequest(documentID: document.id, parentID: rootID)
        workbench.entityPickerRequest = request
        let container = UIContainerView(rootView: EditorEntityPickerDialog(workbench: workbench, request: request).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1_000, height: 760)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.EntityPicker.Dialog"))
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.EntityPicker.Group.2D"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.EntityPicker.camera3D"))

        let updated = try #require(workbench.sceneDocument(id: document.id)?.sceneModel)
        let camera = try #require(updated.entities.first { $0.name == EditorSceneEntityTemplate.camera3D.title })
        #expect(camera.parent == rootID)
        #expect(camera.components[EditorBuiltInComponentType.camera]?["projection"] == .string("perspective"))
        #expect(workbench.entityPickerRequest == nil)
    }
}
