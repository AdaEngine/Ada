@_spi(Internal) @testable import AdaApp
@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@Suite("Editor Terrain")
@MainActor
struct EditorTerrainTests {
    @Test("Terrain geometry has upward triangles, smooth normals and matching grid samples")
    func geometry() throws {
        var terrain = Terrain3D(resolution: 3, size: 4)
        terrain.heights[4] = 2
        let geometry = try terrain.geometry()
        #expect(geometry.positions.count == 9)
        #expect(geometry.indices.count == 24)
        #expect(geometry.positions[4] == Vector3(0, 2, 0))
        for index in stride(from: 0, to: geometry.indices.count, by: 3) {
            let a = geometry.positions[Int(geometry.indices[index])]
            let b = geometry.positions[Int(geometry.indices[index + 1])]
            let c = geometry.positions[Int(geometry.indices[index + 2])]
            #expect((b - a).cross(c - a).y > 0)
        }
        #expect(geometry.normals.allSatisfy { $0.y > 0 && abs($0.length - 1) < 0.001 })
        #expect(terrain.surfaceHeight(at: .zero) == 2)
        #expect(terrain.surfaceHeight(at: Vector2(1, 0)) == 1)
        #expect(terrain.surfaceHeight(at: Vector2(5, 0)) == nil)
    }

    @Test("Sculpted triangle geometry blocks a native physics sphere sweep at the raised height")
    func collision() async throws {
        let app = AppWorlds(main: World(name: "Terrain collision"))
        app.addPlugin(MainSchedulerPlugin()).addPlugin(Physics3DPlugin()).addPlugin(TransformPlugin())
        try await app.build()
        var terrain = Terrain3D(resolution: 5, size: 8)
        terrain.heights = Array(repeating: 3, count: 25)
        let geometry = try terrain.geometry()
        let shape = try Shape3DResource.generateTriangleMesh(vertices: geometry.positions, indices: geometry.indices)
        app.main.spawn {
            Transform()
            PhysicsBody3DComponent(shapes: [shape], mode: .static)
        }
        await app.main.runScheduler(.physicsSync)
        let physics = try #require(app.main.physicsWorld3D)
        let fraction = physics.sphereCastFraction(from: [0, 10, 0], to: [0, -10, 0], radius: 0.25)
        #expect(fraction > 0.33 && fraction < 0.35)
    }

    @Test("Brush falloff, direction and convergence are bounded")
    func brushes() {
        var terrain = Terrain3D(resolution: 9, size: 8)
        func apply(_ mode: EditorTerrainBrushMode, target: Float = 0) {
            EditorTerrainBrush.apply(to: &terrain, at: .zero, mode: mode, radius: 3, strength: 10, duration: 0.1, flattenHeight: target)
        }
        apply(.raise)
        #expect(terrain.heights[40] == 1)
        #expect(terrain.heights[41] > 0 && terrain.heights[41] < 1)
        #expect(terrain.heights[0] == 0)
        apply(.lower)
        #expect(abs(terrain.heights[40]) < 0.001)
        terrain.heights[40] = 5
        apply(.smooth)
        #expect(terrain.heights[40] > 0 && terrain.heights[40] < 5)
        apply(.flatten, target: 2)
        #expect(abs(terrain.heights[40] - 2) < 0.001)
        #expect(terrain.heights.allSatisfy { $0.isFinite })
    }

    @Test("Picking follows raised triangles and misses outside the terrain")
    func picking() throws {
        var terrain = Terrain3D(resolution: 3, size: 4)
        terrain.heights[4] = 3
        let hit = try #require(EditorTerrainBrush.hit(ray: Ray(origin: Vector3(0, 10, 0), direction: Vector3(0, -1, 0)), terrain: terrain))
        #expect(abs(hit.point.y - 3) < 0.001)
        #expect(EditorTerrainBrush.hit(ray: Ray(origin: Vector3(10, 10, 0), direction: Vector3(0, -1, 0)), terrain: terrain) == nil)
    }

    @Test("Malformed terrain is rejected before allocation or mesh generation")
    func validation() throws {
        var terrain = Terrain3D()
        terrain.resolution = Int.max
        #expect(throws: Terrain3D.ValidationError.self) { try terrain.geometry() }
        terrain = Terrain3D()
        terrain.heights[0] = .nan
        #expect(throws: Terrain3D.ValidationError.self) { try terrain.geometry() }
        let invalid = Data(#"{"resolution":999999999,"size":64,"heights":[]}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Terrain3D.self, from: invalid) }
    }

    @Test("Terrain payload and scene save/reopen retain every height and collision setting")
    func persistence() throws {
        var terrain = Terrain3D(resolution: 5, size: 12)
        terrain.heights[12] = 3.25
        terrain.generatesCollision = false
        var model = EditorSceneModel.default(projectName: "Terrain")
        let id = model.addEntity(name: "Ground", parentID: nil).id
        let index = try #require(model.entities.firstIndex { $0.id == id })
        model.entities[index].components[EditorTerrainPayload.typeName] = EditorTerrainPayload.encode(terrain)
        let reopened = try EditorSceneModel.decode(from: model.encodedYAML())
        let payload = try #require(reopened.entities.first { $0.id == id }?.components[EditorTerrainPayload.typeName])
        #expect(EditorTerrainPayload.decode(payload) == terrain)
        let world = World(name: "Terrain load")
        let loaded = EditorSceneFileLoader.load(content: try model.encodedYAML(), into: world)
        let entity = loaded.entitiesByEditorID[id].flatMap { world.getEntityByID($0) }
        #expect(entity?.components[Terrain3D.self] == terrain)
    }

    @Test("Inspector colour edits retain the engine's vector encoding")
    func inspectorColor() throws {
        var payload = EditorTerrainPayload.encode(Terrain3D())
        let field = try #require(EditorComponentRegistry.terrainDescriptor.fields.first { $0.key == "color" })
        field.write("0.1, 0.2, 0.3, 1", to: &payload)
        let terrain = try #require(EditorTerrainPayload.decode(payload))
        #expect(terrain.color == Vector4(0.1, 0.2, 0.3, 1))
    }

    @Test("A complete stroke publishes one history edit and Escape restores the original")
    func strokeTransaction() throws {
        let viewport = EditorSceneViewportModel()
        var model = EditorSceneModel.default(projectName: "Terrain")
        let id = model.addEntity(name: "Ground", parentID: nil).id
        let index = try #require(model.entities.firstIndex { $0.id == id })
        model.entities[index].components[EditorTerrainPayload.typeName] = EditorTerrainPayload.encode(Terrain3D(resolution: 17, size: 16))
        var edits: [String] = []
        viewport.configure(sceneContent: try model.encodedYAML(), model: model, onSelectionChanged: { _ in }, onDocumentContentChanged: { edits.append($0) })
        viewport.setViewportSize(Size(width: 800, height: 600))
        viewport.setTerrainEditing(true)
        viewport.perspectiveBlend = 1
        let screen = try #require(viewport.project(.zero, size: viewport.viewportSize))
        let point = Point(x: screen.x, y: screen.y)
        #expect(viewport.handleTerrainPointer(at: point, began: true))
        #expect(viewport.terrainEditing.stroke != nil)
        for _ in 0..<4 { _ = viewport.updateTerrainStroke(deltaTime: 0.05) }
        #expect(edits.isEmpty)
        viewport.endTerrainStroke()
        #expect(edits.count == 1)
        let committed = try #require(viewport.sceneModel)
        #expect(EditorTerrainPayload.decode(try #require(committed.entities[index].components[EditorTerrainPayload.typeName]))?.heights.contains(where: { $0 > 0 }) == true)
        _ = viewport.handleTerrainPointer(at: point, began: true)
        _ = viewport.updateTerrainStroke(deltaTime: 0.05)
        viewport.endTerrainStroke(cancelled: true)
        #expect(viewport.sceneModel == committed)
        #expect(edits.count == 1)
    }
}
