import AdaApp
import AdaECS
import AdaScene
import AdaScripting
import Foundation
import Testing

@Suite("AdaScript scene navigation", .serialized)
struct AdaScriptSceneNavigationTests {
    @Test("An AdaScript system can restart the active scene")
    @MainActor
    func reloadFromSystem() async throws {
        let world = World(name: "AdaScript navigation")
        let app = AppWorlds(main: world)
        ScenePlugin(includesModel3D: false).setup(in: app)
        let navigator = try #require(world.getResource(SceneNavigator.self))
        let scene = Scene(name: "Level")
        scene.world.spawn("Old player") {}
        navigator.installInitialScene(scene, make: {
            let replacement = Scene(name: "Level")
            replacement.world.spawn("New player") {}
            return replacement
        })

        let plugin = try AdaScriptPlugin(
            source: """
            @system(id: "navigation.restart")
            class RestartSystem {
                func update(context) {
                    context.world.spawn([]);
                    context.world.reloadScene();
                }
            }
            """,
            name: "SceneNavigation"
        )
        plugin.setup(in: app)
        await world.runScheduler(.update)
        for _ in 0..<100 where world.getEntityByName("New player") == nil {
            await world.runScheduler(.postUpdate)
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(world.getEntityByName("Old player") == nil)
        #expect(world.getEntityByName("New player") != nil)
        #expect(world.getEntities().count == 2)
        #expect(plugin.diagnostics.isEmpty, Comment(rawValue: plugin.diagnostics.joined(separator: "\n")))
    }
}
