import AdaApp
import AdaECS
import AdaScripting
import Testing

@Suite("AdaScript hot reload", .serialized)
struct AdaScriptHotReloadTests {
    @Test("A valid edit replaces systems in the same world and an invalid edit keeps the last version")
    @MainActor
    func replacesRunningSystems() async throws {
        let world = World(name: "AdaScript live game")
        let app = AppWorlds(main: world)
        let plugin = try AdaScriptPlugin(source: Self.source(spawns: 1), name: "LiveGame")
        plugin.setup(in: app)

        await world.runScheduler(.update)
        #expect(world.getEntities().count == 1)

        try await plugin.reload(sources: [AdaScriptSource(path: "Main.ada", source: Self.source(spawns: 2))], in: app)
        await world.runScheduler(.update)
        #expect(world.getEntities().count == 3)

        do {
            try await plugin.reload(sources: [AdaScriptSource(path: "Main.ada", source: "@system class Broken {")], in: app)
            Issue.record("Invalid AdaScript unexpectedly reloaded")
        } catch {
            await world.runScheduler(.update)
            #expect(world.getEntities().count == 5)
        }

        let addedSystem = Self.source(spawns: 2) + """

        @system(id: "live.extra")
        class ExtraSystem {
            func update(context) { context.world.commands.spawn([]); }
        }
        """
        try await plugin.reload(sources: [AdaScriptSource(path: "Main.ada", source: addedSystem)], in: app)
        await world.runScheduler(.update)
        #expect(world.getEntities().count == 8)
    }

    private static func source(spawns: Int) -> String {
        let statements = Array(repeating: "context.world.commands.spawn([]);", count: spawns).joined(separator: "\n")
        return """
        @system(id: "live.spawn")
        class SpawnSystem {
            func update(context) {
                \(statements)
            }
        }
        """
    }
}
