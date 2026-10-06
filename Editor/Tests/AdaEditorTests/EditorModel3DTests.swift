@_spi(Internal) @testable import AdaApp
@_spi(AdaEngine) @testable import AdaEngine
@_spi(Internal) @testable import AdaRender
@_spi(Internal) @testable import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite(.serialized)
struct EditorModel3DTests {
    init() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader())
        EditorComponentRegistry.registerBuiltIns()
    }

    @Test("Import and file drop preserve glTF buffers and never overwrite an earlier import", arguments: [false, true])
    func importsDependencies(drop: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try triangle(in: root.appendingPathComponent("Export"))
        let project = try EditorProjectStore(storageURL: root.appendingPathComponent("projects.json"), distribution: .standalone)
            .createProject(named: "Model Import", at: root)
        let editor = EditorViewModel(project: project)
        if drop {
            editor.projectSidebar.select(try #require(editor.projectSidebar.items.first { $0.relativePath == "Assets" }))
            #expect(editor.importDroppedFiles(from: [source]))
            await editor.sourceControl.refreshTask?.value
            #expect(editor.importDroppedFiles(from: [source]))
        } else {
            editor.importAssets(from: [source])
            await editor.sourceControl.refreshTask?.value
            editor.importAssets(from: [source])
        }
        await editor.sourceControl.refreshTask?.value
        let files = editor.projectSidebar.items.filter { $0.title == "Triangle.gltf" }
        #expect(files.count == 2)
        #expect(EditorViewModel.modelAssets(from: files).count == 2)
        for item in files {
            guard case let .asset(document) = EditorViewModel.document(for: item) else {
                Issue.record("Models must open in the 3D preview")
                continue
            }
            #expect(document.kind == .model3D)
            let path = try #require(document.absolutePath)
            #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("Buffers/mesh.bin").path))
            let imported = try await NativeGLTFLoader().load(url: URL(fileURLWithPath: path))
            #expect(imported.meshes.count == 1)
            #expect(imported.nodes.first?.name == "Offset mesh")
        }
    }

    @Test("Missing or escaping dependencies leave no partially imported bundle")
    func rejectsBrokenDependencies() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = try triangle(in: root.appendingPathComponent("Export"))
        let original = try String(contentsOf: source, encoding: .utf8)
        for invalid in ["Buffers/missing.bin", "../secret.bin", "https://example.com/mesh.bin"] {
            try original.replacingOccurrences(of: "Buffers/mesh.bin", with: invalid).write(to: source, atomically: true, encoding: .utf8)
            #expect(throws: (any Error).self) { try EditorModelAssetImporter.copy(source, to: destination) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
    }

    @Test("Add model, save and reopen preserves a portable reference and loads hierarchy/materials in edit and Play", arguments: [false, true])
    func savedModelLoads(play: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("Assets")
        let source = try triangle(in: assets)
        let sceneURL = assets.appendingPathComponent("Main.ascn")
        let initial = EditorSceneModel.default(projectName: "Models")
        let workbench = EditorWorkbenchViewModel(openDocuments: [.scene(try sceneDocument(initial, at: sceneURL))], activeDocumentID: "scene:Main")
        let document = assetDocument(source)
        #expect(workbench.addModelAsset(document, to: "scene:Main"))
        #expect(workbench.saveAllDocuments())
        let content = try String(contentsOf: sceneURL, encoding: .utf8)
        let reopened = try EditorSceneModel.decode(from: content)
        let authored = try #require(reopened.entities.first { $0.components[EditorBuiltInComponentType.model3DSource] != nil })
        #expect(authored.name == "Triangle")
        #expect(authored.components[EditorBuiltInComponentType.model3DSource]?["source"] == .string("@res://Triangle.gltf"))
        #expect(reopened.entities.count == initial.entities.count + 1)
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        let result = EditorSceneFileLoader.load(content: content, into: app.main, loadsScriptableObjects: play, sourceURL: sceneURL, resourceRootURL: assets)
        #expect(result.warnings.isEmpty, Comment(rawValue: result.warnings.joined(separator: "\n")))
        let ownerID = try #require(result.entitiesByEditorID[authored.id])
        let owner = try #require(app.main.getEntityByID(ownerID))
        let generated = try #require(owner.children.first)
        let mesh = try #require(generated.children.first)
        let component = try #require(mesh.components[Mesh3DComponent.self])
        #expect(component.materials.first is PBRMaterial)
        #expect(component.mesh.models.first?.parts.first?.indexCount == 3)
        #expect(mesh.components[Transform.self]?.position.x == 3)
        #expect(result.editorIDsByEntityID[mesh.id] == authored.id)
        let count = app.main.getEntities().count
        await app.main.runScheduler(.preUpdate)
        #expect(app.main.getEntities().count == count, "Already prepared models must not instantiate twice")
        await app.main.runScheduler(.postUpdate)
        let renderWorld = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        renderWorld.insertResource(MainWorld(world: app.main))
        await renderWorld.runScheduler(.extract)
        let items = try #require(renderWorld.getResource(RenderItems<Opaque3DRenderItem>.self))
        #expect(items.items.contains { $0.entity == mesh.id }, "Imported meshes must reach the production render extraction path")
        #expect(workbench.performDocumentHistory(redo: false))
        #expect(workbench.activeSceneDocument?.sceneModel?.entities.count == initial.entities.count)
        #expect(workbench.performDocumentHistory(redo: true))
    }

    @Test("Named GLB clips have independent players and authored playback survives scene reopening")
    func namedAnimation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ribbon(in: root)
        var scene = EditorSceneModel.default(projectName: "Animation")
        for _ in 0..<2 {
            let entity = scene.addEntity(template: .importedModel3D, parentID: scene.rootEntityID)
            let index = try #require(scene.entities.firstIndex { $0.id == entity.id })
            scene.entities[index].components[EditorBuiltInComponentType.model3DSource] = [
                "source": .string("@res://TwoBoneRibbon.glb"), "animation": .string("Bend"), "autoplay": .bool(true), "repeats": .bool(false),
            ]
        }
        let world = World()
        let result = EditorSceneFileLoader.load(content: try scene.encodedYAML(), into: world, resourceRootURL: root)
        #expect(result.warnings.isEmpty)
        let roots = world.getEntities().filter { $0.components[ModelAnimation3DComponent.self] != nil }
        #expect(roots.count == 2)
        var first = try #require(roots.first?.components[ModelAnimation3DComponent.self])
        #expect(first.player.isPlaying && !first.player.repeats)
        #expect(first.player.clips[first.player.clipIndex ?? 0].name == "Bend")
        first.player.seek(to: 0.5)
        roots[0].components[ModelAnimation3DComponent.self] = first
        #expect(roots[1].components[ModelAnimation3DComponent.self]?.player.time == 0)
        let preview = EditorModelAssetPreviewModel()
        preview.asset = try #require(AssetsManager.loadSync(ModelAsset3D.self, at: source.path).asset)
        #expect(preview.animationNames == ["Rest pose", "Bend"])
        #expect(preview.normalizedBounds.center == .zero)
        #expect(max(preview.normalizedBounds.halfExtents.x, max(preview.normalizedBounds.halfExtents.y, preview.normalizedBounds.halfExtents.z)) == 1.5)
        let previewWorld = World()
        let previewOwner = previewWorld.spawn("Preview")
        let previewRoot = try Model3DSource(source: source.path).instantiate(try #require(preview.asset), in: previewWorld, under: previewOwner)
        preview.bind(to: previewWorld)
        preview.selectedAnimation = "Bend"
        var playing = try #require(previewRoot.components[ModelAnimation3DComponent.self])
        playing.player.seek(to: 0.3)
        previewRoot.components[ModelAnimation3DComponent.self] = playing
        preview.playsAnimation = false
        #expect(previewRoot.components[ModelAnimation3DComponent.self]?.player.time == 0.3)
        #expect(previewRoot.components[ModelAnimation3DComponent.self]?.player.isPlaying == false)
        preview.playsAnimation = true
        #expect(previewRoot.components[ModelAnimation3DComponent.self]?.player.time == 0.3)
        #expect(previewRoot.components[ModelAnimation3DComponent.self]?.player.isPlaying == true)
    }

    @Test("Runtime plugin loads serialized references, replaces only generated children and cleans up removed references")
    func runtimeLifecycle() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ribbon(in: root)
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        let owner = app.main.spawn("Model")
        owner.components[Transform.self] = Transform()
        let other = app.main.spawn("Authored child")
        owner.addChild(other)
        let reference = Model3DSource(source: source.path, animation: "Bend", autoplay: true)
        owner.components[Model3DSource.self] = try JSONDecoder().decode(Model3DSource.self, from: JSONEncoder().encode(reference))
        app.main.flush()
        await app.main.runScheduler(.preUpdate)
        app.main.flush()
        let state = try #require(owner.components[Model3DSourceState.self])
        #expect(state.error == nil && state.rootEntityID != nil)
        #expect(owner.children.count == 2)
        owner.components[Model3DSource.self] = Model3DSource(source: source.path, animation: "Missing")
        app.main.flush()
        await app.main.runScheduler(.preUpdate)
        #expect(owner.components[Model3DSourceState.self]?.error?.contains("Missing") == true)
        #expect(owner.children.map(\.id) == [other.id])
        owner.components[Model3DSource.self] = nil
        app.main.flush()
        await app.main.runScheduler(.preUpdate)
        #expect(owner.components[Model3DSourceState.self] == nil)
        #expect(app.main.getEntityByID(other.id) != nil)
    }

    @Test("Inspector exposes model assets through real picker interaction")
    func inspectorPicker() async throws {
        var scene = EditorSceneModel.default(projectName: "Picker")
        let entity = scene.addEntity(template: .importedModel3D, parentID: scene.rootEntityID)
        let viewport = EditorSceneViewportModel()
        let inspector = EditorInspectorSidebarViewModel()
        inspector.modelAssets = [.init(name: "Robot.glb", reference: "@res://Robot.glb", absolutePath: "/tmp/Robot.glb")]
        viewport.configure(sceneContent: try scene.encodedYAML(), onSelectionChanged: { inspector.selectEntity($0) }, onDocumentContentChanged: { _ in })
        inspector.updateComponentField = { type, field, value in scene.updateField(typeName: type, field: field, value: value, in: entity.id) }
        let container = UIContainerView(rootView: EditorInspectorSidebar(viewModel: inspector))
        container.frame = Rect(x: 0, y: 0, width: 380, height: 1000)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Inspector.AssetReference.\(EditorBuiltInComponentType.model3DSource).source")
        _ = try container.uiScrollToNode(matching: selector)
        _ = try container.uiTapNode(matching: selector)
        for _ in 0..<10 {
            await Task.yield()
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        let option = UINodeSelector.accessibilityIdentifier("AdaEditor.Inspector.AssetOption.@res://Robot.glb")
        _ = try container.uiScrollToNode(matching: option)
        _ = try container.uiTapNode(matching: option)
        #expect(scene.selectedEntity()?.components[EditorBuiltInComponentType.model3DSource]?["source"] == .string("@res://Robot.glb"))
        viewport.disconnect()
    }

    @Test("Picking respects translated, rotated and scaled imported-node bounds")
    func pickingImportedBounds() {
        let transform = Transform(rotation: Quat(axis: Vector3(0, 0, 1), angle: .pi / 2), scale: Vector3(2), position: Vector3(10, 0, 0))
        let bounds = BoundingComponent(bounds: .aabb(AABB(center: Vector3(3, 0, 0), halfExtents: Vector3(1, 0.5, 0.5))))
        let ray = Ray(origin: Vector3(10, 6, -5), direction: Vector3(0, 0, 1))
        #expect(EditorPicking.intersectionDistance(ray: ray, transform: transform, bounds: bounds) == 4)
    }

    @Test("Play camera keeps authored lens settings while fitting its actual viewport", arguments: [Size(width: 320, height: 800), Size(width: 800, height: 320)])
    func playCameraAspect(size: Size) throws {
        let world = World()
        var display = Camera()
        display.logicalViewport.rect = Rect(x: 0, y: 0, width: size.width, height: size.height)
        let target = world.spawn("SceneView_Camera") { display; Transform() }
        var authored = Camera()
        authored.projection = .perspective(PerspectiveProjection(near: 0.2, far: 400, fieldOfView: .degrees(65), aspectRation: 16 / 9))
        world.spawn("Game camera") { authored; Transform() }
        #expect(EditorSceneViewportView.synchronizePlayCamera(in: world))
        guard case let .perspective(projection)? = target.components[Camera.self]?.projection else {
            Issue.record("Missing perspective Play camera")
            return
        }
        #expect(abs(projection.aspectRation - size.width / size.height) < 0.00001)
        #expect(projection.fieldOfView == .degrees(65) && projection.near == 0.2 && projection.far == 400)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("editor-model3d-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Asset camera fits portrait and landscape viewports and resets orbit/zoom", arguments: [Size(width: 360, height: 800), Size(width: 1200, height: 500)])
    func assetCameraFraming(size: Size) {
        let camera = EditorModelPreviewCamera()
        camera.attach(to: World(), bounds: AABB(center: .zero, halfExtents: Vector3(1.2, 1.5, 0.8)))
        camera.setViewportSize(size)
        let transform = camera.cameraTransform()
        let projection = PerspectiveProjection(fieldOfView: EditorModelPreviewCamera.fieldOfView, aspectRation: size.width / size.height).makeClipView()
        for x: Float in [-1.2, 1.2] {
            for y: Float in [-1.5, 1.5] {
                for z: Float in [-0.8, 0.8] {
                    let clipMatrix = projection * transform.matrix.inverse
                    let corner = Vector4(x, y, z, 1)
                    let clip = clipMatrix * corner
                    #expect(clip.w > 0)
                    #expect(abs(clip.x / clip.w) < 1 && abs(clip.y / clip.w) < 1)
                }
            }
        }
        camera.orbit(by: Point(100, 30))
        camera.zoom(by: 2)
        #expect(camera.cameraTransform() != transform)
        camera.reset()
        #expect(camera.cameraTransform() == transform)
    }

    private func ribbon(in root: URL) throws -> URL {
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = engine.appendingPathComponent("Tests/AdaAssetsTests/Fixtures/TwoBoneRibbon.glb")
        return try EditorModelAssetImporter.copy(source, to: root)
    }

    private func triangle(in root: URL) throws -> URL {
        let buffers = root.appendingPathComponent("Buffers")
        try FileManager.default.createDirectory(at: buffers, withIntermediateDirectories: true)
        var data = Data()
        for value: Float in [0, 0, 0, 1, 0, 0, 0, 1, 0] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: [0, 0, 1, 0, 2, 0])
        try data.write(to: buffers.appendingPathComponent("mesh.bin"))
        let json = """
        {"asset":{"version":"2.0"},"buffers":[{"uri":"Buffers/mesh.bin","byteLength":42}],
        "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":6}],
        "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},
        {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}],
        "materials":[{"pbrMetallicRoughness":{"baseColorFactor":[0.2,0.4,0.8,1],"metallicFactor":0,"roughnessFactor":0.7}}],
        "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"material":0}]}],
        "nodes":[{"name":"Offset mesh","mesh":0,"translation":[3,0,0]}],"scenes":[{"nodes":[0]}],"scene":0}
        """
        let source = root.appendingPathComponent("Triangle.gltf")
        try json.write(to: source, atomically: true, encoding: .utf8)
        return source
    }

    private func assetDocument(_ url: URL) -> EditorAssetDocument {
        .init(
            id: "asset:\(url.lastPathComponent)",
            title: url.lastPathComponent,
            relativePath: "Assets/\(url.lastPathComponent)",
            absolutePath: url.path,
            assetReference: "@res://\(url.lastPathComponent)",
            kind: .model3D,
            fileExtension: url.pathExtension
        )
    }

    private func sceneDocument(_ scene: EditorSceneModel, at url: URL) throws -> EditorSceneDocument {
        .init(
            id: "scene:Main",
            title: "Main.ascn",
            relativePath: "Assets/Main.ascn",
            absolutePath: url.path,
            content: try scene.encodedYAML(),
            sceneModel: scene,
            isDirty: true,
            loadSummary: .init(entityCount: scene.entities.count, warnings: [])
        )
    }
}
