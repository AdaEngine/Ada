@testable import AdaApp
import AdaECS
import AdaScripting
import Testing

@Suite("Gravity resource bindings", .serialized)
struct GravityResourceBindingTests {
    @Test("Mutates a typed resource through a pointer-backed @res binding")
    @MainActor
    func mutatesResource() async throws {
        RuntimeTypeRegistry.registerResource(ScriptBalance.self, names: ["ScriptBalance", "test.balance"])
        RuntimeResourceReflectionRegistry.register(
            ScriptBalance.self,
            fields: [Self.gravityField]
        )

        let plugin = try AdaScriptPlugin(
            source: """
            @system(id: "resource.system")
            class ResourceSystem {
                @res
                var balance: ScriptBalance;

                func update(context) {
                    balance.gravity += 1.5;
                }
            }
            """,
            name: "ResourceBinding"
        )
        let world = World(name: "Gravity resource binding")
        world.insertResource(ScriptBalance(gravity: 9.8))
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)

        #expect(plugin.diagnostics.isEmpty)
        #expect(world.getResource(ScriptBalance.self)?.gravity == 11.3)
    }

    @Test("Reports a missing required resource and permits an optional resource")
    @MainActor
    func missingResources() async throws {
        RuntimeTypeRegistry.registerResource(ScriptBalance.self, names: ["ScriptBalance", "test.balance"])
        RuntimeResourceReflectionRegistry.register(ScriptBalance.self, fields: [Self.gravityField])

        let plugin = try AdaScriptPlugin(
            source: """
            @system(id: "resource.system")
            class ResourceSystem {
                @res
                var required: ScriptBalance;

                @res(optional: true)
                var optional: ScriptBalance;

                func update(context) {
                    if (optional.available()) {
                        optional.gravity += 1.0;
                    }
                }
            }
            """,
            name: "MissingResourceBinding"
        )
        let world = World(name: "Missing Gravity resource binding")
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)

        #expect(plugin.diagnostics == ["Required resource 'ScriptBalance' is not available"])
    }

    @safe
    private static let gravityField = unsafe ReflectedComponentField(
        key: "gravity",
        label: "gravity",
        kind: .float,
        isWritable: true,
        accepts: { ComponentReflection.accepts($0, for: Double.self) },
        read: { _ in nil },
        write: { _, _ in nil },
        readPointer: { pointer in
            let resource = unsafe pointer.assumingMemoryBound(to: ScriptBalance.self)
            return ComponentReflection.read(unsafe resource.pointee.gravity)
        },
        writePointer: { pointer, value in
            let resource = unsafe pointer.assumingMemoryBound(to: ScriptBalance.self)
            return unsafe ComponentReflection.write(value, to: &resource.pointee.gravity)
        }
    )
}

private struct ScriptBalance: Resource {
    var gravity: Double
}
