@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Testing

@MainActor
@Suite("Terrain runtime tiles", .serialized)
struct TerrainRuntimeTests {
    private func makeApp(physics: Bool = false) async throws -> AppWorlds {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        if physics { app.addPlugin(Physics3DPlugin()) }
        try await app.build()
        return app
    }

    private func settle(_ app: AppWorlds) async {
        for _ in 0..<3 { await app.main.runScheduler(.preUpdate) }
    }

    private func tiles(of owner: Entity) -> [TerrainTileCoordinate: Entity] {
        Dictionary(
            uniqueKeysWithValues: owner.children.compactMap { entity in
                entity.components[TerrainTile3DComponent.self].map { ($0.coordinate, entity) }
            }
        )
    }

    private func buffers(of owner: Entity) throws -> [TerrainTileCoordinate: ObjectIdentifier] {
        try tiles(of: owner).mapValues { entity in
            let mesh = try #require(entity.components[Mesh3DComponent.self]?.mesh)
            let part = try #require(mesh.models.first?.parts.first)
            return ObjectIdentifier(part.vertexBuffer)
        }
    }

    @Test("Local edits replace only affected tile buffers; color, idle frames and transforms retain them")
    func incrementalMeshesAndCleanup() async throws {
        let app = try await makeApp()
        var terrain = Terrain3D(resolution: 129, size: 128)
        terrain.generatesCollision = false
        let owner = app.main.spawn("Terrain") {
            Transform(); terrain
        }
        await settle(app)
        let initial = tiles(of: owner)
        #expect(initial.count == 4)
        let original = try buffers(of: owner)
        #expect(original.count == 4)
        terrain.heights[10 * 129 + 10] = 3
        owner.components[Terrain3D.self] = terrain
        await settle(app)
        let edited = try buffers(of: owner)
        #expect(edited[.init(x: 0, z: 0)] != original[.init(x: 0, z: 0)])
        for coordinate in original.keys where coordinate != .init(x: 0, z: 0) {
            #expect(edited[coordinate] == original[coordinate])
            #expect(tiles(of: owner)[coordinate]?.id == initial[coordinate]?.id)
        }
        terrain.color = [0.8, 0.3, 0.1, 1]
        owner.components[Terrain3D.self] = terrain
        await settle(app)
        #expect(try buffers(of: owner) == edited)
        let materials = try tiles(of: owner).values.map { tile in
            try #require(tile.components[Mesh3DComponent.self]?.materials.first as? PBRMaterial)
        }
        #expect(materials.count == 4)
        #expect(Set(materials.map(ObjectIdentifier.init)).count == 1)
        #expect(materials.allSatisfy { $0.baseColorFactor == terrain.color })
        owner.components[Transform.self] = Transform(position: [5, 2, 3])
        await settle(app)
        #expect(try buffers(of: owner) == edited)
        await settle(app)
        #expect(try buffers(of: owner) == edited)
        terrain.heights[64 * 129 + 64] = 4
        owner.components[Terrain3D.self] = terrain
        await settle(app)
        let corner = try buffers(of: owner)
        #expect(corner.count == 4)
        #expect(corner.allSatisfy { edited[$0.key] != $0.value })
        owner.components.remove(Terrain3D.self)
        await settle(app)
        #expect(tiles(of: owner).isEmpty)
        #expect(owner.children.isEmpty)
    }

    @Test("Tile colliders follow reflected parent transforms and disappear when collision is disabled")
    func transformedCollision() async throws {
        let app = try await makeApp(physics: true)
        var terrain = Terrain3D(resolution: 129, size: 128)
        terrain.heights = Array(repeating: 2, count: 129 * 129)
        let parent = app.main.spawn("Environment") { Transform(position: [0, 3, 0]) }
        let owner = app.main.spawn("Terrain") {
            Transform(scale: [-1, 1, 1]); terrain
        }
        parent.addChild(owner)
        await settle(app)
        await app.main.runScheduler(.physicsSync)
        let physics = try #require(app.main.physicsWorld3D)
        let before = physics.sphereCastFraction(from: [-20, 10, -20], to: [-20, -10, -20], radius: 0.25)
        #expect(before > 0.23 && before < 0.25)
        parent.components[Transform.self] = Transform(position: [0, 5, 0])
        await settle(app)
        await app.main.runScheduler(.physicsSync)
        let moved = physics.sphereCastFraction(from: [-20, 10, -20], to: [-20, -10, -20], radius: 0.25)
        #expect(moved > 0.13 && moved < 0.15)
        terrain.generatesCollision = false
        owner.components[Terrain3D.self] = terrain
        await settle(app)
        await app.main.runScheduler(.physicsSync)
        #expect(physics.sphereCastFraction(from: [-20, 10, -20], to: [-20, -10, -20], radius: 0.25) == 1)
    }
}
