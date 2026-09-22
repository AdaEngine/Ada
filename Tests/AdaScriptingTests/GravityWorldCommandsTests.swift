@testable import AdaApp
import AdaECS
import AdaScripting
import Math
import Testing

@Suite("Gravity world commands", .serialized)
struct GravityWorldCommandsTests {
    @Test("Defers despawns until pointer-backed query iteration finishes")
    @MainActor
    func defersDespawnDuringIteration() async throws {
        registerComponents()
        let plugin = try AdaScriptPlugin(
            source: """
            @system(id: "cleanup.system")
            class CleanupSystem {
                @query(CommandMarker)
                var entities;

                func update(context) {
                    for (var entity in entities) {
                        context.world.commands.despawn(entity.id);
                    }
                }
            }
            """,
            name: "DeferredDespawn"
        )
        let world = World(name: "Deferred despawn")
        let first = world.spawn { CommandMarker() }
        let second = world.spawn { CommandMarker() }

        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)

        #expect(plugin.diagnostics.isEmpty)
        #expect(world.get(CommandMarker.self, from: first.id) == nil)
        #expect(world.get(CommandMarker.self, from: second.id) == nil)
    }

    @Test("Spawns, inserts, and removes detached component defaults")
    @MainActor
    func mutatesStructureWithDefaults() async throws {
        registerComponents()
        let plugin = try AdaScriptPlugin(
            source: """
            @system(id: "spawn.system")
            class SpawnSystem {
                func update(context) {
                    var entity = context.world.commands.spawn(["test.spawned"]);
                    context.world.commands.insert(entity, "test.extra");
                    context.world.commands.remove(entity, "test.extra");
                }
            }
            """,
            name: "DeferredSpawn"
        )
        let world = World(name: "Deferred spawn")

        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)

        let spawned = try #require(world.getEntities().first)
        #expect(plugin.diagnostics.isEmpty)
        #expect(world.get(CommandSpawned.self, from: spawned.id) != nil)
        #expect(world.get(CommandExtra.self, from: spawned.id) == nil)
    }

    @Test("Spawns initialized component values through the world facade")
    @MainActor
    func spawnsInitializedComponents() async throws {
        registerComponents()
        let plugin = try AdaScriptPlugin(
            source: """
            @system(id: "typed.spawn.system")
            class TypedSpawnSystem {
                func update(context) {
                    context.world.spawn([
                        CommandConfigured(position: Vector3(4, 5, 6), count: 7)
                    ]);
                }
            }
            """,
            name: "TypedDeferredSpawn"
        )
        let world = World(name: "Typed deferred spawn")

        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)

        let spawned = try #require(world.getEntities().first)
        let component = try #require(world.get(CommandConfigured.self, from: spawned.id))
        #expect(plugin.diagnostics.isEmpty)
        #expect(component.position == Vector3(4, 5, 6))
        #expect(component.count == 7)
    }

    @Test("Supports Vector3.ZERO in component constructors")
    @MainActor
    func supportsVectorZero() async throws {
        registerComponents()
        let plugin = try AdaScriptPlugin(
            source: """
            @system(id: "zero.spawn.system")
            class ZeroSpawnSystem {
                func update(context) {
                    context.world.spawn([CommandConfigured(position: Vector3.ZERO)]);
                }
            }
            """,
            name: "ZeroDeferredSpawn"
        )
        let world = World(name: "Zero deferred spawn")

        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)

        let spawned = try #require(world.getEntities().first)
        #expect(plugin.diagnostics.isEmpty)
        #expect(world.get(CommandConfigured.self, from: spawned.id)?.position == .zero)
    }

    @Test("Rejects a retained commands capability after its callback")
    @MainActor
    func rejectsRetainedCapability() async throws {
        registerComponents()
        let plugin = try AdaScriptPlugin(
            source: """
            var savedCommands = 0;
            var commandUpdates = 0;

            @system(id: "retained.system")
            class RetainedSystem {
                func update(context) {
                    if (commandUpdates == 0) {
                        savedCommands = context.world.commands;
                    } else {
                        savedCommands.spawn(["test.spawned"]);
                    }
                    commandUpdates += 1;
                }
            }
            """,
            name: "RetainedCommands"
        )
        let world = World(name: "Retained commands")

        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)
        await world.runScheduler(.update)

        #expect(world.getEntities().isEmpty)
        #expect(plugin.diagnostics == ["World commands capability is no longer valid"])
    }

    @Test("Rejects command access that was not declared by static capability inference")
    @MainActor
    func rejectsUndeclaredCapability() async throws {
        registerComponents()
        let plugin = try AdaScriptPlugin(
            source: """
            @system(id: "undeclared.system")
            class UndeclaredSystem {
                func update(context) {
                    var world = context.world;
                    world.commands.spawn(["test.spawned"]);
                }
            }
            """,
            name: "UndeclaredCommands"
        )
        let world = World(name: "Undeclared commands")

        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)

        #expect(world.getEntities().isEmpty)
        #expect(plugin.diagnostics == ["System did not declare deferred world command access"])
    }

    @MainActor
    private func registerComponents() {
        RuntimeTypeRegistry.registerComponent(
            CommandMarker.self,
            names: ["CommandMarker", "test.marker"],
            makeDefault: { CommandMarker() }
        )
        RuntimeTypeRegistry.registerComponent(
            CommandSpawned.self,
            names: ["CommandSpawned", "test.spawned"],
            makeDefault: { CommandSpawned() }
        )
        RuntimeTypeRegistry.registerComponent(
            CommandExtra.self,
            names: ["CommandExtra", "test.extra"],
            makeDefault: { CommandExtra() }
        )
        RuntimeTypeRegistry.registerComponent(
            CommandConfigured.self,
            names: ["CommandConfigured"],
            makeDefault: { CommandConfigured() }
        )
        ComponentReflectionRegistry.register(CommandConfigured.componentDescriptor)
    }
}

@Component
private struct CommandMarker {}

@Component
private struct CommandSpawned {}

@Component
private struct CommandExtra {}

@Component
private struct CommandConfigured {
    var position: Vector3 = .zero
    var count: Int = 0
}
