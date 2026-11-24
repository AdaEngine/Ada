@_spi(Internal) @testable import AdaApp
@_spi(Internal) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@Suite("CSG scene authoring")
struct EditorCSGTests {
    @Test("The scene picker creates an editable CSG group with a persisted base box")
    func createsAndSavesGroup() throws {
        let template = try #require(EditorSceneEntityTemplate(rawValue: "csgGroup"), "The scene picker must offer a CSG group")
        var model = EditorSceneModel.default(projectName: "CSG")
        let group = model.addEntity(template: template, parentID: nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).ascn")
        defer { try? FileManager.default.removeItem(at: file) }
        try model.encodedYAML().write(to: file, atomically: true, encoding: .utf8)
        let reopened = try EditorSceneModel.decode(from: String(contentsOf: file, encoding: .utf8))
        let box = try #require(reopened.entities.first { $0.parent == group.id })
        #expect(reopened.entities.filter { $0.parent == group.id }.count == 1)
        #expect(box.components[EditorBuiltInComponentType.transform] != nil)
        #expect(reopened.editor?.selectedEntity == group.id)
    }

    @Test("Mixed Boolean operations export tiled UVs and a portable image", .enabled(if: CSGGroupSource.isAvailable))
    func exportsTexturedMixedShapes() async throws {
        let box = CSGBoxOperand(transform: .init(scale: [1.15, 1, 0.85]))
        for operation in [TriangleBooleanOperation.union, .subtract, .intersect] {
            let sphere = CSGBoxOperand(transform: .init(scale: [0.75, 1.3, 0.8], position: [0.17, 0.04, 0]), operation: operation, shape: .sphere)
            let cylinder = CSGBoxOperand(transform: .init(scale: [0.65, 1.6, 0.65], position: [-0.03, 0, 0.01]), operation: operation, shape: .cylinder)
            let result = try await CSGGroupSource(boxes: [box, sphere, cylinder], uvRepeats: 4, texture: .checker).evaluate()
            #expect(!result.isEmpty)
            let asset = try NativeGLTFLoader().load(data: result.modelData())
            #expect(asset.materials.first?.baseColorTextureIndex == 0)
            #expect(asset.samplers.first?.wrapS == 10497)
            #expect(asset.samplers.first?.wrapT == 10497)
            let image = try #require(asset.images.first)
            #expect(image.mimeType == "image/png")
            let bytes = try #require(image.data)
            #expect(try Image.decode(from: bytes).width == 64)
            let uv = asset.meshes.first?.primitives.first?.attributes[.texCoord(0)]?.vector2Values() ?? []
            #expect(uv.count == result.surface.indices.count)
            #expect(uv.allSatisfy { $0.x.isFinite && $0.y.isFinite })
            #expect(uv.contains { $0.x > 1 || $0.y > 1 })
        }
    }

    @Test("A sphere cut near the pole retains a local UV chart on each face", .enabled(if: CSGGroupSource.isAvailable))
    func preservesCurvedCharts() async throws {
        let sphere = CSGBoxOperand(shape: .sphere)
        let cutter = CSGBoxOperand(
            transform: .init(scale: [0.23, 0.46, 0.27], position: [0.12, 0.38, 0.014]),
            operation: .subtract
        )
        let output = try await CSGGroupSource(boxes: [sphere, cutter]).evaluate()
        let surface = output.surface
        #expect(Set(surface.faceSources) == [1, 2])
        let curvedFaces = surface.faceSources.indices.filter { surface.faceSources[$0] == 1 }
        var charts: [UInt32: [Vector3: Vector2]] = [:]
        var sharedPoints = 0
        for face in curvedFaces {
            let indices = surface.indices[(face * 3)..<(face * 3 + 3)].map(Int.init)
            let u = indices.map { surface.textureCoordinates[$0].x }
            let low = try #require(u.min())
            let high = try #require(u.max())
            #expect(high - low < 0.1)
            let chartID = surface.faceIDs[face]
            for index in indices {
                let position = surface.positions[index]
                let uv = surface.textureCoordinates[index]
                if let original = charts[chartID]?[position] {
                    #expect(abs(original.x - uv.x) < 0.0001)
                    #expect(abs(original.y - uv.y) < 0.0001)
                    sharedPoints += 1
                }
                charts[chartID, default: [:]][position] = uv
            }
        }
        #expect(sharedPoints > 0)
    }

    @Test("UV seams preserve shared vertices in a portable cube collider", .enabled(if: CSGGroupSource.isAvailable))
    func weldsColliderAcrossUVSeams() async throws {
        let result = try await CSGGroupSource(boxes: [.init()]).evaluate()
        #expect(result.surface.positions.count > 8)
        let data = try JSONEncoder().encode(StaticTriangleMesh3DSource(surface: result.surface))
        let encoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((encoded?["positions"] as? [Any])?.count == 8)
        #expect((encoded?["indices"] as? [Any])?.count == 36)
    }

    @Test("Project texture and UV edits survive scene reload", .enabled(if: CSGGroupSource.isAvailable))
    func reloadsProjectTexture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = Image(width: 2, height: 2, color: .white)
        try image.pngData().write(to: root.appendingPathComponent("Wall.png"))
        var model = EditorSceneModel.default(projectName: "Textured CSG")
        let group = model.addEntity(template: .csgGroup, parentID: nil)
        let cylinder = model.addCSGBox(to: group.id, shape: .cylinder)
        let operand = try #require(cylinder)
        model.setCSGTexture("@res://Wall.png", in: group.id)
        model.setCSGUVRepeats(8, in: group.id)
        let reopened = try EditorSceneModel.decode(from: model.encodedYAML())
        let authoredGroup = try #require(reopened.entities.first { $0.id == group.id })
        let source = try reopened.csgSource(authoredGroup, resourceRootURL: root)
        #expect(source.boxes.map(\.shape) == [.box, .cylinder])
        #expect(source.uvRepeats == 8)
        #expect(reopened.csgBoxes(in: group.id).last?.id == operand.id)
        let product = try await source.evaluate()
        let glTF = try NativeGLTFLoader().load(data: product.modelData())
        #expect(glTF.images.first?.data != nil)
    }

    @Test("CSG only offers texture paths relative to the exported assets root")
    @MainActor
    func texturePickerUsesPrimaryAssets() {
        let project = FileManager.default.temporaryDirectory
        let primary = project.appendingPathComponent("Assets", isDirectory: true)
        let chosen = primary.appendingPathComponent("Walls/Brick.png")
        let other = project.appendingPathComponent("Other/Brick.png")
        let assets: [EditorInspectorSidebarViewModel.TextureAsset] = [
            .init(name: "Brick.png", reference: "@res://Brick.png", absolutePath: chosen.path),
            .init(name: "Brick.png", reference: "@res://Brick.png", absolutePath: other.path),
        ]
        #expect(EditorViewModel.csgTextures(from: assets, assetsDirectory: primary) == ["@res://Walls/Brick.png"])
    }

    @Test("A CSG viewport edit can save after selection autosaves")
    @MainActor
    func savesViewportEditAfterSelection() throws {
        var model = EditorSceneModel.default(projectName: "CSG selection")
        let group = model.addEntity(template: .csgGroup, parentID: nil)
        let operand = model.addCSGBox(to: group.id)
        let box = try #require(operand)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).ascn")
        defer { try? FileManager.default.removeItem(at: file) }
        let content = try model.encodedYAML()
        try content.write(to: file, atomically: true, encoding: .utf8)
        let document = EditorSceneDocument(
            id: "csg-selection",
            title: file.lastPathComponent,
            relativePath: file.lastPathComponent,
            absolutePath: file.path,
            content: content,
            lastSavedContent: content,
            sceneModel: model,
            isDirty: false,
            loadSummary: EditorSceneFileLoader.summary(from: content)
        )
        let workbench = EditorWorkbenchViewModel(openDocuments: [.scene(document)], activeDocumentID: document.id)
        workbench.selectSceneEntity(documentID: document.id, entityID: group.id)
        try #require(workbench.saveActiveDocument())
        #expect(workbench.activeSceneDocument?.lastSavedContent != document.lastSavedContent)

        var edit = document
        model.setCSGOperation(.subtract, for: box.id)
        edit.content = try model.encodedYAML()
        edit.sceneModel = model
        edit.isDirty = true
        workbench.applySceneViewportEdit(edit)
        try #require(workbench.saveActiveDocument())
        let reopened = try EditorSceneModel.decode(from: String(contentsOf: file, encoding: .utf8))
        #expect(reopened.csgBoxes(in: group.id).last?.components[EditorCSGScene.boxType]?["operation"] == .string("subtract"))

        let current = try #require(workbench.activeSceneDocument)
        workbench.renameSceneEntity(documentID: current.id, entityID: box.id, name: "Newer on disk")
        try #require(workbench.saveActiveDocument())
        let newerContent = try String(contentsOf: file, encoding: .utf8)
        var staleEdit = current
        model.setCSGOperation(.intersect, for: box.id)
        staleEdit.content = try model.encodedYAML()
        staleEdit.sceneModel = model
        staleEdit.isDirty = true
        workbench.applySceneViewportEdit(staleEdit)
        #expect(!workbench.saveActiveDocument())
        #expect(try String(contentsOf: file, encoding: .utf8) == newerContent)
    }

    #if os(macOS) || os(Windows) || os(Linux)
    @Test("The two-room fixture passes a character through the doorway and stops it at the wall", .enabled(if: CSGGroupSource.isAvailable))
    @MainActor
    func walksThroughTheExportedDoorway() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CSGTwoRooms/Assets")
        let assets = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: fixture, to: assets)
        defer { try? FileManager.default.removeItem(at: assets) }
        let url = assets.appendingPathComponent("Scenes/TwoRooms.ascn")
        let model = try EditorSceneModel.decode(from: String(contentsOf: url, encoding: .utf8))
        let products = try await EditorCSGScene.prepare(model, sourceURL: url, resourceRootURL: assets)
        let usesCSG = try await EditorAdaScriptNativeExporter.convertScenes(at: assets, originalRoot: fixture, sources: [])
        #expect(usesCSG)

        let play = World()
        var result = EditorSceneFileLoader.load(model: model.withoutCSGAuthoring(), into: play, sourceURL: url, resourceRootURL: assets)
        EditorCSGScene.install(products, in: play, result: &result)
        try await verifyDoorway(in: play)

        let document = try JSONDecoder().decode(AdaScriptNativeSceneDocument.self, from: Data(contentsOf: url))
        let native = try document.makeScene(components: [], resourceRoot: assets, sourceURL: url)
        try await verifyDoorway(in: native.world)
    }

    @MainActor
    private func verifyDoorway(in world: World) async throws {
        let app = AppWorlds(main: world)
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(Physics3DPlugin())
        try await app.build()
        var controller = CharacterController3DComponent(radius: 0.3, height: 1.5)
        controller.desiredVelocity = [2.5, 0, 0]
        controller.acceleration = 100_000
        let doorway = world.spawn {
            controller
            Transform(position: [-1.5, 0.03, 0])
        }
        let wall = world.spawn {
            controller
            Transform(position: [-1.5, 0.03, 2])
        }
        await world.runScheduler(.physicsSync)
        world.insertResource(FixedTime(deltaTime: 1 / 60))
        for _ in 0..<85 {
            await world.runScheduler(.physicsStep)
            await world.runScheduler(.physicsWriteback)
        }
        let through = try #require(doorway.components[Transform.self]).position
        let blocked = try #require(wall.components[Transform.self]).position
        #expect(through.x > 0.8)
        #expect(abs(through.y) < 0.06)
        #expect(blocked.x < -0.2)
        #expect(blocked.x > -0.75)
    }
    #endif
}
