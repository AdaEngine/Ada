@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Removing only the authored owner cleans generated terrain while preserving ordinary children", arguments: [false, true])
    func cleansOrphanedTerrain(sourceBacked: Bool) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await save(Terrain3D(resolution: 65, size: 64), in: directory)
        let app = try await makeApp(physics: true)
        let owner = app.main.spawn("Terrain") { Transform() }
        if sourceBacked { owner.components[Terrain3DSource.self] = .init(source: file.path) } else { owner.components[Terrain3D.self] = .init(resolution: 65, size: 64) }
        let authored = app.main.spawn("Hand placed prop") { Transform(position: [100, 0, 100]) }
        owner.addChild(authored)
        await settle(app)
        await app.main.runScheduler(.physicsSync)
        let physics = try #require(app.main.physicsWorld3D)
        #expect(physics.sphereCastFraction(from: [10, 10, 10], to: [10, -10, 10], radius: 0.25) < 1)
        let generated = owner.children.filter { $0.id != authored.id }.map(\.id)
        #expect(generated.count == 2)
        app.main.removeEntity(owner)
        await settle(app)
        await app.main.runScheduler(.physicsSync)
        #expect(generated.allSatisfy { app.main.getEntityByID($0) == nil })
        #expect(app.main.getEntityByID(authored.id) != nil)
        #expect(physics.sphereCastFraction(from: [10, 10, 10], to: [10, -10, 10], radius: 0.25) == 1)
    }

    @Test("Saving and reopening a running scene persists authored terrain without generated meshes or baked collision", arguments: [false, true])
    func scenePersistenceDiscardsGeneratedTerrain(sourceBacked: Bool) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await save(Terrain3D(resolution: 65, size: 64), in: directory)
        let app = try await makeApp(physics: true)
        let owner = app.main.spawn("Saved terrain") { Transform() }
        if sourceBacked { owner.components[Terrain3DSource.self] = .init(source: file.path) } else { owner.components[Terrain3D.self] = .init(resolution: 65, size: 64) }
        owner.addChild(app.main.spawn("Hand placed prop") { Transform(position: [100, 0, 100]) })
        await settle(app)
        await app.main.runScheduler(.physicsSync)
        let sceneFile = directory.appendingPathComponent("level.ascn")
        // Copy the ECS world without process-local app resources, as an authored scene snapshot.
        try await AssetsManager.save(Scene(from: app.main.copy()), at: sceneFile.path)
        let reopened = try await AssetsManager.loadFresh(Scene.self, at: sceneFile.path)
        #expect(reopened.world.getEntities().count == 2)
        #expect(reopened.world.getEntities().allSatisfy { $0.components[PhysicsBody3DComponent.self] == nil })
        let restored = try await makeApp(physics: true, world: reopened.world)
        await settle(restored)
        await restored.main.runScheduler(.physicsSync)
        let restoredOwner = try #require(restored.main.getEntityByName("Saved terrain"))
        #expect(restoredOwner.children.count == 3)
        if sourceBacked { restoredOwner.components.remove(Terrain3DSource.self) } else { restoredOwner.components.remove(Terrain3D.self) }
        await settle(restored)
        await restored.main.runScheduler(.physicsSync)
        let physics = try #require(restored.main.physicsWorld3D)
        #expect(physics.sphereCastFraction(from: [10, 10, 10], to: [10, -10, 10], radius: 0.25) == 1)
        #expect(restored.main.getEntityByName("Hand placed prop") != nil)
    }
}

extension TerrainSourceRuntimeTests {
    @Test("Scene persistence retains authored parents and transforms while excluding generated descendants")
    func sceneRetainsAuthoredHierarchy() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await makeApp(physics: true)
        let environment = app.main.spawn("Environment") { Transform(position: [0, 3, 0]) }
        let owner = app.main.spawn("Authored terrain") {
            Transform(position: [0, 2, 0]); Terrain3D(resolution: 65, size: 64)
        }
        environment.addChild(owner)
        let prop = app.main.spawn("Authored prop") { Transform(position: [100, 0, 0]) }
        owner.addChild(prop)
        await settle(app)
        let file = directory.appendingPathComponent("hierarchy.ascn")
        try await AssetsManager.save(Scene(from: app.main.copy()), at: file.path)
        let loaded = try await AssetsManager.loadFresh(Scene.self, at: file.path)
        let restoredOwner = try #require(loaded.world.getEntityByName("Authored terrain"))
        let restoredEnvironment = try #require(loaded.world.getEntityByName("Environment"))
        let restoredProp = try #require(loaded.world.getEntityByName("Authored prop"))
        #expect(restoredOwner.parent?.id == restoredEnvironment.id)
        #expect(restoredProp.parent?.id == restoredOwner.id)
        #expect(restoredEnvironment.children.map(\.id) == [restoredOwner.id])
        #expect(restoredOwner.children.map(\.id) == [restoredProp.id])
        #expect(restoredOwner.components[RelationshipComponent.self]?.children.allSatisfy { loaded.world.getEntityByID($0) != nil } == true)
        let restored = try await makeApp(physics: true, world: loaded.world)
        await settle(restored)
        await restored.main.runScheduler(.physicsSync)
        let physics = try #require(restored.main.physicsWorld3D)
        let fraction = physics.sphereCastFraction(from: [10, 10, 10], to: [10, -10, 10], radius: 0.25)
        #expect(fraction > 0.23 && fraction < 0.25)
    }
}

extension TerrainSourceRuntimeTests {
    @Test("A transient group excludes all descendants and restored IDs remain safe for new authored entities")
    func transientHierarchyAndRestoredIDs() throws {
        Transform.registerComponent()
        let world = World()
        let root = world.spawn("Authored root") { Transform() }
        let generated = world.spawn("Generated group") { Transform(); TransientEntity() }
        root.addChild(generated)
        generated.addChild(world.spawn("Unmarked generated descendant") { Transform() })
        let retained = world.spawn("Authored child") { Transform() }
        root.addChild(retained)
        let decoded = try JSONDecoder().decode(World.self, from: JSONEncoder().encode(world))
        #expect(Set(decoded.getEntities().map(\.name)) == ["Authored root", "Authored child"])
        let restoredRoot = try #require(decoded.getEntityByName("Authored root"))
        let restoredChild = try #require(decoded.getEntityByName("Authored child"))
        #expect(restoredRoot.children.map(\.id) == [restoredChild.id])
        #expect(restoredChild.parent?.id == restoredRoot.id)
        let next = decoded.spawn("New authored entity") { Transform() }
        #expect(next.id > max(restoredRoot.id, restoredChild.id))
        #expect(decoded.getEntityByID(restoredRoot.id)?.name == "Authored root")
        #expect(decoded.getEntityByID(restoredChild.id)?.name == "Authored child")
    }
}
