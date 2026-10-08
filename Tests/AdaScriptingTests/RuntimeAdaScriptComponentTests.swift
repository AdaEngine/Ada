@testable import AdaApp
import AdaECS
import AdaScripting
import Testing

@Suite("Portable AdaScript components", .serialized)
struct RuntimeAdaScriptComponentTests {
    @Test("Declares, spawns, queries, and mutates a component without generated Swift")
    @MainActor
    func roundTripsPortableComponent() async throws {
        let plugin = try AdaScriptPlugin(
            source: """
            @component(id: "test.runtime-health")
            struct RuntimeHealth {
                @export var current = 10;
                @export var title = "Player";
            }

            var spawned = false;

            @system(id: "runtime.health")
            class RuntimeHealthSystem {
                @query(RuntimeHealth)
                var entities;

                func update(context) {
                    if (!spawned) {
                        context.world.spawn([RuntimeHealth(current: 3, title: "Ada")]);
                        spawned = true;
                    }
                    for (var entity in entities) {
                        entity.runtimeHealth.current += 1;
                    }
                }
            }
            """,
            name: "RuntimeComponent"
        )
        let world = World(name: "Portable AdaScript component")
        plugin.setup(in: AppWorlds(main: world))

        await world.runScheduler(.update)
        await world.runScheduler(.update)

        let descriptor = try #require(world.runtimeComponentDescriptor(named: "RuntimeHealth"))
        let entity = try #require(world.getEntities().first)
        let component = try #require(world.getRuntimeComponent(descriptor.componentID, from: entity.id))
        #expect(component.values == [.int(4), .string("Ada")])
        #expect(plugin.diagnostics.isEmpty)
    }
}
