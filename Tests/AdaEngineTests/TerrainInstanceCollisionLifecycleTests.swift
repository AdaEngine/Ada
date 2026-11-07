@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
@testable import AdaScene
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    func collisionFixture(_ directory: URL, count: Int, surface: Bool = true) async throws -> URL {
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("prop.gltf"))
        let rows = try (0..<count).map { index in
            try TerrainRegionInstance(id: UInt64(index + 1), prototypeID: 7, localPosition: [30 + Float(index), 1, 30], flags: [.collision])
        }
        let region = TerrainRegionAsset(x: 0, z: 0, tiles: surface ? [.init(x: 0, z: 0)] : [], pages: [], instances: rows)
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([region], manifest: .init(meshPrototypes: [.init(id: 7, assetPath: "prop.gltf")]), at: file.path)
        return file
    }

    @Test("Mesh brush collision opt-in survives native save and Undo", arguments: [false, true])
    func terrainCollisionBrushHistory(enabled: Bool) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await collisionFixture(directory, count: 0)
        let app = try await makeApp(physics: true)
        let owner = app.main.spawn("Collision brush") {
            Transform()
            Terrain3DSource(source: file.path, maximumLOD: 0, streamingRadius: nil, instanceCollision: .init(maximumCount: 1))
        }
        app.main.spawn("Camera") { Transform(position: [20, 4, 20]); Camera() }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        var settings = TerrainInstanceBrushSettings(prototypeID: 7, radius: 2, density: 4)
        settings.shape = .hardRound
        settings.minimumDistance = 1
        settings.requestsCollision = enabled
        owner.components[Terrain3DEdit.self] = .init(storage: storage, brush: .init(settings: settings, points: [.init(position: [20, 0, 20], time: 0)]))
        await settle(app)
        #expect(owner.components[Terrain3DEditStatus.self]?.phase == .applied)
        let rows = try #require(try storage.regionAsset(at: .init(x: 0, z: 0))).instances
        try #require(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.flags.contains(.collision) == enabled })
        #expect(owner.components[Terrain3DSourceStatus.self]?.instanceColliderCount == (enabled ? 1 : 0))
        let delta = try #require(owner.components[Terrain3DEditStatus.self]?.delta)
        owner.components[Terrain3DSave.self] = .init(storage: storage)
        await finishSave(app, owner: owner)
        let manifest = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        let reference = try #require(manifest.heightRegions.first)
        let saved = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(reference.fileName).path)
        #expect(saved.instances == rows)
        owner.components[Terrain3DEdit.self] = .init(storage: storage, undoing: delta)
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.instanceColliderCount == 0)
        #expect(owner.children.filter { $0.name.hasPrefix("Terrain Prop Collision") }.isEmpty)
    }

    @Test("Nearby prop BVHs are paced and published together; rejection preserves collision and disabling removes it")
    func terrainCollisionPublicationBudget() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await collisionFixture(directory, count: 8)
        let app = try await makeApp(physics: true)
        var source = Terrain3DSource(
            source: file.path,
            maximumLOD: 0,
            streamingRadius: nil,
            maximumTileUpdatesPerFrame: 1,
            instanceCollision: .init(distance: 64, maximumCount: 8, maximumUpdatesPerFrame: 1)
        )
        let owner = app.main.spawn("Paced prop collision") { Transform(); source }
        let camera = app.main.spawn("Camera") { Transform(position: [32, 4, 30]); Camera() }
        let metrics = try #require(app.main.physicsWorld3D).collisionPreparationMetrics
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(15))
        while clock.now < deadline {
            let before = metrics.snapshot.nativeTriangleMeshCount
            await app.main.runScheduler(.preUpdate)
            #expect(metrics.snapshot.nativeTriangleMeshCount - before <= 2)
            let children = owner.children.filter { $0.name.hasPrefix("Terrain Prop Collision") }
            #expect(children.isEmpty || children.count == 8)
            if owner.components[Terrain3DSourceStatus.self]?.isReady == true { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(owner.components[Terrain3DSourceStatus.self]?.instanceColliderCount == 8)
        #expect(metrics.snapshot.nativeTriangleMeshCount == 9)
        let old = Set(owner.children.filter { $0.name.hasPrefix("Terrain Prop Collision") }.map(\.id))
        camera.components[Transform.self]?.position.x += 0.25
        await settle(app)
        #expect(metrics.snapshot.nativeTriangleMeshCount == 9)
        #expect(Set(owner.children.filter { $0.name.hasPrefix("Terrain Prop Collision") }.map(\.id)) == old)
        source.instanceCollision.maximumBytes = 0
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.error?.contains("collision") == true)
        #expect(Set(owner.children.filter { $0.name.hasPrefix("Terrain Prop Collision") }.map(\.id)) == old)
        source.generatesCollision = false
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(owner.components[Terrain3DSourceStatus.self]?.instanceColliderCount == 0)
        #expect(owner.children.filter { $0.components[PhysicsBody3DComponent.self] != nil }.isEmpty)
    }

    @Test("Fixed synchronization waits for nearby props after an in-region teleport and retains the published count")
    func terrainCollisionPhysicsReadiness() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await collisionFixture(directory, count: 1)
        let app = try await makeApp(physics: true)
        let owner = app.main.spawn("Physics prop collision") {
            Transform()
            Terrain3DSource(source: file.path, maximumLOD: 0, streamingRadius: nil, instanceCollision: .init(distance: 4))
        }
        let body = app.main.spawn("Teleported dynamic body") {
            Transform(position: [5, 3, 5])
            PhysicsBody3DComponent(shapes: [.generateSphere(radius: 0.25)], mode: .dynamic)
        }
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.instanceColliderCount == 0)
        body.components[Transform.self]?.position = [30, 3, 30]
        await app.main.runScheduler(.physicsSync)
        let gate = try #require(app.main.getResource(PhysicsSimulationGate3D.self))
        #expect(!gate.isReady)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == false)
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.instanceColliderCount == 1)
        await app.main.runScheduler(.physicsSync)
        #expect(gate.isReady)
        #expect(owner.components[Terrain3DSourceStatus.self]?.instanceColliderCount == 1)
    }
}
