import AdaApp
import AdaAssets
import AdaECS
import AdaScene
import Foundation
import Testing

@Suite("Scene navigator", .serialized)
struct SceneNavigatorTests {
    @Test("Reload recreates scene entities and scene resources")
    @MainActor
    func reloadsFreshSceneState() async throws {
        let world = World(name: "Navigation test")
        ScenePlugin(includesModel3D: false).setup(in: AppWorlds(main: world))
        let navigator = try #require(world.getResource(SceneNavigator.self))
        let counter = SceneFactoryCounter()
        let make: @MainActor @Sendable () throws -> Scene = {
            let scene = Scene(name: "Level")
            scene.world.spawn("Enemy \(counter.next())") {}
            scene.world.insertResource(LevelHealth(value: 100))
            return scene
        }
        navigator.installInitialScene(try make(), make: make)

        let firstEnemy = try #require(world.getEntityByName("Enemy 1"))
        world.getRefResource(LevelHealth.self).wrappedValue.value = 0
        let effect = world.spawn("Transient effect") {}
        navigator.trackSceneEntity(effect.id)

        let reload = Task { try await navigator.reloadScene() }
        for _ in 0..<100 where world.getEntityByName("Enemy 2") == nil {
            await world.runScheduler(.postUpdate)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await reload.value

        #expect(world.getEntityByID(firstEnemy.id) == nil)
        #expect(world.getEntityByName("Enemy 2") != nil)
        #expect(world.getResource(LevelHealth.self)?.value == 100)
        #expect(world.getEntityByName("Transient effect") == nil)
    }

    @Test("Failed replacement preserves the running scene")
    @MainActor
    func preservesSceneAfterLoadFailure() async throws {
        let world = World(name: "Navigation failure")
        ScenePlugin(includesModel3D: false).setup(in: AppWorlds(main: world))
        let navigator = try #require(world.getResource(SceneNavigator.self))
        let scene = Scene(name: "Still here")
        scene.world.spawn("Player") {}
        navigator.installInitialScene(scene, make: { Scene(name: "Still here") })

        await #expect(throws: (any Error).self) {
            try await navigator.replaceScene(with: "@res://Missing/level.ascn")
        }
        await world.runScheduler(.postUpdate)
        #expect(world.getEntityByName("Player") != nil)
        #expect(navigator.lastError != nil)
    }

    @Test("Asset scene reload decodes a new template")
    @MainActor
    func reloadsAssetScene() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneNavigator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await AssetsManager.setProjectDirectories(
            ProjectDirectories(
                source: root,
                assetsDirectory: root.appendingPathComponent("Assets", isDirectory: true),
                userDataDirectory: root.appendingPathComponent("User", isDirectory: true),
                cacheDirectory: root.appendingPathComponent("Cache", isDirectory: true)
            )
        )
        let path = "@res://Scenes/Level.ascn"
        let scene = Scene(name: "File level")
        scene.world.spawn("File player") {}
        try await AssetsManager.save(scene, at: path)

        let world = World(name: "Asset navigation")
        ScenePlugin(includesModel3D: false).setup(in: AppWorlds(main: world))
        let navigator = try #require(world.getResource(SceneNavigator.self))
        let load = Task { try await navigator.replaceScene(with: path) }
        for _ in 0..<100 where world.getEntityByName("File player") == nil {
            await world.runScheduler(.postUpdate)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await load.value
        let original = try #require(world.getEntityByName("File player"))

        let reload = Task { try await navigator.reloadScene() }
        for _ in 0..<100 where world.getEntityByID(original.id) != nil {
            await world.runScheduler(.postUpdate)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await reload.value
        #expect(world.getEntityByID(original.id) == nil)
        #expect(world.getEntityByName("File player") != nil)
        #expect(navigator.currentScenePath == path)
    }
}

private struct LevelHealth: Resource {
    var value: Int
}

@MainActor
private final class SceneFactoryCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}
