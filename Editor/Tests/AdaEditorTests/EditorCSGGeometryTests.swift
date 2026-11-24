@_spi(Internal) @testable import AdaApp
@_spi(Internal) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@Suite("CSG geometry and portable scene output", .serialized, .enabled(if: CSGGroupSource.isAvailable))
struct EditorCSGGeometryTests {
    @Test("The through-cut leaves an opening and a closed solid on both sides")
    @MainActor
    func evaluatesDoorway() async throws {
        let cut = CSGBoxOperand(transform: .init(scale: [2, 2, 3], position: [0, 1.03, 0]), operation: .subtract)
        let wall = CSGBoxOperand(transform: .init(scale: [-8, 3, 1], position: [0, 1.5, 0]))
        let result = try await CSGGroupSource(boxes: [wall, cut]).evaluate()
        let solid = try ScalarMeshSolid(positions: result.surface.positions, indices: result.surface.indices)
        #expect(try solid.value(at: [0, 1, 0]) > 0)
        #expect(try solid.value(at: [2, 1, 0]) < 0)
        #expect(try solid.value(at: [-2, 1, 0]) < 0)

        let imported = try NativeGLTFLoader().load(data: result.modelData())
        #expect(imported.meshes.first?.primitives.first?.indices?.count == result.surface.indices.count)
        let pose = Transform3D(translation: [5, 2, -3], rotation: .identity, scale: [2, 3, -1])
        let candidateShape = try result.collisionShape(worldMatrix: pose)
        let shape = try #require(candidateShape)
        try shape.prepareStaticCollision()
        #expect(shape.localBounds?.min == [-3, 2, -3.5])
        #expect(shape.localBounds?.max == [13, 11, -2.5])

        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(Physics3DPlugin(gravity: .zero))
        try await app.build()
        let body = app.main.spawn {
            Transform()
            PhysicsBody3DComponent(shapes: [shape], mode: .static)
        }
        await app.main.runScheduler(.physicsSync)
        let physics = try #require(app.main.physicsWorld3D)
        #expect(physics.raycast(from: [5, 5, -7], to: [5, 5, 1]) == nil)
        #expect(physics.raycast(from: [9, 5, -7], to: [9, 5, 1])?.entityID == body.id)
    }

    @Test("Stored operator order controls empty results and later unions")
    func evaluatesInOrder() async throws {
        let cut = CSGBoxOperand(transform: .init(scale: [4, 4, 4]), operation: .subtract)
        let small = CSGBoxOperand(transform: .init(scale: [2, 2, 2]))
        let placed = CSGBoxOperand(transform: .init(position: [1.5, 0, 0]))
        let empty = try await CSGGroupSource(boxes: [small, cut]).evaluate()
        #expect(empty.isEmpty)
        let restored = try await CSGGroupSource(boxes: [small, cut, placed]).evaluate()
        #expect(!restored.isEmpty)
        let reordered = try await CSGGroupSource(boxes: [small, placed, cut]).evaluate()
        #expect(reordered.isEmpty)
        let intersect = CSGBoxOperand(transform: .init(scale: [2, 2, 2], position: [1, 0, 0]), operation: .intersect)
        let result = try await CSGGroupSource(boxes: [small, intersect]).evaluate()
        let solid = try ScalarMeshSolid(positions: result.surface.positions, indices: result.surface.indices)
        #expect(try solid.value(at: [0.5, 0, 0]) < 0)
        #expect(try solid.value(at: [-0.5, 0, 0]) > 0)
    }

    @Test("Group operand budgets and zero-scale boxes reject invalid geometry")
    func rejectsInvalidGeometry() async {
        let oversized = CSGGroupSource(boxes: Array(repeating: .init(), count: CSGGroupSource.maximumBoxes + 1))
        await #expect(throws: TriangleGeometryError.budgetExceeded) { try await oversized.evaluate() }
        let invalid = CSGGroupSource(boxes: [.init(transform: .init(scale: [1, 0, 1]))])
        await #expect(throws: (any Error).self) { try await invalid.evaluate() }
    }

    @Test("Scene edits, history, and file reload preserve Boolean ordering and identities")
    @MainActor
    func restoresHistory() throws {
        let model = EditorSceneModel.default(projectName: "CSG History")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).ascn")
        defer { try? FileManager.default.removeItem(at: file) }
        let content = try model.encodedYAML()
        try content.write(to: file, atomically: true, encoding: .utf8)
        let document = EditorSceneDocument(
            id: "csg",
            title: file.lastPathComponent,
            relativePath: file.lastPathComponent,
            absolutePath: file.path,
            content: content,
            lastSavedContent: content,
            sceneModel: model,
            isDirty: false,
            loadSummary: .init(entityCount: model.entities.count, warnings: [])
        )
        let workbench = EditorWorkbenchViewModel(openDocuments: [.scene(document)], activeDocumentID: document.id)
        let template = try #require(EditorSceneEntityTemplate(rawValue: "csgGroup"))
        workbench.addSceneEntity(documentID: document.id, parentID: model.rootEntityID, template: template)
        let groupID = try #require(workbench.activeSceneDocument?.sceneModel?.editor?.selectedEntity)
        let first = try #require(workbench.activeSceneDocument?.sceneModel?.csgBoxes(in: groupID).first?.id)
        workbench.updateSceneModelDocument(id: document.id, status: "Add fixture cut") { model in
            if let box = model.addCSGBox(to: groupID) { model.setCSGOperation(.subtract, for: box.id) }
        }
        let last = try #require(workbench.activeSceneDocument?.sceneModel?.csgBoxes(in: groupID).last?.id)
        workbench.updateSceneModelDocument(id: document.id, status: "Reorder fixture cut") { model in
            model.moveCSGBox(last, in: groupID, by: -1)
        }
        #expect(workbench.activeSceneDocument?.sceneModel?.csgBoxes(in: groupID).map(\.id) == [last, first])
        #expect(workbench.performDocumentHistory(redo: false))
        #expect(workbench.activeSceneDocument?.sceneModel?.csgBoxes(in: groupID).map(\.id) == [first, last])
        #expect(workbench.performDocumentHistory(redo: true))
        #expect(workbench.saveActiveDocument())
        var reopened = try EditorSceneModel.decode(from: String(contentsOf: file, encoding: .utf8))
        let order = reopened.csgBoxes(in: groupID)
        #expect(order.map(\.id) == [last, first])
        let candidateCopy = reopened.duplicateEntity(groupID)
        let copy = try #require(candidateCopy)
        let copied = reopened.csgBoxes(in: copy.id)
        #expect(copied.map { $0.components[EditorCSGScene.boxType] } == order.map { $0.components[EditorCSGScene.boxType] })
        #expect(Set(copied.map(\.id)).isDisjoint(with: order.map(\.id)))
    }

    @Test("An invalid preview retains the last mesh and a valid empty result clears it")
    @MainActor
    func retainsAndClearsPreview() async throws {
        if unsafe RenderEngine.shared == nil {
            let previous = unsafe RenderEngine.configurations.preferredBackend
            defer { unsafe RenderEngine.configurations.preferredBackend = previous }
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "CSG Preview")))
        }
        let template = try #require(EditorSceneEntityTemplate(rawValue: "csgGroup"))
        var model = EditorSceneModel.default(projectName: "CSG Preview")
        let group = model.addEntity(template: template, parentID: nil)
        let index = try #require(model.entities.firstIndex { $0.parent == group.id })
        let viewport = EditorSceneViewportModel()
        defer { viewport.disconnect() }
        let world = World()
        viewport.configure(sceneContent: try model.encodedYAML(), model: model, onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in })
        viewport.loadSceneWorld(world, onLoadingChanged: { _ in }, onLoaded: { _ in })
        try await waitFor(.ready, group: group.id, preview: viewport.csgPreview)
        let owner = try #require(viewport.runtimeEntity(for: group.id))
        let previewMesh = owner.children.compactMap { $0.components[Mesh3DComponent.self]?.mesh }.first
        let mesh = try #require(previewMesh)

        let transformType = EditorBuiltInComponentType.transform
        model.entities[index].components[transformType]?["scale"] = .array([.int(1), .int(0), .int(1)])
        viewport.sceneModel = model
        try await waitFor(.failed, group: group.id, preview: viewport.csgPreview)
        #expect(owner.children.compactMap { $0.components[Mesh3DComponent.self]?.mesh }.first?.bounds == mesh.bounds)

        model.entities[index].enabled = false
        viewport.sceneModel = model
        try await waitFor(.empty, group: group.id, preview: viewport.csgPreview)
        #expect(owner.children.allSatisfy { $0.components[Mesh3DComponent.self] == nil })
    }

    @MainActor
    private func waitFor(_ status: EditorCSGPreview.Status, group: String, preview: EditorCSGPreview) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while preview.status[group] != status, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(preview.status[group] == status, "Saved CSG geometry must publish its current result through the viewport")
    }

    #if os(macOS) || os(Windows) || os(Linux)
    @Test("Native scene conversion ships the mesh and an inherited static collider")
    @MainActor
    func convertsRealScene() async throws {
        let template = try #require(EditorSceneEntityTemplate(rawValue: "csgGroup"))
        var model = EditorSceneModel.default(projectName: "Two Rooms")
        let rootID = try #require(model.rootEntityID)
        let root = try #require(model.entities.firstIndex { $0.id == rootID })
        model.entities[root].components[EditorBuiltInComponentType.transform]?["position"] = .array([.int(5), .int(2), .int(-3)])
        model.entities[root].components[EditorBuiltInComponentType.transform]?["scale"] = .array([.int(2), .int(3), .int(1)])
        let group = model.addEntity(template: template, parentID: rootID)
        let cutBox = model.addCSGBox(to: group.id)
        let cutter = try #require(cutBox)
        let boxIndex = try #require(model.entities.firstIndex { $0.id == cutter.id })
        model.entities[boxIndex].components[EditorBuiltInComponentType.transform]?["scale"] = .array([.double(0.25), .int(2), .int(2)])
        model.setCSGOperation(.subtract, for: cutter.id)

        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let file = rootURL.appendingPathComponent("Two Rooms.ascn")
        try model.encodedYAML().write(to: file, atomically: true, encoding: .utf8)
        let hasCSG = try await EditorAdaScriptNativeExporter.convertScenes(at: rootURL, originalRoot: rootURL, sources: [])
        #expect(hasCSG)

        let document = try JSONDecoder().decode(AdaScriptNativeSceneDocument.self, from: Data(contentsOf: file))
        #expect(document.entities.allSatisfy { $0.id != cutter.id && $0.components.keys.allSatisfy { !EditorCSGScene.isAuthoringComponent($0) } })
        let mesh = try #require(document.entities.first { $0.components[EditorBuiltInComponentType.model3DSource] != nil })
        #expect(mesh.parent == group.id)
        let reference = try JSONDecoder().decode(Model3DSource.self, from: #require(mesh.components[EditorBuiltInComponentType.model3DSource]))
        #expect(reference.source.hasPrefix("@res://NativeCSG/"))
        let asset = rootURL.appendingPathComponent(String(reference.source.dropFirst("@res://".count)))
        let imported = try await NativeGLTFLoader().load(url: asset)
        #expect(imported.meshes.first?.primitives.first?.indices?.isEmpty == false)

        let scene = try document.makeScene(components: [], resourceRoot: rootURL, sourceURL: file)
        let physics = try #require(scene.world.getEntities().compactMap { $0.components[PhysicsBody3DComponent.self] }.first)
        #expect(physics.mode == .static)
        #expect(physics.localBounds?.min == [4, 0.5, -3.5])
        #expect(physics.localBounds?.max == [6, 3.5, -2.5])
    }

    @Test("A rotated scene instance places the same portable collision as Play")
    @MainActor
    func transformsReferencedScene() async throws {
        let template = try #require(EditorSceneEntityTemplate(rawValue: "csgGroup"))
        var nested = EditorSceneModel.default(projectName: "Nested CSG")
        let group = nested.addEntity(template: template, parentID: nested.rootEntityID)
        var level = EditorSceneModel.default(projectName: "Outer CSG")
        let instance = level.addEntity(template: .sceneInstance, parentID: level.rootEntityID)
        let index = try #require(level.entities.firstIndex { $0.id == instance.id })
        level.entities[index].components[EditorBuiltInComponentType.sceneInstance]?["scene"] = .string("@res://Nested.ascn")
        level.entities[index].components[EditorBuiltInComponentType.transform] = [
            "position": .array([.int(5), .int(3), .int(-2)]),
            "rotation": .array([.int(0), .double(0.70710678), .int(0), .double(0.70710678)]),
            "scale": .array([.int(4), .int(2), .int(1)]),
        ]
        let assets = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: assets) }
        let main = assets.appendingPathComponent("Main.ascn")
        try nested.encodedYAML().write(to: assets.appendingPathComponent("Nested.ascn"), atomically: true, encoding: .utf8)
        try level.encodedYAML().write(to: main, atomically: true, encoding: .utf8)

        let products = try await EditorCSGScene.prepare(level, sourceURL: main, resourceRootURL: assets)
        let prepared = try #require(products.first)
        #expect(prepared.groupID == instance.id + "/" + group.id)
        let play = World()
        var loaded = EditorSceneFileLoader.load(model: level, into: play, sourceURL: main, resourceRootURL: assets)
        _ = try await EditorAdaScriptNativeExporter.convertScenes(at: assets, originalRoot: assets, sources: [])
        EditorCSGScene.install(products, in: play, result: &loaded)
        #expect(loaded.csgTargets[prepared.groupID] != nil)
        let playCollision = try #require(play.getEntities().compactMap { $0.components[PhysicsBody3DComponent.self] }.first)
        #expect(playCollision.localBounds == prepared.shape.localBounds)

        let document = try JSONDecoder().decode(AdaScriptNativeSceneDocument.self, from: Data(contentsOf: main))
        let native = try document.makeScene(components: [], resourceRoot: assets, sourceURL: main)
        let collision = try #require(native.world.getEntities().compactMap { $0.components[PhysicsBody3DComponent.self] }.first)
        #expect(collision.localBounds == playCollision.localBounds)
    }
    #endif
}
