@_spi(AdaEngine) import AdaEngine
// Different SPI groups expose independent test-only APIs.
// swiftlint:disable:next duplicate_imports
@_spi(Internal) import AdaEngine
import Foundation
import Testing

@testable import AdaCorePipelines
@testable import AdaEditor

private enum EditorReflectionMode: String, CaseIterable, ReflectedEnum, Codable, Sendable {
    case idle
    case active
}

@Component
private struct EditorReflectedComponent: Codable, Sendable {
    var color: Color
    var offset: Vector2
    var mode: EditorReflectionMode

    init(color: Color = .white, offset: Vector2 = .zero, mode: EditorReflectionMode = .idle) {
        self.color = color
        self.offset = offset
        self.mode = mode
    }
}

private actor EditorRenderCompletionProbe {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

@Suite("Editor scene editing")
struct EditorSceneEditingTests {
    @Test("component registry exposes built-in editable descriptors")
    func componentRegistryBuiltIns() throws {
        let transform = try #require(EditorComponentRegistry.descriptor(named: EditorBuiltInComponentType.transform))
        let sprite = try #require(EditorComponentRegistry.descriptor(named: EditorBuiltInComponentType.sprite))

        #expect(transform.displayName == "Transform")
        #expect(transform.fields.map(\.key) == ["position", "rotation", "scale"])
        #expect(sprite.requiredComponentTypeNames == [EditorBuiltInComponentType.visibility])

        let decoded = try EditorComponentRegistry.decode(
            typeName: EditorBuiltInComponentType.transform,
            payload: transform.makeDefaultPayload()
        )
        #expect(decoded is Transform)
    }

    @Test("component registry adapts reflected component descriptors")
    func componentRegistryReflectsGeneratedDescriptors() throws {
        ComponentReflectionRegistry.register(EditorReflectedComponent.componentDescriptor)

        let descriptor = try #require(EditorComponentRegistry.descriptor(named: String(reflecting: EditorReflectedComponent.self)))

        #expect(descriptor.displayName == "EditorReflectedComponent")
        #expect(descriptor.fields.map(\.key) == ["color", "offset", "mode"])
        #expect(descriptor.fields.first { $0.key == "color" }?.kind == .color)
        #expect(descriptor.fields.first { $0.key == "offset" }?.kind == .vector2)
        #expect(descriptor.fields.first { $0.key == "mode" }?.kind == .enumeration(["idle", "active"]))
    }

    @Test("enumeration field edits normalize invalid values")
    func enumerationFieldEditsNormalizeInvalidValues() throws {
        var payload = EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.visibility)
        let descriptor = try #require(EditorComponentRegistry.descriptor(named: EditorBuiltInComponentType.visibility))
        let field = try #require(descriptor.fields.first { $0.key == "value" })

        field.write("not-a-case", to: &payload)

        #expect(payload["value"] == .string("visible"))
    }

    @Test("scene model adds entities and required editable components")
    func sceneModelAddsEntityAndComponents() throws {
        var model = EditorSceneModel.default(projectName: "Editing")

        let entity = model.addEntity()
        model.addComponent(typeName: EditorBuiltInComponentType.sprite, to: entity.id)

        let editedEntity = try #require(model.entities.first { $0.id == entity.id })
        #expect(editedEntity.parent == "root")
        #expect(editedEntity.components[EditorBuiltInComponentType.transform] != nil)
        #expect(editedEntity.components[EditorBuiltInComponentType.sprite] != nil)
        #expect(editedEntity.components[EditorBuiltInComponentType.visibility] != nil)

        let content = try model.encodedYAML()
        let decoded = try EditorSceneModel.decode(from: content)
        #expect(decoded.entities.count == 2)
        #expect(decoded.editor?.selectedEntity == entity.id)
    }

    @Test("scene creation presets add useful component sets")
    func sceneCreationPresetsAddComponents() throws {
        var model = EditorSceneModel.default(projectName: "Presets")

        let camera = model.addEntity(preset: .camera)
        let sprite = model.addEntity(preset: .sprite)
        let light = model.addEntity(preset: .light2D)

        #expect(model.entities.first { $0.id == camera.id }?.components[EditorBuiltInComponentType.camera] != nil)
        #expect(model.entities.first { $0.id == sprite.id }?.components[EditorBuiltInComponentType.sprite] != nil)
        #expect(model.entities.first { $0.id == sprite.id }?.components[EditorBuiltInComponentType.visibility] != nil)
        #expect(model.entities.first { $0.id == light.id }?.components[EditorBuiltInComponentType.light2D] != nil)
    }

    @Test("AdaScript scriptable objects round-trip through scene YAML and runtime loading")
    @MainActor
    func scriptableObjectsRoundTripThroughSceneRuntime() throws {
        let fileManager = FileManager.default
        let projectURL = fileManager.temporaryDirectory
            .appendingPathComponent("EditorScriptables-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: projectURL) }
        let sourcesURL = projectURL.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
        let identifier = "editor.test.\(UUID().uuidString)"
        try """
        @scriptable(id: "\(identifier)", version: 2)
        class SceneController {
            @export var speed = 4.5;
            @export var enabled = true;
            @component(required: true) var transform: Transform;
        }
        """
        .write(to: sourcesURL.appendingPathComponent("SceneController.ada"), atomically: true, encoding: .utf8)
        let project = ProjectSystem.defaultProject(projectName: "ScriptableScene", buildSystem: .adaScript)
        let support = try EditorScriptableObjectCatalogLoader.load(project: project, at: projectURL, fileManager: fileManager)
        let descriptor = try #require(support.descriptors.first)
        var model = EditorSceneModel.default(projectName: "ScriptableScene")
        let entityID = try #require(model.editor?.selectedEntity)

        model.addScriptableObject(descriptor, to: entityID)
        model.updateScriptableObjectField(
            identifier: identifier,
            field: EditorComponentField(key: "speed", label: "speed", kind: .float),
            value: "9.25",
            in: entityID
        )
        let decodedModel = try EditorSceneModel.decode(from: model.encodedYAML())
        var app = AppWorlds(main: World(name: "EditorScriptableSceneRuntime"))
        EditorComponentRegistry.registerBuiltIns()
        app.addPlugin(ScriptableObjectPlugin())
        try support.playRuntime.install(in: &app)
        let loadResult = EditorSceneFileLoader.load(model: decodedModel, into: app.main)
        let runtimeEntityID = try #require(loadResult.entitiesByEditorID[entityID])
        let scripts = try #require(app.main.get(ScriptableComponents.self, from: runtimeEntityID)?.scripts)

        #expect(support.descriptors.map(\.identifier) == [identifier])
        #expect(scripts.count == 1)
        #expect(loadResult.warnings.isEmpty)
    }

    @Test("scene hierarchy builds visible rows with components and resources")
    func sceneHierarchyBuildsVisibleRows() throws {
        var model = EditorSceneModel.default(projectName: "Hierarchy")
        let parent = model.addEntity(name: "Player")
        let child = model.addEntity(name: "Sprite")
        let childIndex = try #require(model.entities.firstIndex { $0.id == child.id })
        model.entities[childIndex].components[EditorBuiltInComponentType.sprite] = EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.sprite)
        model.entities[childIndex].components[EditorBuiltInComponentType.sprite]?["texture"] = .string("Assets/Textures/player.png")
        model.selectEntity(model.entities[childIndex].id)

        let items = EditorSceneHierarchyModel.visibleItems(for: model)
        let childItem = try #require(items.first { $0.id == child.id })

        #expect(items.map(\.name).contains("Root"))
        #expect(childItem.level == 2)
        #expect(child.parent == parent.id)
        #expect(childItem.componentNames.contains("Sprite"))
        #expect(
            childItem.resources == [
                EditorSceneHierarchyResource(componentName: "Sprite", fieldName: "Texture", value: "Assets/Textures/player.png")
            ]
        )
        #expect(EditorSceneHierarchyIcon.symbol(for: childItem) == EditorSceneHierarchyIcon.image)
    }

    @Test("hierarchy entity commands preserve a valid parent-child tree")
    func hierarchyEntityCommandsPreserveTree() throws {
        var model = EditorSceneModel.default(projectName: "Hierarchy Commands")
        let rootID = try #require(model.rootEntityID)
        let parent = model.addEntity(name: "Parent", parentID: rootID)
        let child = model.addEntity(name: "Child", parentID: parent.id)

        let didRename = model.renameEntity(child.id, to: "Renamed Child")
        let didHide = model.setEntityEnabled(child.id, isEnabled: false)
        #expect(didRename)
        #expect(didHide)
        #expect(model.entities.first(where: { $0.id == child.id })?.name == "Renamed Child")
        #expect(model.entities.first(where: { $0.id == child.id })?.enabled == false)
        #expect(!model.canReparentEntity(parent.id, to: child.id))
        let didReparentRoot = model.reparentEntity(rootID, to: child.id)
        let didReparentChild = model.reparentEntity(child.id, to: rootID)
        #expect(!didReparentRoot)
        #expect(didReparentChild)
        #expect(model.entities.first(where: { $0.id == child.id })?.parent == rootID)

        let didDeleteParent = model.deleteEntity(parent.id)
        #expect(didDeleteParent)
        #expect(!model.entities.contains(where: { $0.id == parent.id }))
        #expect(model.entities.contains(where: { $0.id == child.id }))
        let didDeleteRoot = model.deleteEntity(rootID)
        #expect(!didDeleteRoot)
    }

    @Test("duplicate copy paste and scene prefab commands preserve subtrees")
    func hierarchyClipboardAndPrefabCommandsPreserveSubtrees() throws {
        var model = EditorSceneModel.default(projectName: "Hierarchy Clipboard")
        let rootID = try #require(model.rootEntityID)
        let parent = model.addEntity(name: "Parent", parentID: rootID)
        let child = model.addEntity(name: "Child", parentID: parent.id)

        let duplicatedEntity = model.duplicateEntity(parent.id)
        let duplicate = try #require(duplicatedEntity)
        let duplicateChildren = model.entities.filter { $0.parent == duplicate.id }
        #expect(duplicate.name == "Parent Copy")
        #expect(duplicate.parent == rootID)
        #expect(duplicateChildren.count == 1)
        #expect(duplicateChildren.first?.name == child.name)

        let payload = try #require(model.clipboardPayload(for: parent.id))
        #expect(EditorSceneModel.canPasteEntityPayload(payload))
        #expect(!EditorSceneModel.canPasteEntityPayload("not an AdaEditor entity"))
        let pastedEntity = model.pasteEntity(from: payload, parentID: duplicate.id)
        let pasted = try #require(pastedEntity)
        #expect(pasted.parent == duplicate.id)
        #expect(model.entities.filter { $0.parent == pasted.id }.count == 1)

        let prefab = model.addSceneInstance(parentID: rootID)
        #expect(prefab.parent == rootID)
        #expect(prefab.components[EditorBuiltInComponentType.sceneInstance] != nil)

        let roundTrippedModel = try EditorSceneModel.decode(from: model.encodedYAML())
        #expect(roundTrippedModel == model)
    }

    @Test("middle mouse drag pans the 2D viewport without changing selection")
    @MainActor
    func middleMouseDragPans2DViewport() {
        let viewportModel = EditorSceneViewportModel()
        var selectedEntityID: String?
        viewportModel.onSelectEntity = { selectedEntityID = $0 }

        #expect(viewportModel.handleInput(mouseEvent(button: .middle, position: Point(x: 100, y: 100), phase: .began)))
        #expect(viewportModel.handleInput(mouseEvent(button: .middle, position: Point(x: 124, y: 88), phase: .changed)))
        #expect(viewportModel.twoDCenter == Vector2(-24, -12))
        #expect(viewportModel.handleInput(mouseEvent(button: .middle, position: Point(x: 124, y: 88), phase: .ended)))
        #expect(selectedEntityID == nil)
    }

    private func mouseEvent(button: MouseButton, position: Point, phase: MouseEvent.Phase) -> MouseEvent {
        MouseEvent(
            window: RID(),
            button: button,
            mousePosition: position,
            phase: phase,
            modifierKeys: [],
            time: 0
        )
    }

    @Test("scene model expands ancestors when selecting child entity")
    func sceneModelExpandsSelectedEntityAncestors() throws {
        var model = EditorSceneModel.default(projectName: "Expanded")
        let rootID = try #require(model.entities.first?.id)
        let parent = model.addEntity(name: "Parent")
        let child = model.addEntity(name: "Child")
        model.editor?.expandedEntities = []

        model.selectEntity(child.id)

        #expect(model.editor?.selectedEntity == child.id)
        #expect(model.editor?.expandedEntities == [rootID, parent.id, child.id])
    }

    @Test("component field edits update runtime component through scene loader")
    @MainActor
    func componentFieldEditUpdatesRuntimeWorld() throws {
        var model = EditorSceneModel.default(projectName: "Runtime")
        let rootID = try #require(model.entities.first?.id)
        let transformDescriptor = try #require(EditorComponentRegistry.descriptor(named: EditorBuiltInComponentType.transform))
        let positionField = try #require(transformDescriptor.fields.first { $0.key == "position" })
        model.updateField(typeName: EditorBuiltInComponentType.transform, field: positionField, value: "10, 20, 0", in: rootID)

        let world = World()
        let result = EditorSceneFileLoader.load(model: model, into: world)
        let entityID = try #require(result.entitiesByEditorID[rootID])
        let transform = try #require(world.get(Transform.self, from: entityID))

        #expect(transform.position == Vector3(10, 20, 0))
    }

    @Test("picking helpers use 2D fallback bounds and nearest 3D ray hit")
    func pickingMath() throws {
        let transform = Transform(position: Vector3(2, 3, 0))
        #expect(EditorPicking.contains2D(Vector2(2.1, 3.1), transform: transform, bounds: nil))
        #expect(!EditorPicking.contains2D(Vector2(4, 3), transform: transform, bounds: nil))

        let ray = Ray(origin: Vector3(0, 0, -5), direction: Vector3(0, 0, 1))
        let aabb = AABB(center: .zero, halfExtents: Vector3(1, 1, 1))
        let distance = try #require(EditorPicking.rayAABBIntersectionDistance(ray: ray, aabb: aabb))
        #expect(distance == 4)

        let centerRay = EditorPicking.perspectiveRay(
            point: Point(x: 640, y: 360),
            viewportSize: Size(width: 1280, height: 720),
            cameraPosition: Vector3(0, 0, -5),
            front: Vector3(0, 0, 1),
            right: Vector3(1, 0, 0),
            verticalFieldOfView: .degrees(62)
        )
        #expect(centerRay.direction == Vector3(0, 0, 1))
    }

    @Test("3D viewport raycast selects the nearest scene entity")
    @MainActor
    func viewportRaycastSelectsNearestEntity() throws {
        let cameraPosition = Vector3(0, 6, -10)
        let front = Vector3(0, Math.sin(-0.42), Math.cos(-0.42)).normalized
        var model = EditorSceneModel.default(projectName: "Raycast")
        let entityID = try #require(model.editor?.selectedEntity)
        let transformDescriptor = try #require(EditorComponentRegistry.descriptor(named: EditorBuiltInComponentType.transform))
        let positionField = try #require(transformDescriptor.fields.first { $0.key == "position" })
        let targetPosition = cameraPosition + front * 10
        model.updateField(
            typeName: EditorBuiltInComponentType.transform,
            field: positionField,
            value: "\(targetPosition.x), \(targetPosition.y), \(targetPosition.z)",
            in: entityID
        )
        let content = try model.encodedYAML()
        let world = World()
        let camera = world.spawn("SceneView_Camera") {
            Camera()
            Transform()
        }
        let loadResult = EditorSceneFileLoader.load(content: content, into: world, loadsScriptableObjects: false)
        let viewportModel = EditorSceneViewportModel()
        viewportModel.configure(sceneContent: content, onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in })
        viewportModel.attachSceneWorld(world, loadResult: loadResult)
        viewportModel.setViewportSize(Size(width: 1280, height: 720))
        viewportModel.setDisplayMode(.threeD)

        #expect(viewportModel.pick3D(at: Point(x: 640, y: 360)) == entityID)
        #expect(world.getEntityByID(camera.id) === camera)
    }

    @Test("3D viewport raycast follows the rendered vertical camera axis")
    @MainActor
    func viewportRaycastFollowsRenderedVerticalCameraAxis() throws {
        let model = EditorSceneModel.default(projectName: "Projected Raycast")
        let entityID = try #require(model.editor?.selectedEntity)
        let content = try model.encodedYAML()
        let world = World()
        world.spawn("SceneView_Camera") {
            Camera()
            Transform()
        }
        let loadResult = EditorSceneFileLoader.load(content: content, into: world, loadsScriptableObjects: false)
        let viewportModel = EditorSceneViewportModel()
        let viewportSize = Size(width: 1_280, height: 720)
        viewportModel.configure(sceneContent: content, onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in })
        viewportModel.attachSceneWorld(world, loadResult: loadResult)
        viewportModel.setViewportSize(viewportSize)
        viewportModel.setDisplayMode(.threeD)
        viewportModel.setActiveTool(.select)
        viewportModel.perspectiveBlend = 1

        let projectedOrigin = try #require(viewportModel.project(.zero, size: viewportSize))
        #expect(projectedOrigin.y > viewportSize.height * 0.5)
        #expect(viewportModel.pick3D(at: projectedOrigin) == entityID)

        var cursorSelection: String?
        viewportModel.onSelectEntity = { cursorSelection = $0 }
        #expect(viewportModel.handleInput(mouseEvent(button: .left, position: projectedOrigin, phase: .began)))
        #expect(viewportModel.handleInput(mouseEvent(button: .left, position: projectedOrigin, phase: .ended)))
        #expect(cursorSelection == entityID)
    }

    @Test("scene viewport context menu creates entities and the pill starts Play Mode")
    @MainActor
    func sceneViewportPillControls() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let app = AppWorlds(main: World(name: "EditorSceneViewportPillTests"))
            RenderWorldPlugin().setup(in: app)
        }
        let content = try EditorSceneModel.default(projectName: "Pill").encodedYAML()
        let document = EditorSceneDocument(
            id: "scene:pill",
            title: "Pill.ascn",
            relativePath: "Assets/Scenes/Pill.ascn",
            absolutePath: nil,
            content: content,
            lastSavedContent: content,
            isReadOnly: false,
            sceneModel: EditorSceneFileLoader.model(from: content),
            errorMessage: nil,
            isDirty: false,
            statusMessage: nil,
            loadSummary: EditorSceneFileLoader.summary(from: content)
        )
        var didRequestEntityPicker = false
        var didRequestPlay = false
        var contextMenu: ContextMenuPresentation?
        let previousPresenter = ContextMenuPresentationCenter.present
        ContextMenuPresentationCenter.present = { contextMenu = $0 }
        defer { ContextMenuPresentationCenter.present = previousPresenter }
        let container = UIContainerView(
            rootView: EditorSceneViewportView(
                document: document,
                resourceRootURL: nil,
                inspectorViewModel: EditorInspectorSidebarViewModel(),
                playModeState: .editing,
                playRuntime: nil,
                onEntitySelected: nil,
                onCreateEntity: { didRequestEntityPicker = true },
                onPlay: { didRequestPlay = true },
                onStop: nil,
                onDocumentChanged: { _ in }
            )
        )
        container.frame = Rect(x: 0, y: 0, width: 900, height: 600)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.SceneViewport.Controls"))
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.SceneViewport.Create")).isEmpty)
        let contextSurface = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.SceneViewport.ContextSurface"))
        container.onMouseEvent(
            MouseEvent(
                window: RID(),
                button: .right,
                mousePosition: Point(contextSurface.absoluteFrame.midX, contextSurface.absoluteFrame.midY),
                phase: .began,
                modifierKeys: [],
                time: 0
            )
        )
        contextMenu?.items.first(where: { $0.title == "Create Entity…" })?.action?()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.SceneViewport.Control.Play"))

        #expect(didRequestEntityPicker)
        #expect(didRequestPlay)
    }

    @Test("Play viewport mirrors the highest-order active authored camera")
    @MainActor
    func playViewportUsesAuthoredCamera() throws {
        let world = World()
        let displayCamera = world.spawn("SceneView_Camera") {
            Camera()
            Transform()
        }
        var inactiveCamera = Camera()
        inactiveCamera.isActive = false
        inactiveCamera.renderOrder = 100
        world.spawn("Inactive Camera") {
            inactiveCamera
            Transform(position: Vector3(100, 100, 100))
        }
        var authoredCamera = Camera()
        authoredCamera.projection = .perspective(PerspectiveProjection(fieldOfView: .degrees(72)))
        authoredCamera.backgroundColor = .blue
        authoredCamera.renderOrder = 5
        let authoredTransform = Transform(position: Vector3(2, 3, 7))
        let authoredEnvironment = Environment3D(
            skybox: Skybox3D(intensity: 1.75),
            screenSpaceReflection: ScreenSpaceReflection(isEnabled: false)
        )
        world.spawn("Gameplay Camera") {
            authoredCamera
            authoredTransform
            CameraRenderGraph(subgraphLabel: .main3D, inputSlot: Core3DPlugin.InputNode.view)
            authoredEnvironment
        }

        #expect(EditorSceneViewportView.synchronizePlayCamera(in: world))
        let mirroredCamera = try #require(displayCamera.components[Camera.self])
        guard case let .perspective(projection) = mirroredCamera.projection else {
            Issue.record("Play viewport did not use the authored perspective camera")
            return
        }
        #expect(projection.fieldOfView == .degrees(72))
        #expect(mirroredCamera.backgroundColor == .blue)
        #expect(displayCamera.components[Transform.self] == authoredTransform)
        #expect(displayCamera.components[CameraRenderGraph.self]?.subgraphLabel == .main3D)
        #expect(displayCamera.components[Environment3D.self]?.skybox.intensity == 1.75)
        #expect(displayCamera.components[Environment3D.self]?.screenSpaceReflection.isEnabled == false)
    }

    @Test("scene editor embeds hierarchy beside the viewport")
    @MainActor
    func sceneEditorEmbedsHierarchy() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let app = AppWorlds(main: World(name: "EmbeddedSceneHierarchyTests"))
            RenderWorldPlugin().setup(in: app)
        }
        let content = try EditorSceneModel.default(projectName: "EmbeddedHierarchy").encodedYAML()
        let document = EditorSceneDocument(
            id: "scene:embedded-hierarchy",
            title: "EmbeddedHierarchy.ascn",
            relativePath: "Assets/Scenes/EmbeddedHierarchy.ascn",
            absolutePath: nil,
            content: content,
            lastSavedContent: content,
            isReadOnly: false,
            sceneModel: EditorSceneFileLoader.model(from: content),
            errorMessage: nil,
            isDirty: false,
            statusMessage: nil,
            loadSummary: EditorSceneFileLoader.summary(from: content)
        )
        let workbench = EditorWorkbenchViewModel(openDocuments: [.scene(document)], activeDocumentID: document.id)
        let container = UIContainerView(
            rootView: EditorSceneDocumentEditor(
                document: document,
                workbench: workbench,
                resourceRootURL: nil,
                uiCatalog: .standard,
                inspectorViewModel: EditorInspectorSidebarViewModel(),
                playModeState: .editing,
                playRuntime: nil,
                onEntitySelected: nil,
                onPlay: nil,
                onStop: nil
            )
        )
        container.frame = Rect(x: 0, y: 0, width: 1_100, height: 700)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        let hierarchy = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.SceneEditor.HierarchyPanel"))
        let viewport = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.SceneEditor.ViewportPanel"))
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.SceneHierarchy"))
        #expect(hierarchy.absoluteFrame.minX == 0)
        #expect(hierarchy.absoluteFrame.width == EditorSceneDocumentEditor.hierarchyWidth)
        #expect(viewport.absoluteFrame.minX == EditorSceneDocumentEditor.hierarchyWidth + 1)
        #expect(viewport.absoluteFrame.width == 1_100 - EditorSceneDocumentEditor.hierarchyWidth - 1)
    }

    @Test("2D viewport grid and default entity marker render as quads")
    @MainActor
    func viewportGridAndMarkerRenderAsQuads() throws {
        let viewportModel = EditorSceneViewportModel()
        let content = try EditorSceneModel.default(projectName: "Viewport").encodedYAML()
        viewportModel.configure(sceneContent: content, onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in })

        var gridContext = UIGraphicsContext()
        viewportModel.drawGrid(in: &gridContext, size: Size(width: 320, height: 180), theme: .adaEditor)

        #expect(
            gridContext.getDrawCommands()
                .contains { command in
                    if case .drawQuad = command {
                        return true
                    }
                    return false
                }
        )

        var gizmoContext = UIGraphicsContext()
        viewportModel.drawGizmos(in: &gizmoContext, size: Size(width: 320, height: 180), theme: .adaEditor)

        #expect(
            gizmoContext.getDrawCommands()
                .contains { command in
                    if case .drawQuad = command {
                        return true
                    }
                    return false
                }
        )
    }

    @Test("3D grid projection matches the render camera")
    @MainActor
    func threeDGridProjectionMatchesRenderCamera() async throws {
        let size = Size(width: 1280, height: 720)
        let world = World()
        world.addSystem(TransformSystem.self, on: .preUpdate)
        world.addSystem(CameraSystem.self, on: .preUpdate)
        let cameraEntity = world.spawn("SceneView_Camera") {
            Camera()
            Transform()
        }
        let viewportModel = EditorSceneViewportModel()
        viewportModel.attachSceneWorld(world, loadResult: .empty)
        viewportModel.setViewportSize(size)
        viewportModel.setDisplayMode(.threeD)
        _ = viewportModel.update(deltaTime: 0.5)
        let cameraState = viewportModel.cameraState(for: size)
        let cameraForward = cameraState.transform.matrix.z.xyz.normalized
        let forwardDifference = Vector3(
            cameraForward.x - viewportModel.front3D.x,
            cameraForward.y - viewportModel.front3D.y,
            cameraForward.z - viewportModel.front3D.z
        )
        #expect(forwardDifference.squaredLength < 0.0001)
        await world.runScheduler(.preUpdate)
        await world.runScheduler(.preUpdate)

        let worldPoint = Vector3(6, 0, 14)
        let gridPoint = try #require(viewportModel.project(worldPoint, size: size))
        let uniform = try #require(cameraEntity.components[GlobalViewUniform.self])
        let clipPoint = uniform.viewProjectionMatrix * Vector4(worldPoint, 1)
        let ndc = clipPoint.xyz / clipPoint.w
        let renderPoint = Vector2(
            size.width * (ndc.x + 1) * 0.5,
            size.height * (1 - ndc.y) * 0.5
        )

        let difference = Vector2(gridPoint.x - renderPoint.x, gridPoint.y - renderPoint.y)
        #expect(difference.squaredLength < 0.0001)

        let clippedSegment = try #require(
            viewportModel.clipSegmentToNearPlane(
                start: Vector3(0, 0, -68),
                end: Vector3(0, 0, 48),
                size: size
            )
        )
        #expect(viewportModel.project(clippedSegment.start, size: size) != nil)
        #expect(viewportModel.project(clippedSegment.end, size: size) != nil)

        var gridContext = UIGraphicsContext()
        viewportModel.draw3DGrid(in: &gridContext, size: size, theme: .adaEditor)
        let projectedLineCount = gridContext.getDrawCommands()
            .reduce(into: 0) { count, command in
                if case .drawLine = command {
                    count += 1
                }
            }
        #expect(projectedLineCount > 10)
    }

    @Test("3D ground grid lines reach the UI renderer at their projected screen positions", arguments: [Float(-0.42), 0, -1.45])
    @MainActor
    func groundGridLineScreenCoordinates(pitch: Float) throws {
        let size = Size(width: 1280, height: 720)
        let viewportModel = EditorSceneViewportModel()
        viewportModel.threeDPitch = pitch
        viewportModel.perspectiveBlend = 1
        let center =
            pitch < 0
            ? viewportModel.threeDPosition + viewportModel.front3D * (-viewportModel.threeDPosition.y / viewportModel.front3D.y)
            : Vector3(0, 0, 14)
        let start = center - Vector3(1, 0, 0)
        let end = center + Vector3(1, 0, 0)
        let expectedStart = try #require(viewportModel.project(start, size: size))
        let expectedEnd = try #require(viewportModel.project(end, size: size))
        #expect(expectedStart.y >= size.height * 0.5 - 0.01)
        #expect(expectedStart.y < size.height)

        // Canvas translates its origin in Y-up UI space before executing draws.
        let origin = Vector2(80, 120)
        var context = UIGraphicsContext()
        context.translateBy(x: origin.x, y: -origin.y)
        viewportModel.drawProjectedSegment(
            from: start,
            to: end,
            in: &context,
            size: size,
            lineWidth: 1,
            color: .white
        )
        let command = try #require(context.getDrawCommands().first)
        guard case let .drawLine(lineStart, lineEnd, _, _) = command else {
            Issue.record("Expected a projected grid line")
            return
        }
        // The line tessellator preserves these positions; the UI camera maps
        // negative world Y to positive screen Y, as it does for UI rectangles.
        let uiProjection = Transform3D.orthographic(
            left: 0,
            right: 1600,
            top: 0,
            bottom: -1000,
            zNear: -1,
            zFar: 1
        )
        for (vertex, expected) in [(lineStart, expectedStart), (lineEnd, expectedEnd)] {
            let clip = uiProjection * Vector4(vertex, 1)
            let screen = Vector2((clip.x + 1) * 800, (1 - clip.y) * 500)
            #expect((screen - (origin + expected)).squaredLength < 0.001)
        }
    }

    @Test("viewport reloads edited scene content without recreating camera")
    @MainActor
    func viewportReloadsSceneContentInAttachedWorld() throws {
        var model = EditorSceneModel.default(projectName: "Reload")
        let initialContent = try model.encodedYAML()
        let world = World()
        let cameraEntity = world.spawn("SceneView_Camera") {
            Camera()
            Transform()
            CameraRenderGraph(subgraphLabel: "Scene 2D Render Graph", inputSlot: "view")
        }
        let viewportModel = EditorSceneViewportModel()
        let initialResult = EditorSceneFileLoader.load(content: initialContent, into: world)

        viewportModel.configure(sceneContent: initialContent, onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in })
        viewportModel.attachSceneWorld(world, loadResult: initialResult)

        _ = model.addEntity(name: "Reloaded")
        let updatedContent = try model.encodedYAML()
        let reloadResult = try #require(viewportModel.configure(sceneContent: updatedContent, onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in }))
        let sceneEntities = world.getEntities().filter { $0.id != cameraEntity.id }

        #expect(reloadResult.entityCount == model.entities.count)
        #expect(world.getEntityByID(cameraEntity.id) === cameraEntity)
        #expect(sceneEntities.count == model.entities.count)
        #expect(sceneEntities.contains { $0.name == "Reloaded" })
    }

    @Test("viewport mode animates projection before settling on the target render graph")
    @MainActor
    func viewportModeUpdatesCameraRenderGraph() async throws {
        let world = World()
        world.addSystem(TransformSystem.self, on: .preUpdate)
        world.addSystem(CameraSystem.self, on: .preUpdate)
        world.addSystem(VisibilitySystem.self, on: .preUpdate)
        let cameraEntity = world.spawn("SceneView_Camera") {
            Camera()
            Transform()
            VisibleEntities()
            CameraRenderGraph(subgraphLabel: "Scene 2D Render Graph", inputSlot: "view")
        }
        let visibleEntity = world.spawn("Visible Sprite") {
            Transform()
            BoundingComponent(bounds: .aabb(AABB(center: .zero, halfExtents: Vector3(8, 8, 0))))
            Visibility.visible
        }
        let viewportModel = EditorSceneViewportModel()

        viewportModel.attachSceneWorld(world, loadResult: .empty)
        let viewportSize = Size(width: 640, height: 360)
        viewportModel.setViewportSize(viewportSize)
        await world.runScheduler(.preUpdate)
        #expect(cameraEntity.components[VisibleEntities.self]?.entityIds.contains(visibleEntity.id) == true)
        #expect(cameraEntity.components[Transform.self]?.position.z == EditorSceneViewportModel.twoDCameraDepth)
        let projectedOrigin = try #require(viewportModel.project(.zero, size: viewportSize))
        #expect((projectedOrigin - Vector2(viewportSize.width * 0.5, viewportSize.height * 0.5)).squaredLength < 0.001)
        viewportModel.setDisplayMode(.threeD)

        #expect(viewportModel.perspectiveTransitionProgress == 0)
        #expect(viewportModel.isPerspectiveTransitionActive)
        _ = viewportModel.update(deltaTime: 0.25)

        #expect(abs(viewportModel.perspectiveTransitionProgress - 0.5) < 0.001)
        let transitioningCamera = try #require(cameraEntity.components[Camera.self])
        if case .custom = transitioningCamera.projection {
            // Expected interpolated projection.
        } else {
            Issue.record("Expected a custom projection while transitioning to 3D")
        }

        _ = viewportModel.update(deltaTime: 0.25)

        let threeDGraph = try #require(cameraEntity.components[CameraRenderGraph.self])
        #expect(threeDGraph.subgraphLabel.rawValue == "Scene 3D Render Graph")
        #expect(viewportModel.perspectiveTransitionProgress == 1)
        #expect(!viewportModel.isPerspectiveTransitionActive)
        let threeDCamera = try #require(cameraEntity.components[Camera.self])
        if case .perspective = threeDCamera.projection {
            // Expected final projection.
        } else {
            Issue.record("Expected a perspective projection after the transition")
        }

        viewportModel.setDisplayMode(.twoD)
        _ = viewportModel.update(deltaTime: 0.5)
        await world.runScheduler(.preUpdate)

        let twoDGraph = try #require(cameraEntity.components[CameraRenderGraph.self])
        #expect(twoDGraph.subgraphLabel.rawValue == "Scene 3D Render Graph")
        #expect(cameraEntity.components[Environment3D.self]?.skybox.isEnabled == false)
        #expect(viewportModel.perspectiveTransitionProgress == 0)
        #expect(cameraEntity.components[Transform.self]?.position.z == EditorSceneViewportModel.twoDCameraDepth)
        #expect(cameraEntity.components[VisibleEntities.self]?.entityIds.contains(visibleEntity.id) == true)
        #expect(cameraEntity.components[GlobalTransform.self]?.matrix == cameraEntity.components[Transform.self]?.matrix)
    }

    @Test("3D SceneView rendering signals that its offscreen texture is ready")
    @MainActor
    func threeDSceneViewRenderingSignalsCompletion() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
        }

        let app = AppWorlds(main: World(name: "Editor3DOffscreenCompletion"))
        app.main.setSchedulers([.preUpdate])
        app.updateScheduler = .preUpdate
        app
            .addPlugin(TransformPlugin())
            .addPlugin(RenderWorldPlugin())
            .addPlugin(CameraPlugin())
            .addPlugin(Model3DPlugin())
            .addPlugin(Core2DPlugin())
            .addPlugin(Core3DPlugin(includes2D: true))
            .addPlugin(UpscalePlugin())
        app.insertResource(OffscreenRenderWorld())
        app.insertResource(PrimaryWindowId(windowId: RID()))

        try await app.build()

        let target = RenderTexture(size: SizeInt(width: 64, height: 64), scaleFactor: 1, format: .bgra8)
        let completion = EditorRenderCompletionProbe()
        target.renderCompletedHandler = { _ in
            Task {
                await completion.markCompleted()
            }
        }
        app.main.spawn("SceneView Camera") {
            Camera(renderTarget: target)
            Transform()
            VisibleEntities()
            Visibility.visible
            CameraRenderGraph(subgraphLabel: .main3D, inputSlot: Core3DPlugin.InputNode.view)
        }

        try await app.update()
        await Task.yield()

        #expect(await completion.isCompleted)
    }

    @Test("Viewport waits for its own camera without changing an authored game camera")
    @MainActor
    func viewportBindsCameraCreatedAfterSceneLoad() {
        let world = World()
        let gameCamera = world.spawn("Game Camera") {
            Camera()
            Transform(position: Vector3(100, 200, 300))
        }
        let viewport = EditorSceneViewportModel()
        viewport.attachSceneWorld(world, loadResult: .empty)
        viewport.setViewportSize(Size(width: 640, height: 480))
        #expect(viewport.cameraEntity() == nil)
        #expect(gameCamera.components[Transform.self]?.position == Vector3(100, 200, 300))

        let editorCamera = world.spawn("SceneView_Camera") {
            Camera()
            Transform()
        }
        #expect(viewport.update(deltaTime: 0))
        #expect(viewport.cameraEntity()?.id == editorCamera.id)
        #expect(editorCamera.components[CameraRenderGraph.self]?.subgraphLabel == .main3D)
        viewport.rotate3D(by: Vector2(0, -30))
        #expect(gameCamera.components[Transform.self]?.position == Vector3(100, 200, 300))
    }

    @Test("Scene viewport renders meshes and sprites through both camera projections")
    @MainActor
    func mixedSceneRendersInBothProjections() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
        }
        let app = AppWorlds(main: World(name: "MixedScene"))
        app.main.setSchedulers([.preUpdate])
        app.updateScheduler = .preUpdate
        app.main.addSystem(TransformSystem.self, on: .preUpdate)
        app
            .addPlugin(TransformPlugin())
            .addPlugin(RenderWorldPlugin())
            .addPlugin(CameraPlugin())
            .addPlugin(VisibilityPlugin())
            .addPlugin(SpritePlugin())
            .addPlugin(Model3DPlugin())
            .addPlugin(Core2DPlugin())
            .addPlugin(Core3DPlugin(includes2D: true))
            .addPlugin(UpscalePlugin())
        app.insertResource(OffscreenRenderWorld())
        app.insertResource(PrimaryWindowId(windowId: RID()))
        try await app.build()
        let renderWorld = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        let device = try #require(renderWorld.getResource(RenderDeviceHandler.self)?.renderDevice)
        let diagnostics = try #require(renderWorld.getResource(RenderGraphDiagnostics.self))
        diagnostics.configure(isEnabled: true)
        let target = RenderTexture(size: SizeInt(width: 128, height: 128), scaleFactor: 1, format: .bgra8)
        let gameCamera = app.main.spawn("Authored Window Camera") {
            Camera()
            Transform(position: Vector3(100, 200, 300))
            VisibleEntities()
            GlobalViewUniform()
            CameraRenderGraph(subgraphLabel: .main3D, inputSlot: "view")
        }
        app.main.spawn("SceneView_Camera") {
            Camera(renderTarget: target)
            Transform()
            VisibleEntities()
            Visibility.visible
        }
        let cube = app.main.spawn("Cube") {
            Mesh3DComponent(mesh: EditorMeshPrimitive.cube.makeMesh(renderDevice: device), materials: [PBRMaterial()])
            Transform()
            Visibility.visible
        }
        let sprite = app.main.spawn("Sprite") {
            Sprite(size: Size(width: 1, height: 1))
            Transform(position: Vector3(2, 0, 0))
            BoundingComponent(bounds: .aabb(AABB(center: .zero, halfExtents: Vector3(0.5, 0.5, 0))))
            Visibility.visible
        }
        let viewport = EditorSceneViewportModel()
        viewport.attachSceneWorld(app.main, loadResult: .empty)
        viewport.setViewportSize(Size(width: 128, height: 128))
        for mode in [EditorSceneViewportDisplayMode.twoD, .threeD, .twoD] {
            viewport.setDisplayMode(mode)
            _ = viewport.update(deltaTime: 0.5)
            diagnostics.clear()
            try await app.update()
            try await app.update()
            #expect(!renderWorld.getEntities().contains { $0.components[ExtractedCameraSource.self]?.entityId == gameCamera.id })
            #expect(gameCamera.components[Transform.self]?.position == Vector3(100, 200, 300))
            #expect(renderWorld.getResource(RenderItems<Opaque3DRenderItem>.self)?.items.contains { $0.entity == cube.id } == true)
            let sprites = try #require(renderWorld.getResource(SortedRenderItems<Transparent2DRenderItem>.self))
            let item = try #require(sprites.items.items.first { $0.entity == sprite.id })
            let scenePipeline = renderWorld.getRefResource(Scene2DPipelines.self).wrappedValue.pipeline(for: item.renderPipeline, device: device)
            #expect(scenePipeline.descriptor.backfaceCulling == false)
            #expect(scenePipeline.descriptor.depthStencilDescriptor?.isDepthWriteEnabled == false)
            #expect(scenePipeline.descriptor.depthStencilDescriptor?.depthCompareOperator == .lessOrEqual)
            let frame = try #require(diagnostics.recentFrames().first { $0.graphLabel == RenderGraph.Label.main3D.rawValue })
            #expect(frame.executionOrder.contains(Main3DRenderNode.name.rawValue))
            #expect(frame.executionOrder.contains(Scene2DRenderNode.name.rawValue))
            #expect(frame.error == nil)
        }
    }

    @Test("2D coordinate ruler follows the visible world range and fades during transition")
    @MainActor
    func viewportCoordinateRulerTracksVisibleWorldRange() {
        let viewportModel = EditorSceneViewportModel()
        let size = Size(width: 640, height: 360)
        viewportModel.setViewportSize(size)

        let twoDRuler = viewportModel.coordinateRuler(in: size)
        #expect(twoDRuler.opacity == 1)
        #expect(twoDRuler.labels.contains { $0.axis == .x })
        #expect(twoDRuler.labels.contains { $0.axis == .y })
        #expect(
            twoDRuler.labels.allSatisfy { label in
                label.position.x >= 0 && label.position.x <= size.width
                    && label.position.y >= 0 && label.position.y <= size.height
            }
        )

        viewportModel.setDisplayMode(.threeD)
        _ = viewportModel.update(deltaTime: 0.25)
        let transitioningRuler = viewportModel.coordinateRuler(in: size)
        #expect(transitioningRuler.opacity > 0 && transitioningRuler.opacity < 1)

        _ = viewportModel.update(deltaTime: 0.25)
        let threeDRuler = viewportModel.coordinateRuler(in: size)
        #expect(threeDRuler.opacity == 0)
        #expect(threeDRuler.labels.isEmpty)
    }
}
