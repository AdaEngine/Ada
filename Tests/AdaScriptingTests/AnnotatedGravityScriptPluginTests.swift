@testable import AdaApp
import AdaECS
import AdaScripting
import Testing

@Suite("Annotation-driven Gravity scripts", .serialized)
struct AnnotatedAdaScriptPluginTests {
    @Test("Rejects legacy main manifests")
    func rejectsMainFunction() {
        #expect(throws: AdaScriptError.self) {
            try AdaScriptPlugin(source: """
            @system(scheduler: "update")
            class EmptySystem {
                func update(context) {}
            }

            func main() {
                return null;
            }
            """)
        }
    }

    @Test("Rejects queries outside annotated systems")
    func rejectsOrphanQueries() {
        #expect(throws: AdaScriptError.self) {
            try AdaScriptPlugin(source: """
            @query(AnnotatedPosition)
            var orphan;

            @system(scheduler: "update")
            class EmptySystem {
                func update(context) {}
            }
            """)
        }
    }

    @Test("Discovers a system and runs a pointer-backed query iterator")
    @MainActor
    func runsAnnotatedMovementSystem() async throws {
        AnnotatedPosition.registerComponent()
        AnnotatedVelocity.registerComponent()
        AnnotatedMovable.registerComponent()
        AnnotatedFrozen.registerComponent()

        let plugin = try AdaScriptPlugin(source: """
        @system(scheduler: "update", id: "annotated.movement")
        class MovementSystem {
            @query(
                AnnotatedPosition,
                AnnotatedVelocity,
                with: AnnotatedMovable,
                without: AnnotatedFrozen
            )
            var movers;

            func update(context) {
                var count = 0;
                for (var entity in movers) {
                    entity.annotatedPosition.value += entity.annotatedVelocity.value;
                    count += 1;
                }
                return count;
            }
        }
        """, name: "AnnotatedMovement")

        let world = World(name: "Annotated Gravity test")
        world.insertResource(DeltaTime(deltaTime: 2))
        let first = world.spawn {
            AnnotatedPosition(value: 1)
            AnnotatedVelocity(value: 3)
            AnnotatedMovable()
        }
        let second = world.spawn {
            AnnotatedPosition(value: 10)
            AnnotatedVelocity(value: -2)
            AnnotatedMovable()
        }
        let filtered = world.spawn {
            AnnotatedPosition(value: 20)
            AnnotatedVelocity(value: 100)
            AnnotatedMovable()
            AnnotatedFrozen()
        }

        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)

        #expect(plugin.diagnostics.isEmpty)
        #expect(world.get(AnnotatedPosition.self, from: first.id)?.value == 4)
        #expect(world.get(AnnotatedPosition.self, from: second.id)?.value == 8)
        #expect(world.get(AnnotatedPosition.self, from: filtered.id)?.value == 20)
    }

    @Test("Orders systems with before and after annotations")
    @MainActor
    func ordersAnnotatedSystems() async throws {
        AnnotatedPosition.registerComponent()

        let plugin = try AdaScriptPlugin(source: """
        @system(id: "add")
        class AddSystem {
            @query(AnnotatedPosition)
            var positions;

            func update(context) {
                for (var entity in positions) {
                    entity.annotatedPosition.value += 1;
                }
            }
        }

        @after(id: "add")
        @before(id: "finish")
        @system(id: "double")
        class DoubleSystem {
            @query(AnnotatedPosition)
            var positions;

            func update(context) {
                for (var entity in positions) {
                    entity.annotatedPosition.value *= 2;
                }
            }
        }

        @system(id: "finish")
        class FinishSystem {
            @query(AnnotatedPosition)
            var positions;

            func update(context) {
                for (var entity in positions) {
                    entity.annotatedPosition.value += 3;
                }
            }
        }
        """, name: "SystemOrdering")

        let world = World(name: "Ada Script system ordering test")
        let entity = world.spawn {
            AnnotatedPosition(value: 1)
        }

        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)

        #expect(plugin.diagnostics.isEmpty)
        #expect(world.get(AnnotatedPosition.self, from: entity.id)?.value == 7)
    }

    @Test("Validates system dependency annotations")
    func validatesSystemDependencies() {
        #expect(throws: AdaScriptError.invalidManifest(
            "system 'consumer' depends on unknown system 'missing'"
        )) {
            try AdaScriptPlugin(source: """
            @after(id: "missing")
            @system(id: "consumer")
            class ConsumerSystem { func update(context) {} }
            """)
        }

        #expect(throws: AdaScriptError.invalidManifest(
            "systems 'consumer' and 'bootstrap' must use the same scheduler"
        )) {
            try AdaScriptPlugin(source: """
            @system(scheduler: "startup", id: "bootstrap")
            class BootstrapSystem { func update(context) {} }

            @after(id: "bootstrap")
            @system(id: "consumer")
            class ConsumerSystem { func update(context) {} }
            """)
        }

        #expect(throws: AdaScriptError.invalidManifest(
            "system 'recursive' cannot depend on itself"
        )) {
            try AdaScriptPlugin(source: """
            @before(id: "recursive")
            @system(id: "recursive")
            class RecursiveSystem { func update(context) {} }
            """)
        }

        #expect(throws: AdaScriptError.invalidManifest(
            "system dependency cycle: first -> second -> first"
        )) {
            try AdaScriptPlugin(source: """
            @after(id: "second")
            @system(id: "first")
            class FirstSystem { func update(context) {} }

            @after(id: "first")
            @system(id: "second")
            class SecondSystem { func update(context) {} }
            """)
        }
    }
}

@Component
private struct AnnotatedPosition {
    var value: Double
}

@Component
private struct AnnotatedVelocity {
    var value: Double
}

@Component
private struct AnnotatedMovable {}

@Component
private struct AnnotatedFrozen {}
